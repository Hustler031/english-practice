-- Saved enrichment is intentionally single-flight. Three parallel writer/critic
-- pipelines can converge on the same Gemini rescue rate window and create a
-- thundering herd even while Antigravity quota remains available. One item per
-- worker invocation keeps provider usage predictable; successful items self-drain
-- immediately and the 5-minute due-aware recovery remains the safety net.

create or replace function public.english_saved_enrichment_worker_claim(p_token text,p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english
as $function$
declare
  v_lease uuid;
  v_expires timestamptz;
  v_new_lease uuid;
  v_raw jsonb;
  v_items jsonb;
  v_batch jsonb;
  v_limit integer:=1;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;

  update english.saved_enrichment_item_state es
  set state='retrying',
      attempt_count=greatest(es.attempt_count-1,0),
      transient_failure_count=es.transient_failure_count+1,
      lease_id=null,
      last_error=coalesce(es.last_error,'stale saved-enrichment processing recovered'),
      last_error_at=now(),
      last_error_class='lease_timeout',
      next_attempt_at=now()+interval '15 minutes',
      updated_at=now()
  where es.state='processing'
    and es.updated_at<now()-interval '12 minutes';

  select lease_id,lease_expires_at into v_lease,v_expires
  from english.saved_enrichment_worker_state where singleton=true for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  v_raw:=english.maintenance_saved_enrichment_batch(25);
  select coalesce(jsonb_agg(j order by ord),'[]'::jsonb)
  into v_items
  from (
    select j,ord
    from jsonb_array_elements(coalesce(v_raw->'items','[]'::jsonb)) with ordinality x(j,ord)
    join english.saved_items s on s.saved_id=j->>'savedId' and s.active
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    where coalesce(es.state,'') not in ('processing','failed')
      and not (coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
    order by ord
    limit v_limit
  ) picked;

  v_batch:=jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
  if jsonb_array_length(v_items)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch||jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,lease_expires_at=now()+interval '10 minutes',last_started_at=now(),last_error=null,updated_at=now()
  where singleton=true;

  insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,next_attempt_at,updated_at)
  select s.user_id,j->>'savedId','processing',1,v_new_lease,now(),null,now()
  from jsonb_array_elements(v_items) j
  join english.saved_items s on s.saved_id=j->>'savedId' and s.active
  on conflict(user_id,saved_id) do update set
    state='processing',attempt_count=english.saved_enrichment_item_state.attempt_count+1,lease_id=excluded.lease_id,
    last_attempt_at=excluded.last_attempt_at,next_attempt_at=null,updated_at=now();

  return v_batch||jsonb_build_object('busy',false,'leaseId',v_new_lease);
end
$function$;

create or replace function english.kick_saved_enrichment_worker(p_limit integer default 1)
returns bigint
language plpgsql
security definer
set search_path to pg_catalog, english, net
as $function$
declare
  v_token text;
  req bigint;
begin
  perform english.reconcile_saved_enrichment_worker_http();
  select token into v_token from english.context_ai_runtime_guard where singleton=true;
  if v_token is null then raise exception 'English runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-saved-enrichment-worker',
    body:=jsonb_build_object('limit',1),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=300000
  ) into req;

  insert into english.saved_enrichment_worker_requests(request_id,requested_at)
  values(req,now()) on conflict(request_id) do nothing;
  return req;
end
$function$;

create or replace function english.kick_saved_enrichment_recovery_if_needed()
returns bigint
language plpgsql
security definer
set search_path to pg_catalog, english
as $function$
declare
  v_busy boolean:=false;
  v_due boolean:=false;
begin
  perform english.reconcile_saved_enrichment_worker_http();

  select coalesce(lease_id is not null and lease_expires_at>now(),false)
  into v_busy
  from english.saved_enrichment_worker_state
  where singleton=true;

  if v_busy then return null; end if;

  select exists(
    select 1
    from english.saved_enrichment_item_state es
    join english.saved_items s on s.user_id=es.user_id and s.saved_id=es.saved_id and s.active
    where (es.state='retrying' and (es.next_attempt_at is null or es.next_attempt_at<=now()))
       or (es.state='processing' and es.updated_at<now()-interval '12 minutes')
  ) into v_due;

  if v_due then return english.kick_saved_enrichment_worker(1); end if;
  return null;
end
$function$;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname='english-saved-enrichment' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule('english-saved-enrichment','7 * * * *',$cmd$select english.kick_saved_enrichment_worker(1);$cmd$);
end
$do$;

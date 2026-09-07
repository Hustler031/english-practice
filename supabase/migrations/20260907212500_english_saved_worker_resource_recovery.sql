-- My Saved worker reliability: bound concurrent AI items and recover terminal resource-limit exits.

create or replace function public.english_saved_enrichment_worker_claim(p_token text,p_limit integer default 3)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english
as $function$
declare
  v_lease uuid;
  v_expires timestamptz;
  v_new_lease uuid;
  v_batch jsonb;
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;

  select lease_id,lease_expires_at into v_lease,v_expires
  from english.saved_enrichment_worker_state where singleton=true for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  -- Three independent writer/critic pipelines is the production concurrency ceiling.
  v_batch:=english.maintenance_saved_enrichment_batch(greatest(1,least(3,coalesce(p_limit,3))));
  if coalesce((v_batch->>'count')::integer,0)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch || jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,lease_expires_at=now()+interval '10 minutes',last_started_at=now(),last_error=null,updated_at=now()
  where singleton=true;

  insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,next_attempt_at,updated_at)
  select s.user_id,j->>'savedId','processing',1,v_new_lease,now(),null,now()
  from jsonb_array_elements(coalesce(v_batch->'items','[]'::jsonb)) j
  join english.saved_items s on s.saved_id=j->>'savedId' and s.active
  on conflict(user_id,saved_id) do update set
    state='processing',attempt_count=english.saved_enrichment_item_state.attempt_count+1,lease_id=excluded.lease_id,
    last_attempt_at=excluded.last_attempt_at,next_attempt_at=null,updated_at=now();

  return v_batch || jsonb_build_object('busy',false,'leaseId',v_new_lease);
end;
$function$;

create or replace function english.kick_saved_enrichment_worker(p_limit integer default 3)
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
    body:=jsonb_build_object('limit',greatest(1,least(3,coalesce(p_limit,3)))),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=300000
  ) into req;

  insert into english.saved_enrichment_worker_requests(request_id,requested_at)
  values(req,now()) on conflict(request_id) do nothing;
  return req;
end;
$function$;

create or replace function english.reconcile_saved_enrichment_worker_http()
returns integer
language plpgsql
security definer
set search_path to pg_catalog, english, net
as $function$
declare
  n integer:=0;
  v_failed_lease uuid;
begin
  -- A 546 response means the Edge invocation is terminal; it cannot still own its lease.
  select ws.lease_id into v_failed_lease
  from english.saved_enrichment_worker_state ws
  where ws.singleton=true
    and ws.lease_id is not null
    and coalesce(ws.last_finished_at,'epoch'::timestamptz)<coalesce(ws.last_started_at,'epoch'::timestamptz)
    and exists (
      select 1
      from english.saved_enrichment_worker_requests r
      join net._http_response h on h.id=r.request_id
      where r.reconciled_at is null
        and h.status_code=546
        and r.requested_at between ws.last_started_at-interval '5 seconds' and ws.last_started_at+interval '5 seconds'
    )
  for update;

  if v_failed_lease is not null then
    update english.saved_enrichment_item_state
    set state='pending',lease_id=null,last_error='WORKER_RESOURCE_LIMIT',last_error_at=now(),next_attempt_at=null,updated_at=now()
    where lease_id=v_failed_lease and state='processing';

    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_finished_at=now(),last_count=0,last_error='WORKER_RESOURCE_LIMIT',updated_at=now()
    where singleton=true and lease_id=v_failed_lease;
  end if;

  with ready as (
    update english.saved_enrichment_worker_requests r
    set reconciled_at=now()
    from net._http_response h
    where r.reconciled_at is null and h.id=r.request_id
    returning r.request_id,r.requested_at,h.status_code,h.timed_out,h.error_msg,h.created
  ), ins as (
    insert into english.worker_observability(worker,metrics,elapsed_ms)
    select 'english-saved-enrichment-worker',
      jsonb_strip_nulls(jsonb_build_object('source','scheduler_http','requestId',request_id,'lane','saved_enrichment','statusCode',status_code,'timedOut',coalesce(timed_out,false),'error',nullif(left(coalesce(error_msg,''),500),''))),
      greatest(0,least(2147483647,(extract(epoch from (created-requested_at))*1000)::bigint))::integer
    from ready
    returning event_id
  )
  select count(*) into n from ins;

  delete from english.saved_enrichment_worker_requests where requested_at<now()-interval '45 days';
  return n;
end;
$function$;

-- Reconcile the current terminal response, then restart with bounded concurrency.
select english.reconcile_saved_enrichment_worker_http();

-- Keep the existing hourly safety-net cadence, but make its concurrency explicit.
do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname='english-saved-enrichment' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule('english-saved-enrichment','7 * * * *',$cmd$select english.kick_saved_enrichment_worker(3);$cmd$);
end
$do$;

select english.kick_saved_enrichment_worker(3);

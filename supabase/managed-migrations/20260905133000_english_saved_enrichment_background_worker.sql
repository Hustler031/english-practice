-- Move recurring My Saved enrichment out of the ChatGPT automation runtime.
-- Supabase pg_cron -> private Edge worker -> token-authorized maintenance helpers.
-- The worker never writes canonical tables directly.

create table if not exists english.saved_enrichment_worker_state (
  singleton boolean primary key default true check (singleton),
  lease_id uuid,
  lease_expires_at timestamptz,
  last_started_at timestamptz,
  last_finished_at timestamptz,
  last_count integer not null default 0,
  last_error text,
  updated_at timestamptz not null default now()
);

insert into english.saved_enrichment_worker_state(singleton)
values(true)
on conflict(singleton) do nothing;

alter table english.saved_enrichment_worker_state enable row level security;
revoke all on table english.saved_enrichment_worker_state from public,anon,authenticated;
grant select,insert,update,delete on table english.saved_enrichment_worker_state to service_role;

create table if not exists english.saved_enrichment_worker_requests (
  request_id bigint primary key,
  requested_at timestamptz not null default now(),
  reconciled_at timestamptz
);

alter table english.saved_enrichment_worker_requests enable row level security;
revoke all on table english.saved_enrichment_worker_requests from public,anon,authenticated;
grant select,insert,update,delete on table english.saved_enrichment_worker_requests to service_role;

create or replace function public.english_saved_enrichment_worker_claim(
  p_token text,
  p_limit integer default 10
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
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

  select lease_id,lease_expires_at
  into v_lease,v_expires
  from english.saved_enrichment_worker_state
  where singleton=true
  for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  v_batch:=english.maintenance_saved_enrichment_batch(greatest(1,least(10,coalesce(p_limit,10))));
  if coalesce((v_batch->>'count')::integer,0)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch || jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,
      lease_expires_at=now()+interval '10 minutes',
      last_started_at=now(),
      last_error=null,
      updated_at=now()
  where singleton=true;

  return v_batch || jsonb_build_object('busy',false,'leaseId',v_new_lease);
end
$function$;

create or replace function public.english_saved_enrichment_worker_apply(
  p_token text,
  p_lease_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;
  if not exists(
    select 1 from english.saved_enrichment_worker_state
    where singleton=true and lease_id=p_lease_id and lease_expires_at>now()
  ) then
    raise exception 'saved enrichment worker lease is missing or expired';
  end if;
  return english.maintenance_apply_saved_enrichment(p_items);
end
$function$;

create or replace function public.english_saved_enrichment_worker_finish(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_verified jsonb:=jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb);
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;
  if not exists(
    select 1 from english.saved_enrichment_worker_state
    where singleton=true and lease_id=p_lease_id
  ) then
    raise exception 'saved enrichment worker lease mismatch';
  end if;

  if cardinality(coalesce(p_saved_ids,'{}'::text[]))>0 then
    v_verified:=english.maintenance_verify_saved_enrichment(p_saved_ids);
  end if;

  update english.saved_enrichment_worker_state
  set lease_id=null,
      lease_expires_at=null,
      last_finished_at=now(),
      last_count=cardinality(coalesce(p_saved_ids,'{}'::text[])),
      last_error=nullif(left(coalesce(p_error,''),1200),''),
      updated_at=now()
  where singleton=true and lease_id=p_lease_id;

  return v_verified;
end
$function$;

revoke all on function public.english_saved_enrichment_worker_claim(text,integer) from public,anon,authenticated;
revoke all on function public.english_saved_enrichment_worker_apply(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.english_saved_enrichment_worker_finish(text,uuid,text[],text) from public,anon,authenticated;
grant execute on function public.english_saved_enrichment_worker_claim(text,integer) to service_role;
grant execute on function public.english_saved_enrichment_worker_apply(text,uuid,jsonb) to service_role;
grant execute on function public.english_saved_enrichment_worker_finish(text,uuid,text[],text) to service_role;

create or replace function english.reconcile_saved_enrichment_worker_http()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $function$
declare
  n integer:=0;
begin
  with ready as (
    update english.saved_enrichment_worker_requests r
    set reconciled_at=now()
    from net._http_response h
    where r.reconciled_at is null and h.id=r.request_id
    returning r.request_id,r.requested_at,h.status_code,h.timed_out,h.error_msg,h.created
  ), ins as (
    insert into english.worker_observability(worker,metrics,elapsed_ms)
    select
      'english-saved-enrichment-worker',
      jsonb_strip_nulls(jsonb_build_object(
        'source','scheduler_http',
        'requestId',request_id,
        'lane','saved_enrichment',
        'statusCode',status_code,
        'timedOut',coalesce(timed_out,false),
        'error',nullif(left(coalesce(error_msg,''),500),'')
      )),
      greatest(0,least(2147483647,(extract(epoch from (created-requested_at))*1000)::bigint))::integer
    from ready
    returning event_id
  )
  select count(*) into n from ins;

  delete from english.saved_enrichment_worker_requests
  where requested_at<now()-interval '45 days';
  return n;
end
$function$;

create or replace function english.kick_saved_enrichment_worker(p_limit integer default 10)
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $function$
declare
  v_token text;
  req bigint;
begin
  perform english.reconcile_saved_enrichment_worker_http();

  select token into v_token
  from english.context_ai_runtime_guard
  where singleton=true;
  if v_token is null then raise exception 'English runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-saved-enrichment-worker',
    body:=jsonb_build_object('limit',greatest(1,least(10,coalesce(p_limit,10)))),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=65000
  ) into req;

  insert into english.saved_enrichment_worker_requests(request_id,requested_at)
  values(req,now())
  on conflict(request_id) do nothing;
  return req;
end
$function$;

revoke all on function english.reconcile_saved_enrichment_worker_http() from public,anon,authenticated;
revoke all on function english.kick_saved_enrichment_worker(integer) from public,anon,authenticated;
grant execute on function english.reconcile_saved_enrichment_worker_http() to service_role;
grant execute on function english.kick_saved_enrichment_worker(integer) to service_role;

do $cron$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='english-saved-enrichment'
  order by jobid
  limit 1;

  if v_jobid is null then
    perform cron.schedule(
      'english-saved-enrichment',
      '7 * * * *',
      'select english.kick_saved_enrichment_worker(10);'
    );
  end if;
end
$cron$;

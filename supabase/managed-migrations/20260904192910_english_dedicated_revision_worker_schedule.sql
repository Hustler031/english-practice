-- Route revision-only work to a dedicated worker with a larger bounded AI budget.

create or replace function english.kick_revision_worker(p_limit integer default 1)
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $function$
declare
  v_token text;
  req bigint;
  has_revision boolean:=false;
begin
  perform english.reconcile_context_worker_http();

  update english.question_revision_proposals
  set status='queued',next_attempt_at=now(),last_error='stale dedicated revision processing recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_revision_proposals
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'background revision retries exhausted'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  select exists(
    select 1 from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_revision;
  if not has_revision then return 0; end if;

  select token into v_token
  from english.context_ai_runtime_guard
  where singleton=true;
  if v_token is null then raise exception 'context runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-revision-worker',
    body:=jsonb_build_object('revisionLimit',greatest(1,least(1,coalesce(p_limit,1)))),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=65000
  ) into req;

  insert into english.context_worker_requests(request_id,lane,requested_at)
  values(req,'revision_dedicated',now())
  on conflict(request_id) do nothing;
  return req;
end
$function$;

revoke all on function english.kick_revision_worker(integer) from public,anon,authenticated;
grant execute on function english.kick_revision_worker(integer) to service_role;

-- Stop the mixed scheduler from waking solely for revision backlog. The existing
-- mixed worker may still see a revision during a Context/Transfer invocation,
-- but the dedicated every-minute worker owns the normal revision-only path.
do $route$
declare vdef text; vnext text;
begin
  select pg_get_functiondef(p.oid) into vdef
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english' and p.proname='kick_context_worker'
  order by p.oid desc limit 1;
  if vdef is null then raise exception 'english.kick_context_worker is missing'; end if;
  if position('has_revision:=false;' in vdef)=0 then
    vnext:=replace(vdef,E') into has_revision;\n  select exists(',E') into has_revision;\n  has_revision:=false;\n  select exists(');
    if vnext=vdef then raise exception 'Could not safely detach revision-only wake from mixed worker'; end if;
    execute vnext;
  end if;
end
$route$;

do $cron$
declare v_jobid bigint;
begin
  select jobid into v_jobid from cron.job where jobname='english-question-revision' order by jobid limit 1;
  if v_jobid is null then
    perform cron.schedule('english-question-revision','* * * * *','select english.kick_revision_worker(1);');
  end if;
end
$cron$;

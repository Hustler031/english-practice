-- Direct Supabase ownership for Daily Phrasal generation.
-- App users invoke the Edge worker with their authenticated session; pg_cron uses
-- the existing private English runtime token. GitHub/OIDC is not in the normal path.

create or replace function public.english_phrasal_worker_token_authorized(p_token text)
returns boolean
language sql security definer
set search_path='pg_catalog','english'
as $$
  select exists(
    select 1
    from english.context_ai_runtime_guard g
    where g.singleton=true
      and g.token is not null
      and g.token=p_token
  );
$$;
revoke all on function public.english_phrasal_worker_token_authorized(text) from public, anon, authenticated;
grant execute on function public.english_phrasal_worker_token_authorized(text) to service_role;

create or replace function public.english_phrasal_worker_user_authorized(p_user_id uuid)
returns boolean
language sql security definer
set search_path='pg_catalog','auth'
as $$
  select p_user_id is not null
    and (select count(*) from auth.users u where u.deleted_at is null)=1
    and exists(select 1 from auth.users u where u.deleted_at is null and u.id=p_user_id);
$$;
revoke all on function public.english_phrasal_worker_user_authorized(uuid) from public, anon, authenticated;
grant execute on function public.english_phrasal_worker_user_authorized(uuid) to service_role;

create or replace function english.kick_phrasal_worker()
returns bigint
language plpgsql security definer
set search_path='pg_catalog','english','net'
as $$
declare
  v_token text;
  req bigint;
begin
  select token into v_token
  from english.context_ai_runtime_guard
  where singleton=true;
  if v_token is null then raise exception 'English runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-phrasal-worker',
    body:='{"action":"run"}'::jsonb,
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=180000
  ) into req;
  return req;
end
$$;
revoke all on function english.kick_phrasal_worker() from public, anon, authenticated;
grant execute on function english.kick_phrasal_worker() to service_role;

-- 00:05 Asia/Kolkata = 18:35 UTC on the preceding UTC date. Daily selection itself
-- uses Asia/Kolkata, so the worker always materializes the intended local study day.
do $cron$
declare r record;
begin
  for r in select jobid from cron.job where jobname='english-phrasal-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'english-phrasal-daily',
    '35 18 * * *',
    'select english.kick_phrasal_worker();'
  );
end
$cron$;

comment on function english.kick_phrasal_worker() is
  'Daily Phrasal direct launcher: Central Intelligence selects exact 20; valid bank cards reuse with zero AI; only true gaps/context-fill slots use Antigravity HIGH -> code -> Luna LOW.';

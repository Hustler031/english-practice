-- Allow direct Phrasal generation to honor provider quota backoff windows without
-- truncating the exact-20 atomic run at the previous 180-second launcher timeout.
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
    timeout_milliseconds:=300000
  ) into req;
  return req;
end
$$;
revoke all on function english.kick_phrasal_worker() from public, anon, authenticated;
grant execute on function english.kick_phrasal_worker() to service_role;

comment on function english.kick_phrasal_worker() is
  'Daily Phrasal direct launcher with 300-second transport timeout for bounded AI/provider backoff; exact-20 publication remains atomic.';

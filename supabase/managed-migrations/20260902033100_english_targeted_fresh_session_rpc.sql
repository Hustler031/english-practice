-- Keep Targeted batches fresh without changing the shared client caching contract.
create or replace function public.english_get_targeted_session(
  p_count integer default 15,
  p_kind text default null,
  p_confusion_id uuid default null,
  p_session_nonce text default null
) returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
  select public.english_get_targeted_batch(p_count,p_kind,p_confusion_id);
$$;
revoke all on function public.english_get_targeted_session(integer,text,uuid,text) from public,anon;
grant execute on function public.english_get_targeted_session(integer,text,uuid,text) to authenticated,service_role;

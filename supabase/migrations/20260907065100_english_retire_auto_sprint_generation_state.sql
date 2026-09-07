-- The app no longer owns Sprint creation. Retire stale automatic-generation state
-- so legacy jobs cannot surface an unrelated failure beside a ChatGPT-prepared set.

update english.sprint_generation_jobs
set status='failed',
    error='Automatic Sprint generation retired; create the next set in ChatGPT',
    updated_at=now(),
    completed_at=coalesce(completed_at,now()),
    expires_at=now()
where status in ('queued','generating','ready');

create or replace function public.english_get_sprint_generation()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null
  then jsonb_build_object('ok',false,'error','Authentication required')
  else jsonb_build_object('ok',true,'active',false,'status','idle','retired',true)
end;
$function$;

grant execute on function public.english_get_sprint_generation() to authenticated;

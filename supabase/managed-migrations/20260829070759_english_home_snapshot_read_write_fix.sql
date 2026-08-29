create or replace function public.english_get_home_snapshot()
returns jsonb
language sql
volatile
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
  'ok',true,
  'studyDay',greatest(1, ((now() at time zone 'Asia/Kolkata')::date - date '2026-08-14') + 1),
  'summary',public.english_dashboard_summary(),
  'intelligence',public.english_get_central_intelligence(),
  'phrasal',public.english_get_phrasal_hub(),
  'bank',public.english_get_bank_coverage_hub(),
  'saved',public.english_get_saved_revision_hub(),
  'starred',public.english_get_starred_hub(null,null),
  'hindu',public.english_get_hindu_today()
) end;
$function$;

grant execute on function public.english_get_home_snapshot() to authenticated;

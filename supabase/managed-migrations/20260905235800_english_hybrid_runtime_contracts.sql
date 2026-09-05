-- Read-only service diagnostics used for pre-activation smoke tests.

create or replace function public.english_get_hybrid_ai_runtime_status()
returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english'
as $$
select jsonb_build_object(
  'ok',true,
  'flags',coalesce((select jsonb_object_agg(flag,enabled order by flag) from english.ai_content_feature_flags),'{}'::jsonb),
  'phrasalToday',english.maintenance_verify_phrasal_daily(),
  'hinduToday',english.maintenance_verify_hindu_daily(),
  'recentAuditCount',(select count(*) from english.content_generation_audits where created_at>=now()-interval '24 hours')
)
$$;
revoke all on function public.english_get_hybrid_ai_runtime_status() from public,anon,authenticated;
grant execute on function public.english_get_hybrid_ai_runtime_status() to service_role;

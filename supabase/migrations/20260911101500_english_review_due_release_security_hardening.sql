-- REVIEW DUE TODAY — LEARNER-FACING RELEASE SECURITY HARDENING
-- Runs after practice/gate migrations and keeps all internal tables/helpers owner-only.

alter table if exists english.review_due_runtime_config enable row level security;
alter table if exists english.review_due_question_deferrals enable row level security;
alter table if exists english.review_due_day_runs enable row level security;
alter table if exists english.review_due_obligations enable row level security;
alter table if exists english.review_due_phase2_daily_mix_selections enable row level security;

revoke all on table english.review_due_runtime_config from public,anon,authenticated;
revoke all on table english.review_due_question_deferrals from public,anon,authenticated;
revoke all on table english.review_due_day_runs from public,anon,authenticated;
revoke all on table english.review_due_obligations from public,anon,authenticated;
revoke all on table english.review_due_phase2_daily_mix_selections from public,anon,authenticated;

create or replace function english.review_due_deferral_days(p_status text)
returns integer
language sql
immutable
set search_path to 'pg_catalog'
as $function$
select case coalesce(p_status,'Learning')
  when 'Persistent Weak' then 1
  when 'Weak' then 1
  when 'Learning' then 1
  when 'Fragile' then 2
  when 'Strong' then 7
  else 1
end;
$function$;

revoke all on function english.review_due_deferral_days(text) from public,anon,authenticated;
revoke all on function english.review_due_cross_credit_enabled() from public,anon,authenticated;
revoke all on function english.review_due_evidence_status(uuid,date,text) from public,anon,authenticated;
revoke all on function english.active_review_due_deferral(uuid,text) from public,anon,authenticated;
revoke all on function english.reconcile_review_due_deferrals(uuid,date) from public,anon,authenticated;
revoke all on function english.reconcile_review_due_deferrals_today_all_users() from public,anon,authenticated;

revoke all on function public.english_get_review_due_today() from public,anon;
grant execute on function public.english_get_review_due_today() to authenticated;
revoke all on function public.english_get_review_due_lane(text) from public,anon;
grant execute on function public.english_get_review_due_lane(text) to authenticated;

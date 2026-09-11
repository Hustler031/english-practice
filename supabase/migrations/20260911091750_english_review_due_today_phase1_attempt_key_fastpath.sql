create or replace function public.english_get_review_due_today()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with params as (
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today
), bounds as (
  select p.uid,p.today,(p.today::timestamp at time zone 'Asia/Kolkata') start_at,(((p.today+1)::timestamp) at time zone 'Asia/Kolkata') end_at
  from params p
), run as (
  select r.* from english.review_due_day_runs r join params p on p.uid=r.user_id and p.today=r.due_date
), obligations as (
  select o.* from english.review_due_obligations o join params p on p.uid=o.user_id and p.today=o.due_date
), attempt_evidence as (
  select a.attempt_id,a.question_id,a.attempted_at,a.correct,
         lower(btrim(coalesce(a.module,''))) module_key,
         english.review_due_module_qualifies(a.module) qualifies,
         coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id)) concept_key,
         exists(select 1 from english.learner_confidence_signals g where g.user_id=a.user_id and g.attempt_id=a.attempt_id and g.signal='guessed') guessed,
         coalesce(qm.too_easy,false) too_easy
  from english.attempts a
  join bounds b on a.user_id=b.uid and a.attempted_at>=b.start_at and a.attempted_at<b.end_at
  left join english.question_quality_metrics qm on qm.user_id=a.user_id and qm.question_id=a.question_id
), per_concept as (
  select o.concept_key,
         bool_or(coalesce(a.qualifies,false)) has_qualifying_attempt,
         bool_or(coalesce(a.qualifies,false) and not coalesce(a.correct,false)) has_wrong,
         bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and a.guessed) has_guessed_correct,
         bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and not a.guessed and a.too_easy) has_low_info_correct,
         bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and not a.guessed and not a.too_easy) has_strict_correct,
         bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and not a.guessed and not a.too_easy and a.module_key<>'reviewduetoday') has_strict_correct_elsewhere,
         count(distinct a.module_key) filter(where coalesce(a.qualifies,false)) module_count,
         count(distinct a.question_id) filter(where coalesce(a.qualifies,false)) question_count
  from obligations o left join attempt_evidence a on a.concept_key=o.concept_key
  group by o.concept_key
), classified as (
  select p.*,case when p.has_wrong then 'needs_repair' when p.has_strict_correct then 'satisfied' when p.has_guessed_correct or p.has_low_info_correct then 'low_confidence' else 'remaining' end shadow_status
  from per_concept p
), totals as (
  select count(*)::integer due_at_start,
         count(*) filter(where shadow_status='satisfied')::integer satisfied,
         count(*) filter(where shadow_status='satisfied' and has_strict_correct_elsewhere)::integer satisfied_elsewhere,
         count(*) filter(where shadow_status='needs_repair')::integer needs_repair,
         count(*) filter(where shadow_status='low_confidence')::integer low_confidence,
         count(*) filter(where shadow_status='remaining')::integer remaining,
         count(*) filter(where module_count>=2 or question_count>=2)::integer duplicate_touches
  from classified
)
select case when (select uid from params) is null then jsonb_build_object('ok',false,'reason','Authentication required')
else jsonb_build_object(
  'ok',true,'date',(select today from params),'phase','shadow',
  'snapshotReady',exists(select 1 from run),'snapshotAt',(select captured_at from run limit 1),
  'dueQuestionCount',coalesce((select due_question_count from run limit 1),0),
  'dueAtStart',coalesce((select due_at_start from totals),0),
  'satisfied',coalesce((select satisfied from totals),0),
  'satisfiedElsewhere',coalesce((select satisfied_elsewhere from totals),0),
  'needsRepair',coalesce((select needs_repair from totals),0),
  'lowConfidence',coalesce((select low_confidence from totals),0),
  'remaining',coalesce((select remaining from totals),0),
  'duplicateTouches',coalesce((select duplicate_touches from totals),0),
  'overdueConcepts',null,'routingChanged',false,'countsTowardDailyFocus',false
) end;
$function$;

comment on function public.english_get_review_due_today() is
  'Phase 1 read-only Review Due Today shadow summary. Uses attempt concept_id fast path; no live overdue scan on Home. Wrong evidence overrides same-day success; guessed/too-easy correct evidence is low-confidence. Does not alter routing or review clocks.';

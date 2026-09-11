create or replace function english.review_due_phase2_shadow(p_user_id uuid,p_due_date date)
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with bounds as (
  select p_due_date due_date,
         (p_due_date::timestamp at time zone 'Asia/Kolkata') start_at,
         (((p_due_date+1)::timestamp) at time zone 'Asia/Kolkata') end_at,
         least(now(),(((p_due_date+1)::timestamp) at time zone 'Asia/Kolkata')) observation_end
), obligations as materialized (
  select o.concept_key
  from english.review_due_obligations o
  where o.user_id=p_user_id and o.due_date=p_due_date
), daily_items as materialized (
  select d.question_id,
         coalesce(nullif(d.concept_id,''),english.review_due_concept_key(d.question_id)) concept_key,
         d.reason,
         coalesce(d.selection_signals,'{}'::text[]) signals,
         lower(coalesce(d.status,'')) status,
         (
           select min(a.attempted_at)
           from english.attempts a,bounds b
           where a.user_id=p_user_id
             and lower(btrim(coalesce(a.module,'')))='daily'
             and a.attempted_at>=b.start_at and a.attempted_at<b.end_at
             and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))
                 =coalesce(nullif(d.concept_id,''),english.review_due_concept_key(d.question_id))
         ) first_daily_attempt_at
  from english.daily_current d
  join obligations o on o.concept_key=coalesce(nullif(d.concept_id,''),english.review_due_concept_key(d.question_id))
  where d.user_id=p_user_id and d.quiz_date=p_due_date
), external_flags as materialized (
  select d.question_id,d.concept_key,d.reason,d.signals,d.status,d.first_daily_attempt_at,
         bool_or(not coalesce(a.correct,false)) filter(where a.attempt_id is not null) has_wrong_before,
         bool_or(coalesce(a.correct,false) and not coalesce(g.guessed,false) and not coalesce(qm.too_easy,false)) filter(where a.attempt_id is not null) has_strict_correct_before,
         bool_or(coalesce(a.correct,false) and (coalesce(g.guessed,false) or coalesce(qm.too_easy,false))) filter(where a.attempt_id is not null) has_low_confidence_correct_before
  from daily_items d
  cross join bounds b
  left join english.attempts a
    on a.user_id=p_user_id
   and a.attempted_at>=b.start_at
   and a.attempted_at<coalesce(d.first_daily_attempt_at,b.observation_end)
   and lower(btrim(coalesce(a.module,'')))<>'daily'
   and english.review_due_module_qualifies(a.module)
   and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))=d.concept_key
  left join lateral (
    select exists(
      select 1 from english.learner_confidence_signals x
      where x.user_id=p_user_id and x.attempt_id=a.attempt_id and x.signal='guessed'
    ) guessed
  ) g on true
  left join english.question_quality_metrics qm on qm.user_id=p_user_id and qm.question_id=a.question_id
  group by d.question_id,d.concept_key,d.reason,d.signals,d.status,d.first_daily_attempt_at
), daily_classified as (
  select e.*,
         case
           when coalesce(e.has_wrong_before,false) then 'repair_required'
           when coalesce(e.has_strict_correct_before,false) then 'strictly_satisfied_before_daily'
           when coalesce(e.has_low_confidence_correct_before,false) then 'low_confidence_before_daily'
           else 'no_prior_credit'
         end prior_status,
         (e.reason in ('Due Spaced Revision','Learning') and not (e.signals @> array['TARGET']::text[])) generic_review_only
  from external_flags e
), focus as materialized (
  select f.lane,f.status,f.question_id,f.concept_key,f.selected_at,
         exists(
           select 1 from english.attempts a
           where a.user_id=f.user_id and a.question_id=f.question_id and a.attempted_at>=f.selected_at
         ) has_attempt,
         exists(
           select 1 from english.attempts a
           where a.user_id=f.user_id and a.question_id=f.question_id and a.attempted_at>=f.selected_at and a.correct is true
         ) has_correct
  from english.daily_focus_items f
  join obligations o on o.concept_key=f.concept_key
  where f.user_id=p_user_id and f.batch_date=p_due_date
), sample as (
  select count(*)::int shadow_days
  from english.review_due_day_runs r
  where r.user_id=p_user_id and r.due_date<=p_due_date
)
select jsonb_build_object(
  'ok',true,
  'date',p_due_date,
  'phase','phase2_shadow',
  'routingChanged',false,
  'manualActivationRequired',true,
  'shadowDays',(select shadow_days from sample),
  'dailyMix',jsonb_build_object(
    'reviewDueOverlap',count(*)::int,
    'genericSuppressCandidates',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only)::int,
    'genericDuplicatesActuallyAttempted',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only and first_daily_attempt_at is not null)::int,
    'genericPendingPreventable',count(*) filter(where prior_status='strictly_satisfied_before_daily' and generic_review_only and first_daily_attempt_at is null)::int,
    'preservedIndependentLearning',count(*) filter(where prior_status='strictly_satisfied_before_daily' and not generic_review_only)::int,
    'repairRequiredBeforeDaily',count(*) filter(where prior_status='repair_required')::int,
    'lowConfidenceBeforeDaily',count(*) filter(where prior_status='low_confidence_before_daily')::int
  ),
  'dailyFocus',jsonb_build_object(
    'policy','observe_only_no_suppression',
    'reviewDueOverlap',(select count(*)::int from focus),
    'repairOverlap',(select count(*)::int from focus where lane='repair'),
    'coverageOverlap',(select count(*)::int from focus where lane='coverage'),
    'fastTrackOverlap',(select count(*)::int from focus where lane='fast_track'),
    'completedWithoutCorrectEvidence',(select count(*)::int from focus where lower(coalesce(status,''))='completed' and has_attempt and not has_correct)
  ),
  'activationGate',jsonb_build_object(
    'eligible',false,
    'reason','manual gate; collect multiple full shadow days before any routing change',
    'scopeWhenApproved','Daily Mix generic scheduled-review suppression only; Daily Focus lanes remain independent'
  )
)
from daily_classified;
$function$;

create or replace function public.english_get_review_due_phase2_shadow(p_date date default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_date date:=coalesce(p_date,(now() at time zone 'Asia/Kolkata')::date);
begin
  if uid is null then raise exception 'Authentication required'; end if;
  return english.review_due_phase2_shadow(uid,v_date);
end;
$function$;

revoke all on function english.review_due_phase2_shadow(uuid,date) from public,anon,authenticated;
revoke all on function public.english_get_review_due_phase2_shadow(date) from public,anon;
grant execute on function public.english_get_review_due_phase2_shadow(date) to authenticated;

comment on function english.review_due_phase2_shadow(uuid,date) is
  'Read-only Phase 2 decision simulator. Measures strict external evidence occurring before Daily Mix work; never mutates routing, review clocks, Daily Focus, or attempts.';
comment on function public.english_get_review_due_phase2_shadow(date) is
  'Authenticated Phase 2 shadow metrics. Activation remains manual and Daily Focus lanes remain independent.';
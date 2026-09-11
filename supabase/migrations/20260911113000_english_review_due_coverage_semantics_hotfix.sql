-- REVIEW DUE TODAY — COVERAGE SEMANTICS HOTFIX
-- Learner-facing Review Due Today is a coverage obligation: a scheduled review must not be missed.
-- Any durable attempt made inside the dedicated `reviewduetoday` module covers that concept's
-- obligation for the current IST day, regardless of correctness. Correctness/guess/quality still
-- feed the normal Central Intelligence scheduler and shadow diagnostics.
-- Attempts made outside Review Due do NOT cover the obligation while cross-concept credit is OFF.
-- This migration does not write question_state, next_review, mastery, or attempts.

create or replace function english.review_due_evidence_status(
  p_user_id uuid,
  p_due_date date,
  p_concept_key text
)
returns table(
  shadow_status text,
  resolution_status text,
  strict_correct_at timestamptz,
  strict_question_id text,
  strict_module text,
  last_wrong_at timestamptz,
  last_wrong_question_id text,
  low_confidence_at timestamptz,
  low_confidence_question_id text,
  qualifying_attempts integer,
  module_count integer,
  satisfied_elsewhere boolean
)
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with bounds as (
  select
    (p_due_date::timestamp at time zone 'Asia/Kolkata') start_at,
    (((p_due_date+1)::timestamp) at time zone 'Asia/Kolkata') end_at
), obligation as (
  select o.due_question_ids
  from english.review_due_obligations o
  where o.user_id=p_user_id
    and o.due_date=p_due_date
    and o.concept_key=p_concept_key
  limit 1
), mastery as (
  select coalesce(bool_and(coalesce(s.mastered,false)),false) all_due_mastered
  from obligation o
  cross join unnest(o.due_question_ids) qid
  left join english.question_state s
    on s.user_id=p_user_id and s.question_id=qid
), ev as (
  select
    a.attempt_id,
    a.question_id,
    a.attempted_at,
    lower(btrim(coalesce(a.module,''))) module_key,
    coalesce(a.correct,false) correct,
    english.review_due_module_qualifies(a.module) qualifies,
    a.question_id=any(o.due_question_ids) exact_due,
    exists(
      select 1
      from english.learner_confidence_signals g
      where g.user_id=a.user_id
        and g.attempt_id=a.attempt_id
        and g.signal='guessed'
    ) guessed,
    coalesce(qm.too_easy,false) too_easy
  from english.attempts a
  cross join bounds b
  cross join obligation o
  left join english.question_quality_metrics qm
    on qm.user_id=a.user_id and qm.question_id=a.question_id
  where a.user_id=p_user_id
    and a.attempted_at>=b.start_at
    and a.attempted_at<b.end_at
    and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))=p_concept_key
), agg as (
  select
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and (exact_due or not too_easy)))[1] strict_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and (exact_due or not too_easy)))[1] strict_q,
    (array_agg(module_key order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and (exact_due or not too_easy)))[1] strict_mod,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and not correct))[1] wrong_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and not correct))[1] wrong_q,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and (guessed or (too_easy and not exact_due))))[1] low_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and (guessed or (too_easy and not exact_due))))[1] low_q,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where module_key='reviewduetoday'))[1] review_attempt_at,
    count(*) filter(where qualifies)::integer attempts_n,
    count(distinct module_key) filter(where qualifies)::integer modules_n
  from ev
), classified as (
  select
    a.*,
    coalesce((select all_due_mastered from mastery),false) all_due_mastered,
    coalesce((select a.strict_q=any(o.due_question_ids) from obligation o),false) strict_is_exact_due,
    english.review_due_cross_credit_enabled() cross_credit_enabled,
    (
      a.strict_at is not null
      and (
        a.wrong_at is null
        or (
          a.strict_at>a.wrong_at
          and (
            a.strict_q is distinct from a.wrong_q
            or a.strict_at>=a.wrong_at+interval '15 minutes'
          )
        )
      )
      and (
        a.low_at is null
        or (
          a.strict_at>a.low_at
          and (
            a.strict_q is distinct from a.low_q
            or a.strict_at>=a.low_at+interval '15 minutes'
          )
        )
      )
    ) recovered
  from agg a
)
select
  -- Shadow status remains a learning-quality diagnostic for Central Intelligence.
  case
    when all_due_mastered then 'satisfied'
    when wrong_at is not null then 'needs_repair'
    when strict_at is not null then 'satisfied'
    when low_at is not null then 'low_confidence'
    else 'remaining'
  end shadow_status,
  -- Learner-facing status is coverage. A dedicated Review Due attempt covers today's obligation
  -- even when wrong; the normal submit/scheduler path still determines the next review.
  case
    when all_due_mastered then 'satisfied'
    when review_attempt_at is not null then 'satisfied'
    when cross_credit_enabled and recovered then 'satisfied'
    else 'remaining'
  end resolution_status,
  strict_at,
  strict_q,
  strict_mod,
  wrong_at,
  wrong_q,
  low_at,
  low_q,
  coalesce(attempts_n,0),
  coalesce(modules_n,0),
  (
    review_attempt_at is null
    and cross_credit_enabled
    and recovered
    and coalesce(strict_mod,'')<>'reviewduetoday'
  ) satisfied_elsewhere
from classified;
$function$;

revoke all on function english.review_due_evidence_status(uuid,date,text) from public,anon,authenticated;

-- REVIEW DUE TODAY — LEARNER-FACING PRACTICE LANE
-- This migration adds a read-only dynamic lane. It does not alter Daily Focus 170,
-- Daily Mix composition, mastery, attempts, or review clocks.

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
), ev as (
  select
    a.attempt_id,
    a.question_id,
    a.attempted_at,
    lower(btrim(coalesce(a.module,''))) module_key,
    coalesce(a.correct,false) correct,
    english.review_due_module_qualifies(a.module) qualifies,
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
  left join english.question_quality_metrics qm
    on qm.user_id=a.user_id and qm.question_id=a.question_id
  where a.user_id=p_user_id
    and a.attempted_at>=b.start_at
    and a.attempted_at<b.end_at
    and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))=p_concept_key
), agg as (
  select
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and not too_easy))[1] strict_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and not too_easy))[1] strict_q,
    (array_agg(module_key order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and not too_easy))[1] strict_mod,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and not correct))[1] wrong_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and not correct))[1] wrong_q,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and (guessed or too_easy)))[1] low_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and (guessed or too_easy)))[1] low_q,
    count(*) filter(where qualifies)::integer attempts_n,
    count(distinct module_key) filter(where qualifies)::integer modules_n
  from ev
), classified as (
  select a.*,
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
    ) recovered
  from agg a
)
select
  case
    when wrong_at is not null then 'needs_repair'
    when strict_at is not null then 'satisfied'
    when low_at is not null then 'low_confidence'
    else 'remaining'
  end shadow_status,
  case
    when recovered then 'satisfied'
    when wrong_at is not null then 'needs_repair'
    when low_at is not null then 'low_confidence'
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
  (recovered and coalesce(strict_mod,'')<>'reviewduetoday')
from classified;
$function$;

comment on function english.review_due_evidence_status(uuid,date,text) is
  'Returns conservative shadow status plus learner-facing resolution status. A later strong recovery can clear a wrong only with a fresh sibling or a 15-minute same-question gap.';

revoke all on function english.review_due_evidence_status(uuid,date,text) from public,anon,authenticated;

create or replace function public.english_get_review_due_today()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with params as (
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today
), run as (
  select r.*
  from english.review_due_day_runs r
  join params p on p.uid=r.user_id and p.today=r.due_date
), obligations as (
  select o.*
  from english.review_due_obligations o
  join params p on p.uid=o.user_id and p.today=o.due_date
), classified as (
  select o.concept_key,e.*
  from obligations o
  cross join params p
  cross join lateral english.review_due_evidence_status(p.uid,p.today,o.concept_key) e
), totals as (
  select
    count(*)::integer due_at_start,
    count(*) filter(where resolution_status='satisfied')::integer satisfied,
    count(*) filter(where resolution_status='satisfied' and satisfied_elsewhere)::integer satisfied_elsewhere,
    count(*) filter(where resolution_status='needs_repair')::integer needs_repair,
    count(*) filter(where resolution_status='low_confidence')::integer low_confidence,
    count(*) filter(where resolution_status='remaining')::integer remaining,
    count(*) filter(where module_count>=2 or qualifying_attempts>=2)::integer duplicate_touches,
    count(*) filter(where shadow_status='needs_repair')::integer shadow_needs_repair,
    count(*) filter(where shadow_status='satisfied')::integer shadow_satisfied
  from classified
)
select case
  when (select uid from params) is null then jsonb_build_object('ok',false,'reason','Authentication required')
  else jsonb_build_object(
    'ok',true,
    'date',(select today from params),
    'phase','practice_ready',
    'snapshotReady',exists(select 1 from run),
    'snapshotAt',(select captured_at from run limit 1),
    'dueQuestionCount',coalesce((select due_question_count from run limit 1),0),
    'dueAtStart',coalesce((select due_at_start from totals),0),
    'satisfied',coalesce((select satisfied from totals),0),
    'satisfiedElsewhere',coalesce((select satisfied_elsewhere from totals),0),
    'needsRepair',coalesce((select needs_repair from totals),0),
    'lowConfidence',coalesce((select low_confidence from totals),0),
    'remaining',coalesce((select remaining from totals),0),
    'actionable',coalesce((select needs_repair+low_confidence+remaining from totals),0),
    'duplicateTouches',coalesce((select duplicate_touches from totals),0),
    'shadowNeedsRepair',coalesce((select shadow_needs_repair from totals),0),
    'shadowSatisfied',coalesce((select shadow_satisfied from totals),0),
    'overdueConcepts',null,
    'routingChanged',false,
    'countsTowardDailyFocus',false,
    'practiceEnabled',true
  )
end;
$function$;

revoke all on function public.english_get_review_due_today() from public,anon;
grant execute on function public.english_get_review_due_today() to authenticated;

create or replace function public.english_get_review_due_lane(p_nonce text default null)
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with params as (
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today
), obligations as (
  select o.*
  from english.review_due_obligations o
  join params p on p.uid=o.user_id and p.today=o.due_date
), status as (
  select o.*,e.resolution_status,e.strict_question_id,e.last_wrong_at,e.last_wrong_question_id,
         e.low_confidence_question_id
  from obligations o
  cross join params p
  cross join lateral english.review_due_evidence_status(p.uid,p.today,o.concept_key) e
  where e.resolution_status<>'satisfied'
), picked as (
  select s.*,pick.question_id,
    case s.resolution_status
      when 'needs_repair' then 'Fresh recovery evidence'
      when 'low_confidence' then 'Confirm without guess / low-information evidence'
      else 'Scheduled review due today'
    end selection_reason
  from status s
  cross join params p
  cross join lateral (
    select q.question_id
    from english.questions q
    left join english.question_state qs
      on qs.user_id=p.uid and qs.question_id=q.question_id
    left join english.question_quality_metrics qm
      on qm.user_id=p.uid and qm.question_id=q.question_id
    where q.active
      and english.question_visible_to_user(p.uid,q.question_id)
      and not coalesce(qs.mastered,false)
      and coalesce(
        (select m.concept_id from english.question_concept_mappings m where m.question_id=q.question_id order by coalesce(m.mapping_confidence,0) desc,m.updated_at desc nulls last limit 1),
        nullif(q.concept_id,''),q.question_id
      )=s.concept_key
    order by
      case s.resolution_status
        when 'needs_repair' then
          case
            when q.question_id is distinct from s.last_wrong_question_id
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 0
            when q.question_id=any(s.due_question_ids)
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 1
            when q.question_id is distinct from s.last_wrong_question_id then 2
            else 3
          end
        when 'low_confidence' then
          case
            when q.question_id is distinct from s.low_confidence_question_id
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 0
            when q.question_id=any(s.due_question_ids)
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 1
            else 2
          end
        else
          case
            when q.question_id=any(s.due_question_ids)
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 0
            when q.question_id=any(s.due_question_ids) then 1
            when not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 2
            else 3
          end
      end,
      coalesce(qm.too_easy,false),
      coalesce(qs.last_attempt,'epoch'::timestamptz),
      q.question_id
    limit 1
  ) pick
), payload as (
  select
    p.concept_key,
    p.resolution_status,
    p.selection_reason,
    p.due_question_count,
    p.question_id,
    english.question_payload(x.uid,p.question_id)
      || jsonb_build_object(
        'reviewDueToday',true,
        'reviewDueDate',p.due_date,
        'reviewDueConcept',p.concept_key,
        'reviewDueStatus',p.resolution_status,
        'reviewDueQuestionCount',p.due_question_count,
        'selectionReason',p.selection_reason
      ) item
  from picked p
  cross join params x
)
select case
  when (select uid from params) is null then jsonb_build_array()
  else coalesce(jsonb_agg(item order by
    case resolution_status when 'needs_repair' then 0 when 'low_confidence' then 1 else 2 end,
    concept_key
  ),'[]'::jsonb)
end
from payload;
$function$;

comment on function public.english_get_review_due_lane(text) is
  'Dynamic Review Due Today practice lane. One unresolved obligation per concept; actual due question first, fresh sibling preferred for recovery. p_nonce is ignored and exists only to force a fresh client cache key.';

revoke all on function public.english_get_review_due_lane(text) from public,anon;
grant execute on function public.english_get_review_due_lane(text) to authenticated;

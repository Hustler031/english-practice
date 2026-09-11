-- REVIEW DUE TODAY — GATE-AWARE PRACTICE SELECTION
-- While cross-concept credit is OFF, only exact due questions are learner-actionable.
-- Once the gate is enabled, fresh sibling evidence may be served for repair/confirmation.

create or replace function public.english_get_review_due_today()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with params as (
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today
), run as (
  select r.* from english.review_due_day_runs r
  join params p on p.uid=r.user_id and p.today=r.due_date
), obligations as (
  select o.* from english.review_due_obligations o
  join params p on p.uid=o.user_id and p.today=o.due_date
), classified as (
  select o.concept_key,e.*
  from obligations o cross join params p
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
    'crossCreditEnabled',english.review_due_cross_credit_enabled(),
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
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today,
         english.review_due_cross_credit_enabled() cross_credit
), obligations as (
  select o.*
  from english.review_due_obligations o
  join params p on p.uid=o.user_id and p.today=o.due_date
), status as (
  select o.*,e.resolution_status,e.strict_question_id,e.last_wrong_at,e.last_wrong_question_id,
         e.low_confidence_question_id
  from obligations o cross join params p
  cross join lateral english.review_due_evidence_status(p.uid,p.today,o.concept_key) e
  where e.resolution_status<>'satisfied'
), picked as (
  select s.*,pick.question_id,
    case
      when not p.cross_credit and s.resolution_status='needs_repair' then 'Retry the scheduled due word after repair'
      when not p.cross_credit and s.resolution_status='low_confidence' then 'Confirm the scheduled due word with stronger evidence'
      when s.resolution_status='needs_repair' then 'Fresh recovery evidence'
      when s.resolution_status='low_confidence' then 'Confirm without guess / low-information evidence'
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
      and (p.cross_credit or q.question_id=any(s.due_question_ids))
      and coalesce(
        (select m.concept_id from english.question_concept_mappings m
         where m.question_id=q.question_id
         order by coalesce(m.mapping_confidence,0) desc,m.updated_at desc nulls last
         limit 1),
        nullif(q.concept_id,''),q.question_id
      )=s.concept_key
    order by
      case
        when not p.cross_credit then
          case
            when q.question_id=any(s.due_question_ids)
              and not exists(
                select 1 from english.attempts a
                where a.user_id=p.uid and a.question_id=q.question_id
                  and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
              ) then 0
            else 1
          end
        when s.resolution_status='needs_repair' then
          case
            when q.question_id is distinct from s.last_wrong_question_id
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 0
            when q.question_id=any(s.due_question_ids)
              and not exists(select 1 from english.attempts a where a.user_id=p.uid and a.question_id=q.question_id and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today) then 1
            when q.question_id is distinct from s.last_wrong_question_id then 2
            else 3
          end
        when s.resolution_status='low_confidence' then
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
  select p.concept_key,p.resolution_status,p.selection_reason,p.due_question_count,p.question_id,
    english.question_payload(x.uid,p.question_id)
      || jsonb_build_object(
        'reviewDueToday',true,
        'reviewDueDate',p.due_date,
        'reviewDueConcept',p.concept_key,
        'reviewDueStatus',p.resolution_status,
        'reviewDueQuestionCount',p.due_question_count,
        'reviewDueCrossCreditEnabled',x.cross_credit,
        'selectionReason',p.selection_reason
      ) item
  from picked p cross join params x
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
revoke all on function public.english_get_review_due_lane(text) from public,anon;
grant execute on function public.english_get_review_due_lane(text) to authenticated;

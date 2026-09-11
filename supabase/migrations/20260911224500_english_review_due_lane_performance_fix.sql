-- Review Due lane performance hardening.
-- Preserve exact selection semantics while replacing the per-concept full-bank scan
-- with indexed concept candidate lookup. This fixes browser/PostgREST timeouts when
-- the actionable Review Due set is large.

create or replace function public.english_get_review_due_lane(p_nonce text default null)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with params as (
  select auth.uid() uid,
         (now() at time zone 'Asia/Kolkata')::date today,
         english.review_due_cross_credit_enabled() cross_credit
), obligations as materialized (
  select o.*
  from english.review_due_obligations o
  join params p on p.uid=o.user_id and p.today=o.due_date
), status as materialized (
  select o.*,
         e.resolution_status,
         e.strict_question_id,
         e.last_wrong_at,
         e.last_wrong_question_id,
         e.low_confidence_question_id
  from obligations o
  cross join params p
  cross join lateral english.review_due_evidence_status(p.uid,p.today,o.concept_key) e
  where e.resolution_status<>'satisfied'
), ranked as materialized (
  select
    s.*,
    c.question_id,
    case
      when s.origin_due_date<s.due_date then 'Missed scheduled review carryover'
      when not p.cross_credit and s.resolution_status='needs_repair' then 'Retry the scheduled due word after repair'
      when not p.cross_credit and s.resolution_status='low_confidence' then 'Confirm the scheduled due word with stronger evidence'
      when s.resolution_status='needs_repair' then 'Fresh recovery evidence'
      when s.resolution_status='low_confidence' then 'Confirm without guess / low-information evidence'
      else 'Scheduled review due today'
    end selection_reason,
    row_number() over(
      partition by s.concept_key
      order by
        case
          when c.question_id=any(s.due_question_ids)
            and not exists(
              select 1
              from english.attempts a
              where a.user_id=p.uid
                and a.question_id=c.question_id
                and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
            ) then 0
          when c.question_id=any(s.due_question_ids) then 1
          when not exists(
            select 1
            from english.attempts a
            where a.user_id=p.uid
              and a.question_id=c.question_id
              and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
          ) then 2
          else 3
        end,
        coalesce(qm.too_easy,false),
        coalesce(qs.last_attempt,'epoch'::timestamptz),
        c.question_id
    ) rn
  from status s
  cross join params p
  cross join lateral (
    -- Canonical mapping path: indexed by concept_id.
    select m.question_id
    from english.question_concept_mappings m
    where m.concept_id=s.concept_key

    union

    -- Fallback for a question with concept_id but no explicit canonical mapping.
    select q0.question_id
    from english.questions q0
    where q0.concept_id=s.concept_key
      and not exists(
        select 1
        from english.question_concept_mappings mx
        where mx.question_id=q0.question_id
      )

    union

    -- Final identity fallback, matching review_due_concept_key semantics.
    select q0.question_id
    from english.questions q0
    where q0.question_id=s.concept_key
      and nullif(q0.concept_id,'') is null
      and not exists(
        select 1
        from english.question_concept_mappings mx
        where mx.question_id=q0.question_id
      )
  ) c
  join english.questions q on q.question_id=c.question_id
  left join english.question_state qs
    on qs.user_id=p.uid and qs.question_id=c.question_id
  left join english.question_quality_metrics qm
    on qm.user_id=p.uid and qm.question_id=c.question_id
  where q.active
    and english.question_visible_to_user(p.uid,c.question_id)
    and not coalesce(qs.mastered,false)
    and (p.cross_credit or c.question_id=any(s.due_question_ids))
), picked as (
  select *
  from ranked
  where rn=1
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
        'reviewDueOriginDate',p.origin_due_date,
        'reviewDueCarryover',(p.origin_due_date<p.due_date),
        'reviewDueConcept',p.concept_key,
        'reviewDueStatus',p.resolution_status,
        'reviewDueQuestionCount',p.due_question_count,
        'reviewDueCrossCreditEnabled',x.cross_credit,
        'selectionReason',p.selection_reason
      ) item
  from picked p
  cross join params x
)
select case
  when (select uid from params) is null then jsonb_build_array()
  else coalesce(
    jsonb_agg(
      item
      order by
        case when (item->>'reviewDueCarryover')::boolean then 0 else 1 end,
        concept_key
    ),
    '[]'::jsonb
  )
end
from payload;
$function$;

revoke all on function public.english_get_review_due_lane(text) from public,anon;
grant execute on function public.english_get_review_due_lane(text) to authenticated,service_role;

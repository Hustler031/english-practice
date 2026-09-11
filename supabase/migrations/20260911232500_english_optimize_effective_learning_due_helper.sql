-- Optimize the effective-learning-due diagnostic helper.
-- Concept-due rows are canonical concept IDs, so resolve siblings through the indexed
-- question_concept_mappings table instead of recalculating focus_concept_key across the full bank.

create or replace function english.effective_learning_due(
  p_user_id uuid,
  p_question_id text,
  p_batch_date date default ((now() at time zone 'Asia/Kolkata')::date)
)
returns table(
  concept_key text,
  question_id text,
  source_question_id text,
  question_due timestamptz,
  source_question_due timestamptz,
  concept_due timestamptz,
  effective_due timestamptz,
  due_source text,
  routing_mode text,
  question_due_by_date boolean,
  concept_due_by_date boolean,
  concept_clock_leads boolean,
  alternate_available boolean,
  fresh_alternate_available boolean,
  question_state text,
  concept_state text,
  concept_confidence numeric
)
language sql
stable
security definer
set search_path='pg_catalog','english','auth'
as $function$
with target as (
  select
    q.question_id,
    english.focus_concept_key(q.question_id) concept_key,
    s.next_review question_due,
    coalesce(s.status,'New') question_state,
    ce.next_review concept_due,
    coalesce(ce.coverage_state,'unseen') concept_state,
    coalesce(ce.confidence_score,0) concept_confidence
  from english.questions q
  left join english.question_state s
    on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.concept_evidence ce
    on ce.user_id=p_user_id and ce.concept_id=english.focus_concept_key(q.question_id)
  where q.question_id=p_question_id
    and q.active
    and english.question_visible_to_user(p_user_id,q.question_id)
), sibling_ids as materialized (
  select distinct m.question_id
  from target t
  join english.question_concept_mappings m on m.concept_id=t.concept_key
  union
  select t.question_id from target t
), source_q as (
  select s.question_id,s.next_review
  from sibling_ids x
  join english.question_state s
    on s.user_id=p_user_id and s.question_id=x.question_id
  where coalesce(s.attempts,0)>0
  order by s.last_attempt desc nulls last,s.question_id
  limit 1
), variants as (
  select
    count(*) filter(
      where x.question_id is distinct from sq.question_id
        and q2.active
        and english.question_visible_to_user(p_user_id,q2.question_id)
        and not coalesce(s2.mastered,false)
    )::int alternate_count,
    count(*) filter(
      where x.question_id is distinct from sq.question_id
        and q2.active
        and english.question_visible_to_user(p_user_id,q2.question_id)
        and not coalesce(s2.mastered,false)
        and coalesce(s2.attempts,0)=0
    )::int fresh_alternate_count
  from sibling_ids x
  join english.questions q2 on q2.question_id=x.question_id
  left join source_q sq on true
  left join english.question_state s2
    on s2.user_id=p_user_id and s2.question_id=x.question_id
), calc as (
  select
    t.*,
    sq.question_id source_question_id,
    sq.next_review source_question_due,
    coalesce(v.alternate_count,0)>0 alternate_available,
    coalesce(v.fresh_alternate_count,0)>0 fresh_alternate_available,
    ((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata') day_end
  from target t
  left join source_q sq on true
  cross join variants v
), flags as (
  select c.*,
    (c.question_due is not null and c.question_due<=c.day_end) question_due_by_date,
    (c.concept_due is not null and c.concept_due<=c.day_end) concept_due_by_date,
    (
      c.concept_due is not null
      and (c.source_question_due is null or c.concept_due<c.source_question_due)
    ) concept_clock_leads
  from calc c
)
select
  f.concept_key,
  f.question_id,
  f.source_question_id,
  f.question_due,
  f.source_question_due,
  f.concept_due,
  case
    when f.concept_due_by_date and f.concept_clock_leads and f.alternate_available then f.concept_due
    else f.source_question_due
  end effective_due,
  case
    when f.concept_due_by_date and f.concept_clock_leads and f.alternate_available then 'concept'
    when f.source_question_due is not null then 'question'
    else 'none'
  end due_source,
  case
    when f.concept_due_by_date and f.concept_clock_leads and f.alternate_available then 'concept_validation'
    when f.source_question_due is not null and f.source_question_due<=f.day_end then 'question_review'
    when f.concept_due_by_date and f.concept_clock_leads and not f.alternate_available then 'wait_for_question_due'
    else 'none'
  end routing_mode,
  f.question_due_by_date,
  f.concept_due_by_date,
  f.concept_clock_leads,
  f.alternate_available,
  f.fresh_alternate_available,
  f.question_state,
  f.concept_state,
  f.concept_confidence
from flags f;
$function$;

revoke all on function english.effective_learning_due(uuid,text,date) from public,anon,authenticated;

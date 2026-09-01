-- Maths Exam Preparation foundation.
-- Scope: SSC Standard Sprint freshness + post-sprint review only.
-- Normal Maths Daily / Chapters / Library / On Demand selectors are intentionally unchanged.

create or replace function maths._sprint_ids(p_uid uuid, p_count integer default 25)
returns text[]
language sql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
with runtime as materialized (
  select r.question_id,r.chapter,r.in_mock,r.profile_total
  from maths._user_runtime(p_uid) r
  where r.academic_eligible and r.runtime_active
),
recent_served as (
  select sq.question_id,max(s.created_at) last_served
  from maths.session_questions sq
  join maths.sessions s on s.session_id=sq.session_id
  where s.user_id=p_uid
    and lower(coalesce(s.mode,''))='section_sprint'
    and s.created_at>=now()-interval '14 days'
  group by sq.question_id
),
recent_attempt as (
  select a.question_id,max(a.attempted_at) last_attempt
  from maths.attempts a
  where a.user_id=p_uid
    and a.attempted_at>=now()-interval '14 days'
  group by a.question_id
),
annotated as (
  select r.*,
         rs.last_served,
         ra.last_attempt,
         (
           coalesce(rs.last_served>=now()-interval '48 hours',false)
           or coalesce(ra.last_attempt>=now()-interval '48 hours',false)
         ) hard_recent,
         greatest(rs.last_served,ra.last_attempt) last_seen
  from runtime r
  left join recent_served rs using(question_id)
  left join recent_attempt ra using(question_id)
),
ranked as (
  select a.*,
         row_number() over(
           partition by a.chapter
           order by
             a.hard_recent asc,
             a.in_mock desc,
             (a.profile_total=0) desc,
             a.last_seen asc nulls first,
             abs(hashtext(a.question_id||clock_timestamp()::text))
         ) chapter_rn,
         abs(hashtext(a.question_id||clock_timestamp()::text)) h
  from annotated a
),
balanced as (
  select question_id,hard_recent,chapter_rn,h
  from ranked
  order by hard_recent asc,chapter_rn asc,h asc
  limit greatest(1,least(coalesce(p_count,25),25))
)
select coalesce(array_agg(question_id order by hard_recent,chapter_rn,h),array[]::text[])
from balanced
$$;

create or replace function public.maths_start_sprint(p_diagnostic boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  ids text[];
begin
  ids:=maths._sprint_ids(uid,25);
  return maths._start_session(
    uid,
    ids,
    'section_sprint',
    'SSC Maths Section Sprint',
    jsonb_build_object(
      'durationSec',900,
      'questionCount',25,
      'marksCorrect',2,
      'marksWrong',-.5,
      'selectionCapture',coalesce(p_diagnostic,false),
      'examMode',true,
      'freshnessPolicy','served_or_attempted',
      'coolingHours',48
    ),
    false
  );
end
$$;

create or replace function public.maths_get_sprint_review(p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  items jsonb;
begin
  if not exists(
    select 1 from maths.sessions s
    where s.user_id=uid
      and s.session_id=p_session_id
      and lower(coalesce(s.mode,''))='section_sprint'
      and s.completed
  ) then
    raise exception 'Completed Sprint not found';
  end if;

  with rows as (
    select
      sq.position,
      sq.question_id,
      q.chapter,
      q.topic,
      q.subtopic,
      q.prompt,
      q.answer,
      q.explanation,
      q.correct_option,
      a.attempt_id,
      a.client_attempt_key,
      a.result,
      a.selected_option,
      a.response_sec,
      pe.baseline_sec,
      pe.inferred_reason,
      pe.user_confirmed_reason,
      pe.final_reason,
      pe.inference_confidence,
      pe.slow_correct
    from maths.session_questions sq
    join maths.runtime_questions q on q.question_id=sq.question_id
    left join maths.attempts a
      on a.user_id=uid
     and a.session_id=p_session_id
     and a.question_id=sq.question_id
    left join lateral (
      select e.*
      from maths.performance_evidence e
      where e.user_id=uid
        and e.session_id=p_session_id
        and e.question_id=sq.question_id
      order by e.created_at desc
      limit 1
    ) pe on true
    where sq.session_id=p_session_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'position',position,
      'questionId',question_id,
      'chapter',chapter,
      'topic',topic,
      'subtopic',subtopic,
      'prompt',prompt,
      'answer',answer,
      'explanation',explanation,
      'correctOption',correct_option,
      'attemptId',coalesce(attempt_id,client_attempt_key),
      'result',coalesce(result,'unattempted'),
      'selectedOption',selected_option,
      'responseSec',response_sec,
      'baselineSec',baseline_sec,
      'inferredReason',inferred_reason,
      'confirmedReason',user_confirmed_reason,
      'finalReason',final_reason,
      'inferenceConfidence',inference_confidence,
      'slowCorrect',coalesce(slow_correct,false)
    ) order by position
  ) filter (
    where coalesce(result,'unattempted')<>'correct'
       or coalesce(slow_correct,false)
  ),'[]'::jsonb)
  into items
  from rows;

  return jsonb_build_object('ok',true,'sessionId',p_session_id,'items',items);
end
$$;

grant execute on function public.maths_start_sprint(boolean) to authenticated;
grant execute on function public.maths_get_sprint_review(text) to authenticated;

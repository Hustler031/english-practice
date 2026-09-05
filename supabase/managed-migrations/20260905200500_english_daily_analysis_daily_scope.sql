-- Daily Analysis is a review of today's Daily plan, not a dump of every English attempt made today.
-- Keep current state/evidence for inspection, but classify rows by the reason they entered today's Daily plan.

create or replace function english.daily_analysis_base(p_user_id uuid)
returns table(
  question_id text,
  display_name text,
  topic text,
  current_state text,
  daily_reason text,
  concept_state text,
  concept_id text,
  attempts_today integer,
  wrong_today integer,
  latest_selected text,
  latest_correct boolean,
  last_attempt timestamptz,
  total_attempts integer,
  total_wrong integer,
  accuracy numeric,
  is_persistent_weak boolean,
  is_weak boolean,
  is_retention_risk boolean,
  is_fragile_learning boolean,
  is_due_revision boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with params as (
  select (now() at time zone 'Asia/Kolkata')::date today
), daily_today as (
  select d.question_id,d.reason,d.concept_id
  from english.daily_current d cross join params p
  where d.user_id=p_user_id and d.quiz_date=p.today
), attempt_today as (
  select a.question_id,
         count(*)::int attempts_today,
         count(*) filter(where not a.correct)::int wrong_today,
         max(a.attempted_at) last_attempt
  from english.attempts a cross join params p
  join daily_today d on d.question_id=a.question_id
  where a.user_id=p_user_id
    and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
  group by a.question_id
), latest_today as (
  select distinct on (a.question_id)
         a.question_id,a.selected_answer latest_selected,a.correct latest_correct,a.attempted_at
  from english.attempts a cross join params p
  join daily_today d on d.question_id=a.question_id
  where a.user_id=p_user_id
    and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
  order by a.question_id,a.attempted_at desc,a.attempt_id desc
), mapped as (
  select d.question_id,d.reason,
         coalesce(nullif(q.concept_id,''),nullif(d.concept_id,''),m.concept_id) concept_id,
         q.word,q.question,q.topic
  from daily_today d
  join english.questions q on q.question_id=d.question_id and q.active
  left join lateral (
    select qm.concept_id
    from english.question_concept_mappings qm
    where qm.question_id=d.question_id
    order by coalesce(qm.mapping_confidence,0) desc,qm.updated_at desc nulls last
    limit 1
  ) m on true
  where english.question_visible_to_user(p_user_id,d.question_id)
)
select
  m.question_id,
  coalesce(nullif(btrim(m.word),''),nullif(btrim(c.name),''),nullif(left(btrim(m.question),92),''),'English question') display_name,
  coalesce(nullif(btrim(m.topic),''),'English') topic,
  coalesce(qs.status,'New') current_state,
  m.reason daily_reason,
  ce.coverage_state concept_state,
  m.concept_id,
  coalesce(at.attempts_today,0) attempts_today,
  coalesce(at.wrong_today,0) wrong_today,
  lt.latest_selected,
  lt.latest_correct,
  coalesce(at.last_attempt,qs.last_attempt) last_attempt,
  coalesce(qs.attempts,0) total_attempts,
  coalesce(qs.wrong,0) total_wrong,
  coalesce(qs.accuracy,0) accuracy,
  (coalesce(m.reason,'')='Persistent Weak') is_persistent_weak,
  (coalesce(m.reason,'')='Weak') is_weak,
  (coalesce(ce.coverage_state,'')='retention_risk') is_retention_risk,
  (coalesce(m.reason,'') in ('Fragile','Learning')) is_fragile_learning,
  (coalesce(m.reason,'')='Due Spaced Revision') is_due_revision
from mapped m
left join english.question_state qs on qs.user_id=p_user_id and qs.question_id=m.question_id
left join attempt_today at on at.question_id=m.question_id
left join latest_today lt on lt.question_id=m.question_id
left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
left join english.concepts c on c.concept_id=m.concept_id;
$function$;

revoke all on function english.daily_analysis_base(uuid) from public,anon,authenticated;
grant execute on function english.daily_analysis_base(uuid) to service_role;

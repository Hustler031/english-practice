-- For dates before retention snapshots existed, reconstruct Retention Risk from evidence
-- available at that historical date rather than reclassifying old Daily rows from today's state.
-- Once an archive snapshot exists, it is authoritative (including an explicit false value).

create or replace function english.daily_analysis_occurrences(p_user_id uuid,p_range text default 'today')
returns table(
  quiz_date date,
  question_id text,
  display_name text,
  topic text,
  current_state text,
  daily_reason text,
  concept_state text,
  concept_id text,
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
  select
    (now() at time zone 'Asia/Kolkata')::date today,
    case lower(btrim(coalesce(p_range,'today')))
      when 'today' then (now() at time zone 'Asia/Kolkata')::date
      when '7d' then (now() at time zone 'Asia/Kolkata')::date-6
      when 'overall' then null::date
      else (now() at time zone 'Asia/Kolkata')::date
    end start_date
), daily_rows as (
  select d.quiz_date,d.question_id,d.reason,d.concept_id
  from english.daily_current d cross join params p
  where d.user_id=p_user_id and (p.start_date is null or d.quiz_date>=p.start_date)
  union all
  select h.quiz_date,h.question_id,h.reason,h.concept_id
  from english.daily_history h cross join params p
  where h.user_id=p_user_id and (p.start_date is null or h.quiz_date>=p.start_date)
), mapped as (
  select d.quiz_date,d.question_id,d.reason,
         coalesce(nullif(q.concept_id,''),nullif(d.concept_id,''),m.concept_id) concept_id,
         q.word,q.question,q.topic
  from daily_rows d
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
  m.quiz_date,
  m.question_id,
  coalesce(nullif(btrim(m.word),''),nullif(btrim(c.name),''),nullif(left(btrim(m.question),92),''),'English question') display_name,
  coalesce(nullif(btrim(m.topic),''),'English') topic,
  coalesce(qs.status,'New') current_state,
  m.reason daily_reason,
  ce.coverage_state concept_state,
  m.concept_id,
  coalesce(qs.attempts,0) total_attempts,
  coalesce(qs.wrong,0) total_wrong,
  coalesce(qs.accuracy,0) accuracy,
  (coalesce(m.reason,'')='Persistent Weak') is_persistent_weak,
  (coalesce(m.reason,'') in ('Weak','Weak / Wrong')) is_weak,
  (
    (m.quiz_date=(select today from params) and coalesce(ce.coverage_state,'')='retention_risk')
    or (m.quiz_date<(select today from params) and rh.question_id is not null and rh.is_retention_risk)
    or (
      m.quiz_date<(select today from params)
      and rh.question_id is null
      and exists(
        select 1 from english.attempts a
        where a.user_id=p_user_id and a.question_id=m.question_id and a.correct
          and (a.attempted_at at time zone 'Asia/Kolkata')::date<m.quiz_date
      )
      and exists(
        select 1 from english.attempts a
        where a.user_id=p_user_id and a.question_id=m.question_id and not a.correct
          and (a.attempted_at at time zone 'Asia/Kolkata')::date between m.quiz_date-6 and m.quiz_date
      )
    )
  ) is_retention_risk,
  (coalesce(m.reason,'') in ('Fragile','Learning')) is_fragile_learning,
  (coalesce(m.reason,'') in ('Due Spaced Revision','Due Revision')) is_due_revision
from mapped m
left join english.question_state qs on qs.user_id=p_user_id and qs.question_id=m.question_id
left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
left join english.concepts c on c.concept_id=m.concept_id
left join english.daily_analysis_retention_history rh
  on rh.user_id=p_user_id and rh.quiz_date=m.quiz_date and rh.question_id=m.question_id;
$function$;

revoke all on function english.daily_analysis_occurrences(uuid,text) from public,anon,authenticated;
grant execute on function english.daily_analysis_occurrences(uuid,text) to service_role;

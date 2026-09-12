-- Shared revision recency for My Saved + Starred.
-- Any durable concept attempt after membership counts as a revision for recency/rotation,
-- regardless of delivery module. Outcome/state remains owned by Central Intelligence.
-- Review Due semantics are intentionally untouched.

create or replace function english.saved_revision_candidates_all(p_user_id uuid)
returns table(
  question_id text,
  state text,
  due boolean,
  difficult boolean,
  starred boolean,
  mastered boolean,
  controlled_new boolean,
  never_revised boolean,
  revised_count integer,
  last_revision timestamptz,
  days_since_revision integer,
  created_at timestamptz
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with qmap as materialized (
  select distinct on (m.question_id)
    m.question_id,
    m.concept_id
  from english.question_concept_mappings m
  order by m.question_id,coalesce(m.mapping_confidence,0) desc,m.updated_at desc nulls last,m.concept_id
),
saved as materialized (
  select
    si.practice_question_id question_id,
    min(si.created_at) created_at,
    coalesce(qm.concept_id,si.practice_question_id) concept_key
  from english.saved_items si
  left join qmap qm on qm.question_id=si.practice_question_id
  where si.user_id=p_user_id
    and si.active
    and nullif(btrim(si.practice_question_id),'') is not null
  group by si.practice_question_id,coalesce(qm.concept_id,si.practice_question_id)
),
attempt_base as materialized (
  select
    coalesce(qm.concept_id,nullif(a.concept_id,''),a.question_id) concept_key,
    a.attempted_at
  from english.attempts a
  left join qmap qm on qm.question_id=a.question_id
  where a.user_id=p_user_id
),
activity as materialized (
  select
    s.question_id,
    count(ab.concept_key)::int lifetime_attempts,
    count(ab.concept_key) filter(where ab.attempted_at>=s.created_at)::int revised_count,
    max(ab.attempted_at) filter(where ab.attempted_at>=s.created_at) last_revision
  from saved s
  left join attempt_base ab on ab.concept_key=s.concept_key
  group by s.question_id
)
select
  q.question_id,
  coalesce(qs.status,'New') state,
  (qs.next_review is not null and qs.next_review <= (((now() at time zone 'Asia/Kolkata')::date + 1)::timestamp at time zone 'Asia/Kolkata')) due,
  coalesce(d.difficult,false) difficult,
  coalesce(qs.last_marked,false) starred,
  coalesce(qs.mastered,false) mastered,
  coalesce(a.lifetime_attempts,0)=0 controlled_new,
  coalesce(a.revised_count,0)=0 never_revised,
  coalesce(a.revised_count,0) revised_count,
  a.last_revision,
  case when a.last_revision is null then null else greatest(0,floor(extract(epoch from (now()-a.last_revision))/86400)::int) end days_since_revision,
  s.created_at
from saved s
join english.questions q on q.question_id=s.question_id and q.active
left join english.question_state qs on qs.user_id=p_user_id and qs.question_id=q.question_id
left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
left join activity a on a.question_id=q.question_id;
$function$;

create or replace function english.starred_revision_candidates(p_user_id uuid)
returns table(
  question_id text,
  state text,
  due boolean,
  difficult boolean,
  controlled_new boolean,
  never_revised boolean,
  revised_count integer,
  last_revision timestamptz,
  days_since_revision integer,
  origin_day integer
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with qmap as materialized (
  select distinct on (m.question_id)
    m.question_id,
    m.concept_id
  from english.question_concept_mappings m
  order by m.question_id,coalesce(m.mapping_confidence,0) desc,m.updated_at desc nulls last,m.concept_id
),
latest_star as materialized (
  select distinct on (e.question_id)
    e.question_id,
    e.event_at membership_at,
    e.action,
    greatest(1,coalesce(e.day_no,english.daily_day_no(coalesce(e.starred_date,(e.event_at at time zone 'Asia/Kolkata')::date)),1))::int origin_day,
    coalesce(qm.concept_id,e.question_id) concept_key
  from english.star_events e
  left join qmap qm on qm.question_id=e.question_id
  where e.user_id=p_user_id
  order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
),
current_star as materialized (
  select
    qs.question_id,
    ls.membership_at,
    ls.origin_day,
    coalesce(ls.concept_key,qs.question_id) concept_key
  from english.question_state qs
  join latest_star ls on ls.question_id=qs.question_id
  join english.questions q on q.question_id=qs.question_id and q.active
  where qs.user_id=p_user_id
    and coalesce(qs.last_marked,false)
    and not coalesce(qs.mastered,false)
),
attempt_base as materialized (
  select
    coalesce(qm.concept_id,nullif(a.concept_id,''),a.question_id) concept_key,
    a.attempted_at
  from english.attempts a
  left join qmap qm on qm.question_id=a.question_id
  where a.user_id=p_user_id
),
activity as materialized (
  select
    s.question_id,
    count(ab.concept_key)::int lifetime_attempts,
    count(ab.concept_key) filter(where ab.attempted_at>=s.membership_at)::int revised_count,
    max(ab.attempted_at) filter(where ab.attempted_at>=s.membership_at) last_revision
  from current_star s
  left join attempt_base ab on ab.concept_key=s.concept_key
  group by s.question_id
)
select
  q.question_id,
  coalesce(qs.status,'New') state,
  (qs.next_review is not null and qs.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) due,
  coalesce(d.difficult,false) difficult,
  coalesce(a.lifetime_attempts,0)=0 controlled_new,
  coalesce(a.revised_count,0)=0 never_revised,
  coalesce(a.revised_count,0) revised_count,
  a.last_revision,
  case when a.last_revision is null then null else greatest(0,floor(extract(epoch from (now()-a.last_revision))/86400)::int) end days_since_revision,
  s.origin_day
from current_star s
join english.questions q on q.question_id=s.question_id and q.active
join english.question_state qs on qs.user_id=p_user_id and qs.question_id=q.question_id
left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
left join activity a on a.question_id=q.question_id;
$function$;

comment on function english.saved_revision_candidates_all(uuid) is
  'My Saved revision recency is concept-level and cross-module after Saved membership; outcome/state remains separate.';

comment on function english.starred_revision_candidates(uuid) is
  'Starred revision recency is concept-level and cross-module after current Starred membership; outcome/state remains separate.';

-- My Saved first-exposure SLA
-- Preserve Tier-1/Tier-2 Repair priority, then guarantee a Ready saved item
-- a Repair opportunity by its second fresh Focus batch when it has not yet
-- been practised through any saved practice question for that concept.

create or replace function english.saved_first_exposure_status(
  p_user_id uuid,
  p_batch_date date
)
returns table(
  concept_key text,
  question_id text,
  ready_at timestamptz,
  prior_fresh_batches integer,
  due_now boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with ready_rows as materialized (
  select
    english.focus_concept_key(si.practice_question_id) concept_key,
    si.practice_question_id,
    coalesce(si.gpt_updated_at,si.updated_at,si.created_at) ready_at
  from english.saved_items si
  join english.questions q
    on q.question_id=si.practice_question_id
   and q.active
  left join english.question_state qs
    on qs.user_id=p_user_id
   and qs.question_id=si.practice_question_id
  where si.user_id=p_user_id
    and si.active
    and lower(btrim(coalesce(si.gpt_status,'')))='ready'
    and nullif(btrim(si.practice_question_id),'') is not null
    and not coalesce(qs.mastered,false)
), grouped as materialized (
  select
    r.concept_key,
    (array_agg(r.practice_question_id order by r.ready_at,r.practice_question_id))[1] question_id,
    min(r.ready_at) ready_at,
    array_agg(distinct r.practice_question_id) saved_question_ids
  from ready_rows r
  where nullif(r.concept_key,'') is not null
  group by r.concept_key
), status as materialized (
  select
    g.concept_key,
    g.question_id,
    g.ready_at,
    (
      select count(*)::int
      from english.daily_focus_batches b
      where b.user_id=p_user_id
        and b.batch_date<p_batch_date
        and b.created_at>=g.ready_at
    ) prior_fresh_batches,
    exists(
      select 1
      from english.attempts a
      where a.user_id=p_user_id
        and a.question_id=any(g.saved_question_ids)
        and a.attempted_at>=g.ready_at
    ) practised
  from grouped g
)
select
  s.concept_key,
  s.question_id,
  s.ready_at,
  s.prior_fresh_batches,
  (not s.practised and s.prior_fresh_batches>=1) due_now
from status s;
$function$;

create or replace function english.learning_need_repair_selection(
  p_user_id uuid,
  p_batch_date date,
  p_limit integer default 70
)
returns table(
  concept_key text,
  question_id text,
  primary_need text,
  need_tier integer,
  priority_score integer,
  reasons text[],
  state text,
  targeted_kind text,
  targeted_reason text,
  saved boolean,
  starred boolean,
  never_revised boolean,
  neglect_days integer,
  difficult boolean,
  recent_failures integer,
  confusion_count integer,
  in_fast_track boolean,
  last_attempt timestamptz,
  selection_lane text
)
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with allc as materialized (
  select * from english.learning_need_candidates(p_user_id,p_batch_date)
), sla as materialized (
  select *
  from english.saved_first_exposure_status(p_user_id,p_batch_date)
  where due_now
), eligible as materialized (
  select
    c.concept_key,
    case
      when s.question_id is not null then s.question_id
      else c.question_id
    end question_id,
    c.primary_need,c.need_tier,c.priority_score,c.reasons,c.state,
    c.targeted_kind,c.targeted_reason,c.saved,c.starred,c.never_revised,
    c.neglect_days,c.difficult,c.recent_failures,c.confusion_count,
    c.in_fast_track,c.last_attempt,
    (s.question_id is not null) saved_sla_due,
    s.ready_at saved_ready_at,
    s.prior_fresh_batches saved_prior_fresh_batches
  from allc c
  left join sla s using(concept_key)
  where not english.focus_conflicts_with_required_daily(
    p_user_id,
    case when s.question_id is not null then s.question_id else c.question_id end,
    p_batch_date
  )
), critical as materialized (
  select e.*
  from eligible e
  where e.need_tier<=2
  order by e.need_tier,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit least(50,greatest(0,least(70,coalesce(p_limit,70))))
), saved_sla as materialized (
  select e.*
  from eligible e
  where e.need_tier>=3
    and e.saved_sla_due
    and not exists(select 1 from critical c where c.concept_key=e.concept_key)
  order by
    case when e.saved_prior_fresh_batches=1 then 0 else 1 end,
    e.saved_ready_at,
    e.priority_score desc,
    e.concept_key
  limit greatest(
    0,
    least(70,coalesce(p_limit,70))-(select count(*) from critical)
  )
), rotation as materialized (
  select e.*
  from eligible e
  where e.need_tier>=3
    and (e.saved or e.starred)
    and (e.never_revised or e.neglect_days>=7)
    and not exists(select 1 from critical c where c.concept_key=e.concept_key)
    and not exists(select 1 from saved_sla s where s.concept_key=e.concept_key)
  order by e.never_revised desc,e.neglect_days desc,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit least(
    15,
    greatest(
      0,
      least(70,coalesce(p_limit,70))
        -(select count(*) from critical)
        -(select count(*) from saved_sla)
    )
  )
), selected_seed as materialized (
  select c.*,'critical'::text selection_lane from critical c
  union all
  select s.*,'saved_sla'::text selection_lane from saved_sla s
  union all
  select r.*,'rotation'::text selection_lane from rotation r
), fill as materialized (
  select e.*,'adaptive_fill'::text selection_lane
  from eligible e
  where not exists(select 1 from selected_seed s where s.concept_key=e.concept_key)
  order by e.need_tier,e.priority_score desc,e.last_attempt nulls first,e.concept_key
  limit greatest(
    0,
    least(70,coalesce(p_limit,70))-(select count(*) from selected_seed)
  )
)
select
  s.concept_key,s.question_id,s.primary_need,s.need_tier,s.priority_score,
  s.reasons,s.state,s.targeted_kind,s.targeted_reason,s.saved,s.starred,
  s.never_revised,s.neglect_days,s.difficult,s.recent_failures,
  s.confusion_count,s.in_fast_track,s.last_attempt,s.selection_lane
from selected_seed s
union all
select
  f.concept_key,f.question_id,f.primary_need,f.need_tier,f.priority_score,
  f.reasons,f.state,f.targeted_kind,f.targeted_reason,f.saved,f.starred,
  f.never_revised,f.neglect_days,f.difficult,f.recent_failures,
  f.confusion_count,f.in_fast_track,f.last_attempt,f.selection_lane
from fill f;
$function$;

comment on function english.saved_first_exposure_status(uuid,date) is
'My Saved first-exposure SLA. A Ready saved concept is due on its second fresh Focus batch unless one of its saved practice questions has already been attempted. Duplicate saves for the same concept share one SLA.';

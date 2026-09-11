-- Review Due becomes the sole scheduler watch: exact-today obligations plus unresolved carryover.
-- Existing evidence semantics remain unchanged because carryover is materialized into the current day.

alter table english.review_due_obligations
  add column if not exists origin_due_date date,
  add column if not exists carryover_from_date date;

update english.review_due_obligations
set origin_due_date=due_date
where origin_due_date is null;

alter table english.review_due_obligations
  alter column origin_due_date set default ((now() at time zone 'Asia/Kolkata')::date),
  alter column origin_due_date set not null;

create index if not exists review_due_obligations_origin_idx
  on english.review_due_obligations(user_id,origin_due_date,due_date);

create or replace function english.capture_review_due_day(p_user_id uuid,p_due_date date)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth'
as $function$
declare
  v_existing english.review_due_day_runs%rowtype;
  v_questions integer:=0;
  v_concepts integer:=0;
  v_carryover integer:=0;
begin
  if p_user_id is null or p_due_date is null then
    raise exception 'user and due date are required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('english.capture_review_due_day'),
    hashtext(p_user_id::text||':'||p_due_date::text)
  );

  select * into v_existing
  from english.review_due_day_runs
  where user_id=p_user_id and due_date=p_due_date;

  if found then
    select count(*)::int into v_carryover
    from english.review_due_obligations o
    where o.user_id=p_user_id and o.due_date=p_due_date
      and o.origin_due_date<p_due_date;

    return jsonb_build_object(
      'ok',true,'unchanged',true,'date',p_due_date,
      'dueQuestions',v_existing.due_question_count,
      'dueConcepts',v_existing.due_concept_count,
      'carryoverConcepts',coalesce(v_carryover,0),
      'capturedAt',v_existing.captured_at
    );
  end if;

  create temporary table if not exists pg_temp.review_due_capture(
    concept_key text primary key,
    due_question_ids text[] not null,
    due_question_count integer not null,
    states_at_start text[] not null,
    earliest_due_at timestamptz,
    latest_due_at timestamptz,
    origin_due_date date not null,
    carryover_from_date date,
    source text not null
  ) on commit drop;
  truncate pg_temp.review_due_capture;

  with exact_grouped as (
    select
      english.review_due_concept_key(s.question_id) concept_key,
      array_agg(s.question_id order by s.question_id) due_question_ids,
      array_agg(distinct coalesce(nullif(s.status,''),'Learning')) states_at_start,
      min(s.next_review) earliest_due_at,
      max(s.next_review) latest_due_at
    from english.question_state s
    join english.questions q on q.question_id=s.question_id and q.active
    where s.user_id=p_user_id
      and coalesce(s.attempts,0)>0
      and not coalesce(s.mastered,false)
      and s.next_review is not null
      and (s.next_review at time zone 'Asia/Kolkata')::date=p_due_date
    group by english.review_due_concept_key(s.question_id)
  ), latest_prior as (
    select distinct on (o.concept_key)
      o.*
    from english.review_due_obligations o
    where o.user_id=p_user_id and o.due_date<p_due_date
    order by o.concept_key,o.due_date desc
  ), carryover as (
    select
      o.concept_key,
      o.due_question_ids,
      o.states_at_start,
      o.earliest_due_at,
      o.latest_due_at,
      coalesce(o.origin_due_date,o.due_date) origin_due_date,
      o.due_date carryover_from_date
    from latest_prior o
    cross join lateral english.review_due_evidence_status(o.user_id,o.due_date,o.concept_key) e
    where e.resolution_status<>'satisfied'
  ), seed as (
    select
      e.concept_key,e.due_question_ids,e.states_at_start,e.earliest_due_at,e.latest_due_at,
      p_due_date origin_due_date,null::date carryover_from_date,'exact'::text seed_source
    from exact_grouped e
    union all
    select
      c.concept_key,c.due_question_ids,c.states_at_start,c.earliest_due_at,c.latest_due_at,
      c.origin_due_date,c.carryover_from_date,'carryover'::text
    from carryover c
  ), concepts as (
    select distinct concept_key from seed
  ), merged as (
    select
      c.concept_key,
      coalesce((
        select array_agg(distinct qid order by qid)
        from seed s cross join lateral unnest(s.due_question_ids) qid
        where s.concept_key=c.concept_key
      ),'{}'::text[]) due_question_ids,
      coalesce((
        select array_agg(distinct st order by st)
        from seed s cross join lateral unnest(s.states_at_start) st
        where s.concept_key=c.concept_key
      ),'{}'::text[]) states_at_start,
      (select min(s.earliest_due_at) from seed s where s.concept_key=c.concept_key) earliest_due_at,
      (select max(s.latest_due_at) from seed s where s.concept_key=c.concept_key) latest_due_at,
      (select min(s.origin_due_date) from seed s where s.concept_key=c.concept_key) origin_due_date,
      (select max(s.carryover_from_date) from seed s where s.concept_key=c.concept_key) carryover_from_date,
      exists(select 1 from seed s where s.concept_key=c.concept_key and s.seed_source='exact') has_exact,
      exists(select 1 from seed s where s.concept_key=c.concept_key and s.seed_source='carryover') has_carryover
    from concepts c
  )
  insert into pg_temp.review_due_capture(
    concept_key,due_question_ids,due_question_count,states_at_start,
    earliest_due_at,latest_due_at,origin_due_date,carryover_from_date,source
  )
  select
    m.concept_key,m.due_question_ids,cardinality(m.due_question_ids),m.states_at_start,
    m.earliest_due_at,m.latest_due_at,m.origin_due_date,m.carryover_from_date,
    case
      when m.has_exact and m.has_carryover then 'question_state.next_review+carryover'
      when m.has_carryover then 'carryover'
      else 'question_state.next_review'
    end
  from merged m;

  select coalesce(sum(due_question_count),0)::int,count(*)::int,
         count(*) filter(where origin_due_date<p_due_date)::int
    into v_questions,v_concepts,v_carryover
  from pg_temp.review_due_capture;

  insert into english.review_due_day_runs(
    user_id,due_date,captured_at,due_question_count,due_concept_count,snapshot_version
  ) values(
    p_user_id,p_due_date,now(),v_questions,v_concepts,2
  );

  insert into english.review_due_obligations(
    user_id,due_date,concept_key,due_question_ids,due_question_count,
    states_at_start,earliest_due_at,latest_due_at,snapshot_at,source,
    origin_due_date,carryover_from_date
  )
  select
    p_user_id,p_due_date,concept_key,due_question_ids,due_question_count,
    states_at_start,earliest_due_at,latest_due_at,now(),source,
    origin_due_date,carryover_from_date
  from pg_temp.review_due_capture;

  return jsonb_build_object(
    'ok',true,'unchanged',false,'date',p_due_date,
    'dueQuestions',v_questions,'dueConcepts',v_concepts,
    'carryoverConcepts',v_carryover,'capturedAt',now()
  );
end;
$function$;

create or replace function public.english_get_review_due_today()
returns jsonb
language sql
stable
security definer
set search_path='pg_catalog','public','english','auth'
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
  select o.concept_key,o.origin_due_date,e.*
  from obligations o cross join params p
  cross join lateral english.review_due_evidence_status(p.uid,p.today,o.concept_key) e
), totals as (
  select
    count(*)::integer due_at_start,
    count(*) filter(where origin_due_date<(select today from params))::integer carryover,
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
    'carryoverConcepts',coalesce((select carryover from totals),0),
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
    'overdueConcepts',coalesce((select carryover from totals),0),
    'routingChanged',false,
    'countsTowardDailyFocus',false,
    'practiceEnabled',true
  )
end;
$function$;

create or replace function public.english_get_review_due_lane(p_nonce text default null)
returns jsonb
language sql
stable
security definer
set search_path='pg_catalog','public','english','auth'
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
      when s.origin_due_date<s.due_date then 'Missed scheduled review carryover'
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
    left join english.question_state qs on qs.user_id=p.uid and qs.question_id=q.question_id
    left join english.question_quality_metrics qm on qm.user_id=p.uid and qm.question_id=q.question_id
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
        when q.question_id=any(s.due_question_ids)
          and not exists(
            select 1 from english.attempts a
            where a.user_id=p.uid and a.question_id=q.question_id
              and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
          ) then 0
        when q.question_id=any(s.due_question_ids) then 1
        when not exists(
          select 1 from english.attempts a
          where a.user_id=p.uid and a.question_id=q.question_id
            and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
        ) then 2
        else 3
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
        'reviewDueOriginDate',p.origin_due_date,
        'reviewDueCarryover',(p.origin_due_date<p.due_date),
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
    case when (item->>'reviewDueCarryover')::boolean then 0 else 1 end,
    concept_key
  ),'[]'::jsonb)
end
from payload;
$function$;

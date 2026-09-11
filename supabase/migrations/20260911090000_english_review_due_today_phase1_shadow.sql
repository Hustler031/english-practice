-- REVIEW DUE TODAY — PHASE 1 SHADOW ACCOUNTING
-- Additive only. This migration MUST NOT alter existing learning routing, next_review,
-- attempts, mastery, Daily Mix composition, or Daily Focus quotas.

create table if not exists english.review_due_day_runs (
  user_id uuid not null,
  due_date date not null,
  captured_at timestamptz not null default now(),
  due_question_count integer not null default 0,
  due_concept_count integer not null default 0,
  snapshot_version integer not null default 1,
  primary key (user_id,due_date)
);

create table if not exists english.review_due_obligations (
  user_id uuid not null,
  due_date date not null,
  concept_key text not null,
  due_question_ids text[] not null default '{}'::text[],
  due_question_count integer not null default 0,
  states_at_start text[] not null default '{}'::text[],
  earliest_due_at timestamptz,
  latest_due_at timestamptz,
  snapshot_at timestamptz not null default now(),
  source text not null default 'question_state.next_review',
  primary key (user_id,due_date,concept_key),
  foreign key (user_id,due_date)
    references english.review_due_day_runs(user_id,due_date)
    deferrable initially deferred
);

create index if not exists review_due_obligations_user_date_idx
  on english.review_due_obligations(user_id,due_date);

revoke all on english.review_due_day_runs from anon,authenticated;
revoke all on english.review_due_obligations from anon,authenticated;

comment on table english.review_due_day_runs is
  'Immutable per-user IST-day snapshot header for Review Due Today. Phase 1 shadow accounting only.';
comment on table english.review_due_obligations is
  'One same-day review obligation per user + IST date + concept, originating only from question_state.next_review. It does not become a global concept cooldown.';

create or replace function english.review_due_concept_key(p_question_id text)
returns text
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
select coalesce(
  (
    select m.concept_id
    from english.question_concept_mappings m
    where m.question_id=p_question_id
    order by coalesce(m.mapping_confidence,0) desc,m.updated_at desc nulls last,m.concept_id
    limit 1
  ),
  nullif((select q.concept_id from english.questions q where q.question_id=p_question_id),''),
  p_question_id
);
$function$;

create or replace function english.review_due_module_qualifies(p_module text)
returns boolean
language sql
immutable
as $function$
select case
  when lower(btrim(coalesce(p_module,''))) in (
    'daily','dailyfocusrepair','fasttrack','bankcoverage',
    'grammardaily','phrasaldaily','phrasalrevision','targeted',
    'starredrevision','mysavedrevision','hindu','extra','difficult',
    'source','demand','weak','practice','revision','new','reviewduetoday'
  ) then true
  when lower(btrim(coalesce(p_module,''))) like 'grammardaily:%' then true
  when lower(btrim(coalesce(p_module,''))) like 'sprint_%' then true
  when lower(btrim(coalesce(p_module,''))) like 'sprint:%' then true
  else false
end;
$function$;

comment on function english.review_due_module_qualifies(text) is
  'Conservative Phase 1 allow-list for learner-facing attempts that may provide Review Due Today evidence. Blank/unknown provenance does not satisfy an obligation.';

create or replace function english.capture_review_due_day(
  p_user_id uuid,
  p_due_date date
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_existing english.review_due_day_runs%rowtype;
  v_questions integer:=0;
  v_concepts integer:=0;
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
    return jsonb_build_object(
      'ok',true,'unchanged',true,'date',p_due_date,
      'dueQuestions',v_existing.due_question_count,
      'dueConcepts',v_existing.due_concept_count,
      'capturedAt',v_existing.captured_at
    );
  end if;

  with exact_due as (
    select
      s.user_id,
      s.question_id,
      english.review_due_concept_key(s.question_id) concept_key,
      coalesce(nullif(s.status,''),'Learning') state_at_start,
      s.next_review
    from english.question_state s
    join english.questions q
      on q.question_id=s.question_id
     and q.active
    where s.user_id=p_user_id
      and coalesce(s.attempts,0)>0
      and not coalesce(s.mastered,false)
      and s.next_review is not null
      and (s.next_review at time zone 'Asia/Kolkata')::date=p_due_date
  ), grouped as (
    select
      user_id,
      concept_key,
      array_agg(question_id order by question_id) due_question_ids,
      count(*)::integer due_question_count,
      array_agg(distinct state_at_start) states_at_start,
      min(next_review) earliest_due_at,
      max(next_review) latest_due_at
    from exact_due
    group by user_id,concept_key
  )
  select coalesce(sum(due_question_count),0)::integer,count(*)::integer
  into v_questions,v_concepts
  from grouped;

  insert into english.review_due_day_runs(
    user_id,due_date,captured_at,due_question_count,due_concept_count,snapshot_version
  ) values (
    p_user_id,p_due_date,now(),v_questions,v_concepts,1
  );

  insert into english.review_due_obligations(
    user_id,due_date,concept_key,due_question_ids,due_question_count,
    states_at_start,earliest_due_at,latest_due_at,snapshot_at,source
  )
  select
    user_id,p_due_date,concept_key,due_question_ids,due_question_count,
    states_at_start,earliest_due_at,latest_due_at,now(),'question_state.next_review'
  from (
    select
      s.user_id,
      english.review_due_concept_key(s.question_id) concept_key,
      array_agg(s.question_id order by s.question_id) due_question_ids,
      count(*)::integer due_question_count,
      array_agg(distinct coalesce(nullif(s.status,''),'Learning')) states_at_start,
      min(s.next_review) earliest_due_at,
      max(s.next_review) latest_due_at
    from english.question_state s
    join english.questions q
      on q.question_id=s.question_id
     and q.active
    where s.user_id=p_user_id
      and coalesce(s.attempts,0)>0
      and not coalesce(s.mastered,false)
      and s.next_review is not null
      and (s.next_review at time zone 'Asia/Kolkata')::date=p_due_date
    group by s.user_id,english.review_due_concept_key(s.question_id)
  ) x;

  return jsonb_build_object(
    'ok',true,'unchanged',false,'date',p_due_date,
    'dueQuestions',v_questions,'dueConcepts',v_concepts,'capturedAt',now()
  );
end;
$function$;

create or replace function english.capture_review_due_today_all_users()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  r record;
  v_users integer:=0;
begin
  for r in
    select distinct s.user_id
    from english.question_state s
    where coalesce(s.attempts,0)>0
  loop
    perform english.capture_review_due_day(r.user_id,v_day);
    v_users:=v_users+1;
  end loop;

  return jsonb_build_object('ok',true,'date',v_day,'usersCaptured',v_users);
end;
$function$;

create or replace function public.english_get_review_due_today()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with params as (
  select auth.uid() uid,(now() at time zone 'Asia/Kolkata')::date today
), bounds as (
  select
    p.uid,p.today,
    (p.today::timestamp at time zone 'Asia/Kolkata') start_at,
    (((p.today+1)::timestamp) at time zone 'Asia/Kolkata') end_at
  from params p
), run as (
  select r.*
  from english.review_due_day_runs r
  join params p on p.uid=r.user_id and p.today=r.due_date
), obligations as (
  select o.*
  from english.review_due_obligations o
  join params p on p.uid=o.user_id and p.today=o.due_date
), attempt_evidence as (
  select
    a.attempt_id,
    a.question_id,
    a.attempted_at,
    a.correct,
    lower(btrim(coalesce(a.module,''))) module_key,
    english.review_due_module_qualifies(a.module) qualifies,
    english.review_due_concept_key(a.question_id) concept_key,
    exists(
      select 1
      from english.learner_confidence_signals g
      where g.user_id=a.user_id
        and g.attempt_id=a.attempt_id
        and g.signal='guessed'
    ) guessed,
    coalesce(qm.too_easy,false) too_easy
  from english.attempts a
  join bounds b
    on a.user_id=b.uid
   and a.attempted_at>=b.start_at
   and a.attempted_at<b.end_at
  left join english.question_quality_metrics qm
    on qm.user_id=a.user_id and qm.question_id=a.question_id
), per_concept as (
  select
    o.concept_key,
    bool_or(coalesce(a.qualifies,false)) has_qualifying_attempt,
    bool_or(coalesce(a.qualifies,false) and not coalesce(a.correct,false)) has_wrong,
    bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and a.guessed) has_guessed_correct,
    bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and not a.guessed and a.too_easy) has_low_info_correct,
    bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and not a.guessed and not a.too_easy) has_strict_correct,
    bool_or(coalesce(a.qualifies,false) and coalesce(a.correct,false) and not a.guessed and not a.too_easy and a.module_key<>'reviewduetoday') has_strict_correct_elsewhere,
    count(distinct a.module_key) filter(where coalesce(a.qualifies,false)) module_count,
    count(distinct a.question_id) filter(where coalesce(a.qualifies,false)) question_count
  from obligations o
  left join attempt_evidence a on a.concept_key=o.concept_key
  group by o.concept_key
), classified as (
  select
    p.*,
    case
      when p.has_wrong then 'needs_repair'
      when p.has_strict_correct then 'satisfied'
      when p.has_guessed_correct or p.has_low_info_correct then 'low_confidence'
      else 'remaining'
    end shadow_status
  from per_concept p
), overdue as (
  select distinct english.review_due_concept_key(s.question_id) concept_key
  from english.question_state s
  join english.questions q on q.question_id=s.question_id and q.active
  join params p on p.uid=s.user_id
  where coalesce(s.attempts,0)>0
    and not coalesce(s.mastered,false)
    and s.next_review is not null
    and (s.next_review at time zone 'Asia/Kolkata')::date<p.today
), totals as (
  select
    count(*)::integer due_at_start,
    count(*) filter(where shadow_status='satisfied')::integer satisfied,
    count(*) filter(where shadow_status='satisfied' and has_strict_correct_elsewhere)::integer satisfied_elsewhere,
    count(*) filter(where shadow_status='needs_repair')::integer needs_repair,
    count(*) filter(where shadow_status='low_confidence')::integer low_confidence,
    count(*) filter(where shadow_status='remaining')::integer remaining,
    count(*) filter(where module_count>=2 or question_count>=2)::integer duplicate_touches
  from classified
)
select case
  when (select uid from params) is null then jsonb_build_object('ok',false,'reason','Authentication required')
  else jsonb_build_object(
    'ok',true,
    'date',(select today from params),
    'phase','shadow',
    'snapshotReady',exists(select 1 from run),
    'snapshotAt',(select captured_at from run limit 1),
    'dueQuestionCount',coalesce((select due_question_count from run limit 1),0),
    'dueAtStart',coalesce((select due_at_start from totals),0),
    'satisfied',coalesce((select satisfied from totals),0),
    'satisfiedElsewhere',coalesce((select satisfied_elsewhere from totals),0),
    'needsRepair',coalesce((select needs_repair from totals),0),
    'lowConfidence',coalesce((select low_confidence from totals),0),
    'remaining',coalesce((select remaining from totals),0),
    'duplicateTouches',coalesce((select duplicate_touches from totals),0),
    'overdueConcepts',(select count(*) from overdue),
    'routingChanged',false,
    'countsTowardDailyFocus',false
  )
end;
$function$;

grant execute on function public.english_get_review_due_today() to authenticated;
revoke all on function english.capture_review_due_day(uuid,date) from anon,authenticated;
revoke all on function english.capture_review_due_today_all_users() from anon,authenticated;

comment on function public.english_get_review_due_today() is
  'Phase 1 read-only Review Due Today shadow summary. Wrong evidence overrides same-day success; guessed/too-easy correct evidence is low-confidence. Does not alter routing or review clocks.';

-- Capture the exact question-scheduler obligation at 00:00 IST, one minute before
-- the existing primary Daily rollover. This job is independent: failure cannot
-- block attempt saving, Daily Mix, Daily Focus, or rollover.
do $do$
begin
  if not exists(select 1 from cron.job where jobname='english-review-due-snapshot') then
    perform cron.schedule(
      'english-review-due-snapshot',
      '30 18 * * *',
      'select english.capture_review_due_today_all_users();'
    );
  end if;
end
$do$;

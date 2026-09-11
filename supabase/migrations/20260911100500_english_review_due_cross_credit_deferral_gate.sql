-- REVIEW DUE TODAY — CROSS-CONCEPT CREDIT + WORD-CLOCK DEFERRAL GATE
-- Exact due-question evidence is safe immediately because english_submit_answer already
-- recomputes that word/question clock. Sibling concept evidence remains shadow-only until
-- both cross-concept credit and audited end-of-day deferral are enabled.

create table if not exists english.review_due_runtime_config (
  singleton boolean primary key default true check(singleton),
  cross_concept_credit_enabled boolean not null default false,
  auto_deferral_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into english.review_due_runtime_config(singleton,cross_concept_credit_enabled,auto_deferral_enabled)
values(true,false,false)
on conflict(singleton) do nothing;
revoke all on english.review_due_runtime_config from public,anon,authenticated;

create table if not exists english.review_due_question_deferrals (
  user_id uuid not null,
  due_date date not null,
  concept_key text not null,
  question_id text not null,
  evidence_question_id text not null,
  evidence_at timestamptz not null,
  previous_next_review timestamptz,
  defer_until timestamptz not null,
  state_at_deferral text,
  rule text not null default 'cross_concept_strong_evidence',
  created_at timestamptz not null default now(),
  primary key(user_id,due_date,question_id)
);
create index if not exists review_due_question_deferrals_lookup_idx
  on english.review_due_question_deferrals(user_id,question_id,defer_until desc);
revoke all on english.review_due_question_deferrals from public,anon,authenticated;

create or replace function english.review_due_cross_credit_enabled()
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog','english'
as $function$
select coalesce((select cross_concept_credit_enabled from english.review_due_runtime_config where singleton),false);
$function$;
revoke all on function english.review_due_cross_credit_enabled() from public,anon,authenticated;

create or replace function english.review_due_evidence_status(
  p_user_id uuid,
  p_due_date date,
  p_concept_key text
)
returns table(
  shadow_status text,
  resolution_status text,
  strict_correct_at timestamptz,
  strict_question_id text,
  strict_module text,
  last_wrong_at timestamptz,
  last_wrong_question_id text,
  low_confidence_at timestamptz,
  low_confidence_question_id text,
  qualifying_attempts integer,
  module_count integer,
  satisfied_elsewhere boolean
)
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with bounds as (
  select
    (p_due_date::timestamp at time zone 'Asia/Kolkata') start_at,
    (((p_due_date+1)::timestamp) at time zone 'Asia/Kolkata') end_at
), obligation as (
  select o.due_question_ids
  from english.review_due_obligations o
  where o.user_id=p_user_id and o.due_date=p_due_date and o.concept_key=p_concept_key
  limit 1
), mastery as (
  select coalesce(bool_and(coalesce(s.mastered,false)),false) all_due_mastered
  from obligation o
  cross join unnest(o.due_question_ids) qid
  left join english.question_state s on s.user_id=p_user_id and s.question_id=qid
), ev as (
  select
    a.attempt_id,
    a.question_id,
    a.attempted_at,
    lower(btrim(coalesce(a.module,''))) module_key,
    coalesce(a.correct,false) correct,
    english.review_due_module_qualifies(a.module) qualifies,
    exists(
      select 1
      from english.learner_confidence_signals g
      where g.user_id=a.user_id
        and g.attempt_id=a.attempt_id
        and g.signal='guessed'
    ) guessed,
    coalesce(qm.too_easy,false) too_easy
  from english.attempts a
  cross join bounds b
  left join english.question_quality_metrics qm
    on qm.user_id=a.user_id and qm.question_id=a.question_id
  where a.user_id=p_user_id
    and a.attempted_at>=b.start_at
    and a.attempted_at<b.end_at
    and coalesce(nullif(a.concept_id,''),english.review_due_concept_key(a.question_id))=p_concept_key
), agg as (
  select
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and not too_easy))[1] strict_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and not too_easy))[1] strict_q,
    (array_agg(module_key order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and not guessed and not too_easy))[1] strict_mod,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and not correct))[1] wrong_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and not correct))[1] wrong_q,
    (array_agg(attempted_at order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and (guessed or too_easy)))[1] low_at,
    (array_agg(question_id order by attempted_at desc,attempt_id desc)
      filter(where qualifies and correct and (guessed or too_easy)))[1] low_q,
    count(*) filter(where qualifies)::integer attempts_n,
    count(distinct module_key) filter(where qualifies)::integer modules_n
  from ev
), classified as (
  select a.*,
    coalesce((select all_due_mastered from mastery),false) all_due_mastered,
    coalesce((select a.strict_q=any(o.due_question_ids) from obligation o),false) strict_is_exact_due,
    english.review_due_cross_credit_enabled() cross_credit_enabled,
    (
      a.strict_at is not null
      and (
        a.wrong_at is null
        or (
          a.strict_at>a.wrong_at
          and (
            a.strict_q is distinct from a.wrong_q
            or a.strict_at>=a.wrong_at+interval '15 minutes'
          )
        )
      )
    ) recovered
  from agg a
)
select
  case
    when all_due_mastered then 'satisfied'
    when wrong_at is not null then 'needs_repair'
    when strict_at is not null then 'satisfied'
    when low_at is not null then 'low_confidence'
    else 'remaining'
  end shadow_status,
  case
    when all_due_mastered then 'satisfied'
    when recovered and (strict_is_exact_due or cross_credit_enabled) then 'satisfied'
    when wrong_at is not null then 'needs_repair'
    when low_at is not null and (coalesce((select low_q=any(o.due_question_ids) from obligation o),false) or cross_credit_enabled) then 'low_confidence'
    else 'remaining'
  end resolution_status,
  strict_at,
  strict_q,
  strict_mod,
  wrong_at,
  wrong_q,
  low_at,
  low_q,
  coalesce(attempts_n,0),
  coalesce(modules_n,0),
  (
    recovered
    and (strict_is_exact_due or cross_credit_enabled)
    and coalesce(strict_mod,'')<>'reviewduetoday'
  )
from classified;
$function$;
revoke all on function english.review_due_evidence_status(uuid,date,text) from public,anon,authenticated;

create or replace function english.review_due_deferral_days(p_status text)
returns integer
language sql
immutable
as $function$
select case coalesce(p_status,'Learning')
  when 'Persistent Weak' then 1
  when 'Weak' then 1
  when 'Learning' then 1
  when 'Fragile' then 2
  when 'Strong' then 7
  else 1
end;
$function$;
revoke all on function english.review_due_deferral_days(text) from public,anon,authenticated;

create or replace function english.active_review_due_deferral(p_user_id uuid,p_question_id text)
returns timestamptz
language sql
stable security definer
set search_path to 'pg_catalog','english'
as $function$
select max(d.defer_until)
from english.review_due_question_deferrals d
where d.user_id=p_user_id and d.question_id=p_question_id;
$function$;
revoke all on function english.active_review_due_deferral(uuid,text) from public,anon,authenticated;

-- Preserve existing learning-profile behavior, adding only a later central deferral floor.
-- Guess/context overrides can still bring the review earlier because they are applied last.
create or replace function english.recompute_question_state(p_user_id uuid, p_question_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  p record; q english.questions%rowtype; old english.question_state%rowtype;
  v_marked boolean; v_mastered boolean; v_mastered_on timestamptz;
  v_repeat timestamptz; v_recall integer; v_status text; v_next timestamptz;
  v_override timestamptz; v_deferral timestamptz; v_base_next timestamptz;
begin
  select * into q from english.questions where question_id=p_question_id;
  if not found then raise exception 'Question not found'; end if;
  select * into p from english.learning_profile(p_user_id,p_question_id);
  select * into old from english.question_state where user_id=p_user_id and question_id=p_question_id;
  v_repeat:=old.repeat_suppressed_until;
  v_recall:=coalesce(old.recall_check_count,0);

  select case when se.action='STAR' then true else false end into v_marked
  from english.star_events se
  where se.user_id=p_user_id and se.question_id=p_question_id
  order by se.event_at desc,se.id desc limit 1;
  if not found then v_marked:=coalesce(old.last_marked,false); end if;

  select bool_or(me.active and me.restored_on is null),
         max(me.mastered_on) filter(where me.active and me.restored_on is null)
  into v_mastered,v_mastered_on
  from english.mastery_events me
  where me.user_id=p_user_id and me.question_id=p_question_id;
  v_mastered:=coalesce(v_mastered,coalesce(old.mastered,false));
  if v_mastered and v_mastered_on is null then v_mastered_on:=old.mastered_on; end if;
  if not v_mastered then v_mastered_on:=null; v_repeat:=null; end if;
  v_status:=case when v_mastered then 'Mastered' else p.state end;
  v_override:=english.active_review_override_due(p_user_id,p_question_id);
  v_deferral:=english.active_review_due_deferral(p_user_id,p_question_id);
  v_base_next:=case
    when p.next_review is null then v_deferral
    when v_deferral is null then p.next_review
    else greatest(p.next_review,v_deferral)
  end;
  v_next:=case
    when v_mastered then null
    when v_base_next is null then v_override
    when v_override is null then v_base_next
    else least(v_base_next,v_override)
  end;

  insert into english.question_state(
    user_id,question_id,attempts,correct,wrong,accuracy,marked_count,avg_time,
    last_attempt,last_result,last_time,last_marked,correct_streak,status,next_review,
    mastered,mastered_on,repeat_suppressed_until,recall_check_count,updated_at
  ) values(
    p_user_id,p_question_id,p.attempts,p.correct,p.wrong,p.accuracy,p.marked_count,p.avg_time,
    p.last_attempt,p.last_result,p.last_time,v_marked,p.correct_streak,v_status,v_next,
    v_mastered,v_mastered_on,v_repeat,v_recall,now()
  )
  on conflict(user_id,question_id) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,accuracy=excluded.accuracy,
    marked_count=excluded.marked_count,avg_time=excluded.avg_time,last_attempt=excluded.last_attempt,
    last_result=excluded.last_result,last_time=excluded.last_time,last_marked=excluded.last_marked,
    correct_streak=excluded.correct_streak,status=excluded.status,next_review=excluded.next_review,
    mastered=excluded.mastered,mastered_on=excluded.mastered_on,
    repeat_suppressed_until=excluded.repeat_suppressed_until,
    recall_check_count=excluded.recall_check_count,updated_at=excluded.updated_at;

  return jsonb_build_object('question_id',p_question_id,'attempts',p.attempts,'correct',p.correct,'wrong',p.wrong,
    'status',v_status,'next_review',v_next,'base_next_review',p.next_review,'review_override_due',v_override,
    'review_due_deferral',v_deferral,'mastered',v_mastered,'starred',v_marked,'correct_streak',p.correct_streak);
end;
$function$;

create or replace function english.reconcile_review_due_deferrals(p_user_id uuid,p_due_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  cfg english.review_due_runtime_config%rowtype;
  r record;
  qid text;
  s english.question_state%rowtype;
  v_until timestamptz;
  v_created integer:=0;
begin
  select * into cfg from english.review_due_runtime_config where singleton;
  if not coalesce(cfg.cross_concept_credit_enabled,false) or not coalesce(cfg.auto_deferral_enabled,false) then
    return jsonb_build_object('ok',true,'enabled',false,'created',0);
  end if;

  for r in
    select o.concept_key,o.due_question_ids,e.strict_correct_at,e.strict_question_id
    from english.review_due_obligations o
    cross join lateral english.review_due_evidence_status(o.user_id,o.due_date,o.concept_key) e
    where o.user_id=p_user_id and o.due_date=p_due_date
      and e.resolution_status='satisfied'
      and e.strict_correct_at is not null
      and e.strict_question_id is not null
  loop
    foreach qid in array r.due_question_ids loop
      select * into s from english.question_state where user_id=p_user_id and question_id=qid;
      if not found or coalesce(s.mastered,false) or s.next_review is null then continue; end if;
      if (s.next_review at time zone 'Asia/Kolkata')::date>p_due_date then continue; end if;
      if qid=r.strict_question_id then continue; end if;

      v_until:=r.strict_correct_at+make_interval(days=>english.review_due_deferral_days(s.status));
      if v_until<=s.next_review then continue; end if;

      insert into english.review_due_question_deferrals(
        user_id,due_date,concept_key,question_id,evidence_question_id,evidence_at,
        previous_next_review,defer_until,state_at_deferral,rule
      ) values(
        p_user_id,p_due_date,r.concept_key,qid,r.strict_question_id,r.strict_correct_at,
        s.next_review,v_until,s.status,'cross_concept_strong_evidence'
      ) on conflict(user_id,due_date,question_id) do nothing;
      if found then
        v_created:=v_created+1;
        perform english.recompute_question_state(p_user_id,qid);
      end if;
    end loop;
  end loop;

  return jsonb_build_object('ok',true,'enabled',true,'created',v_created);
end;
$function$;
revoke all on function english.reconcile_review_due_deferrals(uuid,date) from public,anon,authenticated;

create or replace function english.reconcile_review_due_deferrals_today_all_users()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  r record;
  v_users integer:=0;
  v_created integer:=0;
  outv jsonb;
begin
  if not coalesce((select cross_concept_credit_enabled and auto_deferral_enabled from english.review_due_runtime_config where singleton),false) then
    return jsonb_build_object('ok',true,'enabled',false,'date',v_day,'users',0,'created',0);
  end if;
  for r in select user_id from english.review_due_day_runs where due_date=v_day loop
    outv:=english.reconcile_review_due_deferrals(r.user_id,v_day);
    v_users:=v_users+1;
    v_created:=v_created+coalesce((outv->>'created')::integer,0);
  end loop;
  return jsonb_build_object('ok',true,'enabled',true,'date',v_day,'users',v_users,'created',v_created);
end;
$function$;
revoke all on function english.reconcile_review_due_deferrals_today_all_users() from public,anon,authenticated;

-- 23:55 IST. The job is installed now but is a no-op while the runtime gates remain false.
do $do$
begin
  if not exists(select 1 from cron.job where jobname='english-review-due-eod-deferral') then
    perform cron.schedule(
      'english-review-due-eod-deferral',
      '25 18 * * *',
      'select english.reconcile_review_due_deferrals_today_all_users();'
    );
  end if;
end
$do$;

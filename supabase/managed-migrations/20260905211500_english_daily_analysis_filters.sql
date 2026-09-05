-- Daily Analysis period filters + read-only attempt-window review.
-- Historical reason-based categories use the reason recorded in Daily history.
-- Retention Risk is snapshotted when a Daily row is archived so future history is not
-- reclassified from a learner's later/current concept state.

create table if not exists english.daily_analysis_retention_history(
  user_id uuid not null,
  quiz_date date not null,
  question_id text not null,
  is_retention_risk boolean not null default false,
  captured_at timestamptz not null default now(),
  primary key(user_id,quiz_date,question_id)
);

alter table english.daily_analysis_retention_history enable row level security;
revoke all on table english.daily_analysis_retention_history from public,anon,authenticated;
grant select,insert,update,delete on table english.daily_analysis_retention_history to service_role;

create or replace function english.capture_daily_analysis_retention_history()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare
  cid text;
  risk boolean:=false;
begin
  cid:=nullif(new.concept_id,'');
  if cid is null then
    select coalesce(nullif(q.concept_id,''),m.concept_id)
    into cid
    from english.questions q
    left join lateral (
      select qm.concept_id
      from english.question_concept_mappings qm
      where qm.question_id=new.question_id
      order by coalesce(qm.mapping_confidence,0) desc,qm.updated_at desc nulls last
      limit 1
    ) m on true
    where q.question_id=new.question_id;
  end if;
  if cid is not null then
    select coalesce(ce.coverage_state='retention_risk',false)
    into risk
    from english.concept_evidence ce
    where ce.user_id=new.user_id and ce.concept_id=cid;
  end if;
  insert into english.daily_analysis_retention_history(user_id,quiz_date,question_id,is_retention_risk,captured_at)
  values(new.user_id,new.quiz_date,new.question_id,coalesce(risk,false),now())
  on conflict(user_id,quiz_date,question_id) do update
    set is_retention_risk=excluded.is_retention_risk,captured_at=excluded.captured_at;
  return new;
end
$function$;

revoke all on function english.capture_daily_analysis_retention_history() from public,anon,authenticated;
grant execute on function english.capture_daily_analysis_retention_history() to service_role;

drop trigger if exists trg_daily_analysis_retention_history on english.daily_history;
create trigger trg_daily_analysis_retention_history
after insert on english.daily_history
for each row execute function english.capture_daily_analysis_retention_history();

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
  where d.user_id=p_user_id
    and (p.start_date is null or d.quiz_date>=p.start_date)
  union all
  select h.quiz_date,h.question_id,h.reason,h.concept_id
  from english.daily_history h cross join params p
  where h.user_id=p_user_id
    and (p.start_date is null or h.quiz_date>=p.start_date)
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
    or coalesce(rh.is_retention_risk,false)
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

create or replace function public.english_get_daily_analysis_questions_filtered(
  p_category text,
  p_range text default 'today',
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  cat text:=lower(btrim(coalesce(p_category,'')));
  range_key text:=lower(btrim(coalesce(p_range,'today')));
  lim integer:=greatest(1,least(300,coalesce(p_limit,200)));
  start_date date;
  rowsv jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if cat not in ('persistent_weak','weak','retention_risk','fragile_learning','due_revision') then
    raise exception 'unknown daily analysis category';
  end if;
  if range_key not in ('today','7d','overall') then raise exception 'unknown daily analysis range'; end if;
  start_date:=case range_key when 'today' then (now() at time zone 'Asia/Kolkata')::date when '7d' then (now() at time zone 'Asia/Kolkata')::date-6 else null end;

  with qualified as (
    select *
    from english.daily_analysis_occurrences(uid,range_key) o
    where case cat
      when 'persistent_weak' then o.is_persistent_weak
      when 'weak' then o.is_weak
      when 'retention_risk' then o.is_retention_risk
      when 'fragile_learning' then o.is_fragile_learning
      when 'due_revision' then o.is_due_revision
      else false end
  ), grouped as (
    select question_id,max(quiz_date) last_daily_date,count(distinct quiz_date)::int days_seen
    from qualified group by question_id
  ), latest_occ as (
    select distinct on (q.question_id) q.*
    from qualified q
    order by q.question_id,q.quiz_date desc
  ), pa as (
    select a.question_id,count(*)::int period_attempts,
           count(*) filter(where not a.correct)::int period_wrong,
           count(*) filter(where a.correct)::int period_correct,
           max(a.attempted_at) last_attempt
    from english.attempts a join grouped g on g.question_id=a.question_id
    where a.user_id=uid
      and (start_date is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=start_date)
    group by a.question_id
  ), la as (
    select distinct on (a.question_id) a.question_id,a.selected_answer,a.correct
    from english.attempts a join grouped g on g.question_id=a.question_id
    where a.user_id=uid
      and (start_date is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=start_date)
    order by a.question_id,a.attempted_at desc,a.attempt_id desc
  ), picked as (
    select l.*,g.last_daily_date,g.days_seen,
           coalesce(pa.period_attempts,0) period_attempts,
           coalesce(pa.period_wrong,0) period_wrong,
           coalesce(pa.period_correct,0) period_correct,
           pa.last_attempt,la.selected_answer latest_selected,la.correct latest_correct
    from latest_occ l join grouped g using(question_id)
    left join pa using(question_id)
    left join la using(question_id)
    order by coalesce(pa.period_wrong,0) desc,coalesce(pa.period_attempts,0) desc,g.last_daily_date desc,l.total_wrong desc,l.display_name
    limit lim
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'questionId',question_id,
    'displayName',display_name,
    'topic',topic,
    'currentState',current_state,
    'dailyReason',daily_reason,
    'conceptState',concept_state,
    'dailyDate',last_daily_date,
    'daysSeen',days_seen,
    'periodAttempts',period_attempts,
    'periodWrong',period_wrong,
    'periodCorrect',period_correct,
    'latestSelected',latest_selected,
    'latestCorrect',latest_correct,
    'lastAttempt',last_attempt,
    'totalAttempts',total_attempts,
    'totalWrong',total_wrong,
    'accuracy',accuracy
  )) order by period_wrong desc,period_attempts desc,last_daily_date desc,total_wrong desc,display_name),'[]'::jsonb)
  into rowsv from picked;

  return jsonb_build_object(
    'ok',true,
    'date',(now() at time zone 'Asia/Kolkata')::date,
    'category',cat,
    'range',range_key,
    'questions',rowsv
  );
end
$function$;

revoke execute on function public.english_get_daily_analysis_questions_filtered(text,text,integer) from public,anon;
grant execute on function public.english_get_daily_analysis_questions_filtered(text,text,integer) to authenticated,service_role;

create or replace function public.english_get_daily_analysis_question_filtered(
  p_category text,
  p_question_id text,
  p_category_range text default 'today',
  p_attempt_range text default 'today'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  cat text:=lower(btrim(coalesce(p_category,'')));
  qid text:=btrim(coalesce(p_question_id,''));
  category_range text:=lower(btrim(coalesce(p_category_range,'today')));
  attempt_range text:=lower(btrim(coalesce(p_attempt_range,'today')));
  category_start date;
  attempt_start date;
  b record;
  days_seen integer:=0;
  payload jsonb;
  revision_payload jsonb;
  attempts_json jsonb:='[]'::jsonb;
  attempt_summary jsonb:='{}'::jsonb;
  period_attempts integer:=0;
  period_wrong integer:=0;
  period_correct integer:=0;
  latest_selected text;
  latest_correct boolean;
  last_attempt timestamptz;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if qid='' then raise exception 'question id required'; end if;
  if cat not in ('persistent_weak','weak','retention_risk','fragile_learning','due_revision') then raise exception 'unknown daily analysis category'; end if;
  if category_range not in ('today','7d','overall') then raise exception 'unknown daily analysis range'; end if;
  if attempt_range not in ('today','7d','overall') then raise exception 'unknown attempt range'; end if;
  category_start:=case category_range when 'today' then (now() at time zone 'Asia/Kolkata')::date when '7d' then (now() at time zone 'Asia/Kolkata')::date-6 else null end;
  attempt_start:=case attempt_range when 'today' then (now() at time zone 'Asia/Kolkata')::date when '7d' then (now() at time zone 'Asia/Kolkata')::date-6 else null end;

  with qualified as (
    select * from english.daily_analysis_occurrences(uid,category_range) o
    where o.question_id=qid and case cat
      when 'persistent_weak' then o.is_persistent_weak
      when 'weak' then o.is_weak
      when 'retention_risk' then o.is_retention_risk
      when 'fragile_learning' then o.is_fragile_learning
      when 'due_revision' then o.is_due_revision
      else false end
  )
  select * into b from qualified order by quiz_date desc limit 1;
  if not found then raise exception 'question is not in this Daily Analysis category for the selected range'; end if;

  select count(distinct o.quiz_date)::int into days_seen
  from english.daily_analysis_occurrences(uid,category_range) o
  where o.question_id=qid and case cat
    when 'persistent_weak' then o.is_persistent_weak
    when 'weak' then o.is_weak
    when 'retention_risk' then o.is_retention_risk
    when 'fragile_learning' then o.is_fragile_learning
    when 'due_revision' then o.is_due_revision
    else false end;

  select count(*)::int,
         count(*) filter(where not a.correct)::int,
         count(*) filter(where a.correct)::int,
         max(a.attempted_at)
  into period_attempts,period_wrong,period_correct,last_attempt
  from english.attempts a
  where a.user_id=uid and a.question_id=qid
    and (category_start is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=category_start);

  select a.selected_answer,a.correct into latest_selected,latest_correct
  from english.attempts a
  where a.user_id=uid and a.question_id=qid
    and (category_start is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=category_start)
  order by a.attempted_at desc,a.attempt_id desc limit 1;

  payload:=english.question_payload(uid,qid);
  if payload is null then raise exception 'question unavailable'; end if;

  select p.proposed_payload into revision_payload
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=uid and r.question_id=qid and p.status='applied'
  order by r.applied_at desc nulls last,r.proposal_version desc
  limit 1;

  if revision_payload is not null then
    payload:=payload||jsonb_strip_nulls(jsonb_build_object(
      'question',nullif(revision_payload->>'question',''),
      'options',jsonb_build_array(
        jsonb_build_object('key','A','text',coalesce(revision_payload->>'optionA',payload->'options'->0->>'text','')),
        jsonb_build_object('key','B','text',coalesce(revision_payload->>'optionB',payload->'options'->1->>'text','')),
        jsonb_build_object('key','C','text',coalesce(revision_payload->>'optionC',payload->'options'->2->>'text','')),
        jsonb_build_object('key','D','text',coalesce(revision_payload->>'optionD',payload->'options'->3->>'text',''))
      ),
      'correctKey',nullif(revision_payload->>'correctKey',''),
      'explanation',nullif(revision_payload->>'explanation',''),
      'revisionApplied',true
    ));
  end if;

  with windowed as (
    select a.*
    from english.attempts a
    where a.user_id=uid and a.question_id=qid
      and (attempt_start is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=attempt_start)
  ), shown as (
    select * from windowed
    order by attempted_at desc,attempt_id desc
    limit case when attempt_range='overall' then 10 else 50 end
  ), summary as (
    select count(*)::int total,
           count(*) filter(where correct)::int correct,
           count(*) filter(where not correct)::int wrong
    from windowed
  ), shown_summary as (
    select count(*)::int shown,
           count(*) filter(where correct)::int shown_correct,
           count(*) filter(where not correct)::int shown_wrong
    from shown
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object(
      'attemptedAt',s.attempted_at,
      'selected',s.selected_answer,
      'correct',s.correct,
      'module',s.module,
      'timeSeconds',s.time_seconds
    ) order by s.attempted_at desc,s.attempt_id desc),'[]'::jsonb) from shown s),
    jsonb_build_object(
      'range',attempt_range,
      'total',summary.total,
      'correct',summary.correct,
      'wrong',summary.wrong,
      'shown',shown_summary.shown,
      'shownCorrect',shown_summary.shown_correct,
      'shownWrong',shown_summary.shown_wrong,
      'truncated',(summary.total>shown_summary.shown)
    )
  into attempts_json,attempt_summary
  from summary cross join shown_summary;

  return jsonb_build_object(
    'ok',true,
    'date',(now() at time zone 'Asia/Kolkata')::date,
    'category',cat,
    'range',category_range,
    'analysis',jsonb_strip_nulls(jsonb_build_object(
      'questionId',b.question_id,
      'displayName',b.display_name,
      'topic',b.topic,
      'currentState',b.current_state,
      'dailyReason',b.daily_reason,
      'conceptState',b.concept_state,
      'dailyDate',b.quiz_date,
      'daysSeen',days_seen,
      'periodAttempts',period_attempts,
      'periodWrong',period_wrong,
      'periodCorrect',period_correct,
      'latestSelected',latest_selected,
      'latestCorrect',latest_correct,
      'lastAttempt',last_attempt,
      'totalAttempts',b.total_attempts,
      'totalWrong',b.total_wrong,
      'accuracy',b.accuracy
    )),
    'question',payload,
    'recentAttempts',attempts_json,
    'attemptSummary',attempt_summary
  );
end
$function$;

revoke execute on function public.english_get_daily_analysis_question_filtered(text,text,text,text) from public,anon;
grant execute on function public.english_get_daily_analysis_question_filtered(text,text,text,text) to authenticated,service_role;

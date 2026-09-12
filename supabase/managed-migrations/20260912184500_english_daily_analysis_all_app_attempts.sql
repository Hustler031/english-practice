-- Daily Analysis v2: all-English-attempt scope, read-only, with period-filtered Proven Mastered transitions.

create or replace function english.proven_mastery_events(p_user_id uuid, p_range text default 'overall')
returns table(event_date date, question_id text, mastered_at timestamptz)
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with params as (
  select case lower(btrim(coalesce(p_range,'overall')))
    when 'today' then (now() at time zone 'Asia/Kolkata')::date
    when '7d' then (now() at time zone 'Asia/Kolkata')::date-6
    when 'overall' then null::date
    else null::date
  end start_date
), a as (
  select x.*,
    (x.attempted_at at time zone 'Asia/Kolkata')::date study_date,
    row_number() over(
      partition by x.question_id,(x.attempted_at at time zone 'Asia/Kolkata')::date
      order by x.attempted_at,x.source_row nulls last,x.created_at,x.attempt_id
    ) day_rn
  from english.attempts x
  where x.user_id=p_user_id
), cp0 as (
  select question_id,study_date,attempted_at,correct,source_row,created_at,attempt_id,
    row_number() over(
      partition by question_id
      order by study_date,attempted_at,source_row nulls last,created_at,attempt_id
    )::int seq
  from a
  where day_rn=1
), cp1 as (
  select c.*,
    lag(study_date) over(partition by question_id order by seq) prev_date,
    max(seq) filter(where not coalesce(correct,false)) over(
      partition by question_id order by seq rows between unbounded preceding and current row
    ) last_wrong_seq
  from cp0 c
), cp2 as (
  select c.*,
    case when coalesce(correct,false) then seq-coalesce(last_wrong_seq,0) else 0 end streak
  from cp1 c
), cp3 as (
  select c.*,
    (coalesce(correct,false) and streak>=4 and prev_date is not null and (study_date-prev_date)>=5) pm_flag
  from cp2 c
), cp4 as (
  select c.*,
    coalesce(lag(pm_flag) over(partition by question_id order by seq),false) prev_pm_flag
  from cp3 c
), transitions as (
  select study_date,question_id,attempted_at
  from cp4
  where pm_flag and not prev_pm_flag
)
select t.study_date,t.question_id,t.attempted_at
from transitions t cross join params p
where p.start_date is null or t.study_date>=p.start_date;
$function$;

create or replace function english.daily_analysis_attempt_universe(p_user_id uuid, p_range text default 'today')
returns table(
  question_id text,
  display_name text,
  topic text,
  current_state text,
  concept_state text,
  concept_id text,
  days_seen integer,
  period_attempts integer,
  period_wrong integer,
  period_correct integer,
  latest_selected text,
  latest_correct boolean,
  last_attempt timestamptz,
  total_attempts integer,
  total_wrong integer,
  accuracy numeric,
  mastered_on timestamptz,
  is_persistent_weak boolean,
  is_weak boolean,
  is_retention_risk boolean,
  is_fragile_learning boolean,
  is_due_revision boolean,
  is_proven_mastered boolean
)
language sql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with params as (
  select case lower(btrim(coalesce(p_range,'today')))
    when 'today' then (now() at time zone 'Asia/Kolkata')::date
    when '7d' then (now() at time zone 'Asia/Kolkata')::date-6
    when 'overall' then null::date
    else (now() at time zone 'Asia/Kolkata')::date
  end start_date
), period_a as (
  select a.*,(a.attempted_at at time zone 'Asia/Kolkata')::date study_date
  from english.attempts a cross join params p
  where a.user_id=p_user_id
    and (p.start_date is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=p.start_date)
), pa as (
  select question_id,
    count(*)::int period_attempts,
    count(*) filter(where not correct)::int period_wrong,
    count(*) filter(where correct)::int period_correct,
    count(distinct study_date)::int days_seen,
    max(attempted_at) last_attempt
  from period_a
  group by question_id
), la as (
  select distinct on (question_id)
    question_id,selected_answer latest_selected,correct latest_correct,concept_id attempt_concept_id
  from period_a
  order by question_id,attempted_at desc,attempt_id desc
), mastery as (
  select e.question_id,max(e.mastered_at) mastered_on
  from english.proven_mastery_events(p_user_id,p_range) e
  group by e.question_id
), mapped as (
  select pa.question_id,pa.period_attempts,pa.period_wrong,pa.period_correct,pa.days_seen,pa.last_attempt,
    la.latest_selected,la.latest_correct,
    q.word,q.question,q.topic,
    coalesce(nullif(q.concept_id,''),nullif(la.attempt_concept_id,''),qm.concept_id) resolved_concept_id,
    m.mastered_on
  from pa
  join la on la.question_id=pa.question_id
  join english.questions q on q.question_id=pa.question_id and q.active
  left join mastery m on m.question_id=pa.question_id
  left join lateral (
    select x.concept_id
    from english.question_concept_mappings x
    where x.question_id=pa.question_id
    order by coalesce(x.mapping_confidence,0) desc,x.updated_at desc nulls last
    limit 1
  ) qm on true
  where english.question_visible_to_user(p_user_id,pa.question_id)
)
select
  m.question_id,
  coalesce(nullif(btrim(m.word),''),nullif(btrim(c.name),''),nullif(left(btrim(m.question),92),''),'English question') display_name,
  coalesce(nullif(btrim(m.topic),''),'English') topic,
  coalesce(qs.status,'New') current_state,
  ce.coverage_state concept_state,
  m.resolved_concept_id concept_id,
  m.days_seen,
  m.period_attempts,
  m.period_wrong,
  m.period_correct,
  m.latest_selected,
  m.latest_correct,
  m.last_attempt,
  coalesce(qs.attempts,0) total_attempts,
  coalesce(qs.wrong,0) total_wrong,
  coalesce(qs.accuracy,0) accuracy,
  m.mastered_on,
  (coalesce(qs.status,'')='Persistent Weak') is_persistent_weak,
  (coalesce(qs.status,'')='Weak') is_weak,
  (coalesce(ce.coverage_state,'')='retention_risk') is_retention_risk,
  (coalesce(qs.status,'') in ('Fragile','Learning')) is_fragile_learning,
  (qs.next_review is not null and qs.next_review<=now()) is_due_revision,
  (m.mastered_on is not null) is_proven_mastered
from mapped m
left join english.question_state qs on qs.user_id=p_user_id and qs.question_id=m.question_id
left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.resolved_concept_id
left join english.concepts c on c.concept_id=m.resolved_concept_id;
$function$;

create or replace function public.english_get_daily_analysis_summary_filtered(p_range text default 'today')
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  range_key text:=lower(btrim(coalesce(p_range,'today')));
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  outv jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if range_key not in ('today','7d','overall') then raise exception 'unknown daily analysis range'; end if;

  with base as (
    select * from english.daily_analysis_attempt_universe(uid,range_key)
  ), counts as (
    select
      count(*)::int attempted_questions,
      coalesce(sum(period_attempts),0)::int attempt_count,
      coalesce(sum(period_wrong),0)::int wrong_attempts,
      count(*) filter(where period_wrong>0)::int wrong_questions,
      count(*) filter(where is_persistent_weak)::int persistent_weak,
      count(*) filter(where is_weak)::int weak,
      count(*) filter(where is_retention_risk)::int retention_risk,
      count(*) filter(where is_fragile_learning)::int fragile_learning,
      count(*) filter(where is_due_revision)::int due_revision,
      count(*) filter(where is_proven_mastered)::int proven_mastered,
      count(*) filter(where is_persistent_weak or is_weak or is_retention_risk or is_fragile_learning or is_due_revision or is_proven_mastered)::int relevant
    from base
  )
  select jsonb_build_object(
    'ok',true,
    'date',v_today,
    'range',range_key,
    'relevantCount',relevant,
    'attemptedQuestions',attempted_questions,
    'attemptCount',attempt_count,
    'wrongAttempts',wrong_attempts,
    'wrongQuestions',wrong_questions,
    'attemptedToday',attempted_questions,
    'wrongToday',wrong_attempts,
    'categories',jsonb_build_object(
      'persistent_weak',persistent_weak,
      'weak',weak,
      'retention_risk',retention_risk,
      'fragile_learning',fragile_learning,
      'due_revision',due_revision,
      'proven_mastered',proven_mastered
    )
  ) into outv from counts;
  return outv;
end
$function$;

create or replace function public.english_get_daily_analysis_summary()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
  select public.english_get_daily_analysis_summary_filtered('today');
$function$;

create or replace function public.english_get_daily_analysis_questions_filtered(p_category text, p_range text default 'today', p_limit integer default 200)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  cat text:=lower(btrim(coalesce(p_category,'')));
  range_key text:=lower(btrim(coalesce(p_range,'today')));
  lim integer:=greatest(1,least(300,coalesce(p_limit,200)));
  rowsv jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if cat not in ('persistent_weak','weak','retention_risk','fragile_learning','due_revision','proven_mastered') then raise exception 'unknown daily analysis category'; end if;
  if range_key not in ('today','7d','overall') then raise exception 'unknown daily analysis range'; end if;

  with qualified as (
    select b.*,
      case cat
        when 'persistent_weak' then b.is_persistent_weak
        when 'weak' then b.is_weak
        when 'retention_risk' then b.is_retention_risk
        when 'fragile_learning' then b.is_fragile_learning
        when 'due_revision' then b.is_due_revision
        when 'proven_mastered' then b.is_proven_mastered
        else false end qualifies
    from english.daily_analysis_attempt_universe(uid,range_key) b
  ), picked as (
    select * from qualified
    where qualifies
    order by
      case when cat='proven_mastered' then mastered_on end desc nulls last,
      period_wrong desc,period_attempts desc,last_attempt desc,total_wrong desc,display_name
    limit lim
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'questionId',question_id,
    'displayName',display_name,
    'topic',topic,
    'currentState',current_state,
    'dailyReason',case cat
      when 'persistent_weak' then 'Persistent Weak'
      when 'weak' then 'Weak'
      when 'retention_risk' then 'Retention Risk'
      when 'fragile_learning' then current_state
      when 'due_revision' then 'Due Revision'
      when 'proven_mastered' then 'Proven Mastered'
    end,
    'conceptState',concept_state,
    'dailyDate',case when cat='proven_mastered' then (mastered_on at time zone 'Asia/Kolkata')::date else (last_attempt at time zone 'Asia/Kolkata')::date end,
    'daysSeen',days_seen,
    'periodAttempts',period_attempts,
    'periodWrong',period_wrong,
    'periodCorrect',period_correct,
    'latestSelected',latest_selected,
    'latestCorrect',latest_correct,
    'lastAttempt',last_attempt,
    'masteredOn',mastered_on,
    'totalAttempts',total_attempts,
    'totalWrong',total_wrong,
    'accuracy',accuracy
  )) order by
    case when cat='proven_mastered' then mastered_on end desc nulls last,
    period_wrong desc,period_attempts desc,last_attempt desc,total_wrong desc,display_name),'[]'::jsonb)
  into rowsv from picked;

  return jsonb_build_object('ok',true,'date',(now() at time zone 'Asia/Kolkata')::date,'category',cat,'range',range_key,'questions',rowsv);
end
$function$;

create or replace function public.english_get_daily_analysis_question_filtered(p_category text, p_question_id text, p_category_range text default 'today', p_attempt_range text default 'today')
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  cat text:=lower(btrim(coalesce(p_category,'')));
  qid text:=btrim(coalesce(p_question_id,''));
  category_range text:=lower(btrim(coalesce(p_category_range,'today')));
  attempt_range text:=lower(btrim(coalesce(p_attempt_range,'today')));
  attempt_start date;
  b record;
  payload jsonb;
  revision_payload jsonb;
  attempts_json jsonb:='[]'::jsonb;
  attempt_summary jsonb:='{}'::jsonb;
  latest_selected text;
  latest_correct boolean;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if qid='' then raise exception 'question id required'; end if;
  if cat not in ('persistent_weak','weak','retention_risk','fragile_learning','due_revision','proven_mastered') then raise exception 'unknown daily analysis category'; end if;
  if category_range not in ('today','7d','overall') then raise exception 'unknown daily analysis range'; end if;
  if attempt_range not in ('today','7d','overall') then raise exception 'unknown attempt range'; end if;

  select * into b
  from english.daily_analysis_attempt_universe(uid,category_range) x
  where x.question_id=qid and case cat
    when 'persistent_weak' then x.is_persistent_weak
    when 'weak' then x.is_weak
    when 'retention_risk' then x.is_retention_risk
    when 'fragile_learning' then x.is_fragile_learning
    when 'due_revision' then x.is_due_revision
    when 'proven_mastered' then x.is_proven_mastered
    else false end
  limit 1;
  if not found then raise exception 'question is not in this Daily Analysis category for the selected range'; end if;

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

  attempt_start:=case attempt_range when 'today' then (now() at time zone 'Asia/Kolkata')::date when '7d' then (now() at time zone 'Asia/Kolkata')::date-6 else null end;

  select a.selected_answer,a.correct into latest_selected,latest_correct
  from english.attempts a
  where a.user_id=uid and a.question_id=qid and (attempt_start is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=attempt_start)
  order by a.attempted_at desc,a.attempt_id desc limit 1;

  with windowed as (
    select a.* from english.attempts a
    where a.user_id=uid and a.question_id=qid and (attempt_start is null or (a.attempted_at at time zone 'Asia/Kolkata')::date>=attempt_start)
  ), shown as (
    select * from windowed order by attempted_at desc,attempt_id desc limit case when attempt_range='overall' then 10 else 50 end
  ), summary as (
    select count(*)::int total,count(*) filter(where correct)::int correct,count(*) filter(where not correct)::int wrong from windowed
  ), shown_summary as (
    select count(*)::int shown,count(*) filter(where correct)::int shown_correct,count(*) filter(where not correct)::int shown_wrong from shown
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object('attemptedAt',s.attempted_at,'selected',s.selected_answer,'correct',s.correct,'module',s.module,'timeSeconds',s.time_seconds) order by s.attempted_at desc,s.attempt_id desc),'[]'::jsonb) from shown s),
    jsonb_build_object('range',attempt_range,'total',summary.total,'correct',summary.correct,'wrong',summary.wrong,'shown',shown_summary.shown,'shownCorrect',shown_summary.shown_correct,'shownWrong',shown_summary.shown_wrong,'truncated',(summary.total>shown_summary.shown))
  into attempts_json,attempt_summary
  from summary cross join shown_summary;

  return jsonb_build_object(
    'ok',true,'date',(now() at time zone 'Asia/Kolkata')::date,'category',cat,'range',category_range,
    'analysis',jsonb_strip_nulls(jsonb_build_object(
      'questionId',b.question_id,'displayName',b.display_name,'topic',b.topic,'currentState',b.current_state,
      'dailyReason',case cat when 'persistent_weak' then 'Persistent Weak' when 'weak' then 'Weak' when 'retention_risk' then 'Retention Risk' when 'fragile_learning' then b.current_state when 'due_revision' then 'Due Revision' when 'proven_mastered' then 'Proven Mastered' end,
      'conceptState',b.concept_state,
      'dailyDate',case when cat='proven_mastered' then (b.mastered_on at time zone 'Asia/Kolkata')::date else (b.last_attempt at time zone 'Asia/Kolkata')::date end,
      'daysSeen',b.days_seen,'periodAttempts',b.period_attempts,'periodWrong',b.period_wrong,'periodCorrect',b.period_correct,
      'latestSelected',coalesce(latest_selected,b.latest_selected),'latestCorrect',coalesce(latest_correct,b.latest_correct),'lastAttempt',b.last_attempt,'masteredOn',b.mastered_on,
      'totalAttempts',b.total_attempts,'totalWrong',b.total_wrong,'accuracy',b.accuracy
    )),
    'question',payload,'recentAttempts',attempts_json,'attemptSummary',attempt_summary
  );
end
$function$;

grant execute on function public.english_get_daily_analysis_summary_filtered(text) to authenticated;
grant execute on function public.english_get_daily_analysis_summary() to authenticated;
grant execute on function public.english_get_daily_analysis_questions_filtered(text,text,integer) to authenticated;
grant execute on function public.english_get_daily_analysis_question_filtered(text,text,text,text) to authenticated;

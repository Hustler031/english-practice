-- Read-only learner Daily Analysis for Learning Insights.
-- Scope: questions planned or attempted on the current Asia/Kolkata date.
-- This surface never records attempts, changes mastery, changes cooldowns, or mutates canonical questions.

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
), attempt_today as (
  select a.question_id,
         count(*)::int attempts_today,
         count(*) filter(where not a.correct)::int wrong_today,
         max(a.attempted_at) last_attempt
  from english.attempts a cross join params p
  where a.user_id=p_user_id
    and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
  group by a.question_id
), latest_today as (
  select distinct on (a.question_id)
         a.question_id,a.selected_answer latest_selected,a.correct latest_correct,a.attempted_at
  from english.attempts a cross join params p
  where a.user_id=p_user_id
    and (a.attempted_at at time zone 'Asia/Kolkata')::date=p.today
  order by a.question_id,a.attempted_at desc,a.attempt_id desc
), daily_today as (
  select d.question_id,d.reason,d.concept_id
  from english.daily_current d cross join params p
  where d.user_id=p_user_id and d.quiz_date=p.today
), scope_ids as (
  select question_id from attempt_today
  union
  select question_id from daily_today
), mapped as (
  select s.question_id,
         coalesce(nullif(q.concept_id,''),nullif(d.concept_id,''),m.concept_id) concept_id,
         q.word,q.question,q.topic
  from scope_ids s
  join english.questions q on q.question_id=s.question_id and q.active
  left join daily_today d on d.question_id=s.question_id
  left join lateral (
    select qm.concept_id
    from english.question_concept_mappings qm
    where qm.question_id=s.question_id
    order by coalesce(qm.mapping_confidence,0) desc,qm.updated_at desc nulls last
    limit 1
  ) m on true
  where english.question_visible_to_user(p_user_id,s.question_id)
)
select
  m.question_id,
  coalesce(nullif(btrim(m.word),''),nullif(btrim(c.name),''),nullif(left(btrim(m.question),92),''),'English question') display_name,
  coalesce(nullif(btrim(m.topic),''),'English') topic,
  coalesce(qs.status,'New') current_state,
  d.reason daily_reason,
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
  (coalesce(qs.status,'')='Persistent Weak' or coalesce(d.reason,'')='Persistent Weak') is_persistent_weak,
  (coalesce(qs.status,'')='Weak' or coalesce(d.reason,'')='Weak') is_weak,
  (coalesce(ce.coverage_state,'')='retention_risk') is_retention_risk,
  (coalesce(qs.status,'') in ('Fragile','Learning') or coalesce(d.reason,'') in ('Fragile','Learning')) is_fragile_learning,
  (coalesce(d.reason,'')='Due Spaced Revision') is_due_revision
from mapped m
left join english.question_state qs on qs.user_id=p_user_id and qs.question_id=m.question_id
left join daily_today d on d.question_id=m.question_id
left join attempt_today at on at.question_id=m.question_id
left join latest_today lt on lt.question_id=m.question_id
left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=m.concept_id
left join english.concepts c on c.concept_id=m.concept_id;
$function$;

revoke all on function english.daily_analysis_base(uuid) from public,anon,authenticated;
grant execute on function english.daily_analysis_base(uuid) to service_role;

create or replace function public.english_get_daily_analysis_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  outv jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  with base as (select * from english.daily_analysis_base(uid)), counts as (
    select
      count(*) filter(where is_persistent_weak)::int persistent_weak,
      count(*) filter(where is_weak)::int weak,
      count(*) filter(where is_retention_risk)::int retention_risk,
      count(*) filter(where is_fragile_learning)::int fragile_learning,
      count(*) filter(where is_due_revision)::int due_revision,
      count(*) filter(where is_persistent_weak or is_weak or is_retention_risk or is_fragile_learning or is_due_revision)::int relevant,
      count(*) filter(where attempts_today>0)::int attempted_today,
      count(*) filter(where wrong_today>0)::int wrong_today
    from base
  )
  select jsonb_build_object(
    'ok',true,'date',v_today,'relevantCount',relevant,'attemptedToday',attempted_today,'wrongToday',wrong_today,
    'categories',jsonb_build_object(
      'persistent_weak',persistent_weak,
      'weak',weak,
      'retention_risk',retention_risk,
      'fragile_learning',fragile_learning,
      'due_revision',due_revision
    )
  ) into outv from counts;
  return outv;
end
$function$;

revoke execute on function public.english_get_daily_analysis_summary() from public,anon;
grant execute on function public.english_get_daily_analysis_summary() to authenticated,service_role;

create or replace function public.english_get_daily_analysis_questions(p_category text,p_limit integer default 120)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  cat text:=lower(btrim(coalesce(p_category,'')));
  lim integer:=greatest(1,least(200,coalesce(p_limit,120)));
  rowsv jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if cat not in ('persistent_weak','weak','retention_risk','fragile_learning','due_revision') then
    raise exception 'unknown daily analysis category';
  end if;

  with picked as (
    select *
    from english.daily_analysis_base(uid) b
    where case cat
      when 'persistent_weak' then b.is_persistent_weak
      when 'weak' then b.is_weak
      when 'retention_risk' then b.is_retention_risk
      when 'fragile_learning' then b.is_fragile_learning
      when 'due_revision' then b.is_due_revision
      else false end
    order by b.wrong_today desc,b.attempts_today desc,b.last_attempt desc nulls last,b.total_wrong desc,b.display_name
    limit lim
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'questionId',question_id,
    'displayName',display_name,
    'topic',topic,
    'currentState',current_state,
    'dailyReason',daily_reason,
    'conceptState',concept_state,
    'attemptsToday',attempts_today,
    'wrongToday',wrong_today,
    'latestSelected',latest_selected,
    'latestCorrect',latest_correct,
    'lastAttempt',last_attempt,
    'totalAttempts',total_attempts,
    'totalWrong',total_wrong,
    'accuracy',accuracy
  )) order by wrong_today desc,attempts_today desc,last_attempt desc nulls last,total_wrong desc,display_name),'[]'::jsonb)
  into rowsv from picked;

  return jsonb_build_object('ok',true,'date',(now() at time zone 'Asia/Kolkata')::date,'category',cat,'questions',rowsv);
end
$function$;

revoke execute on function public.english_get_daily_analysis_questions(text,integer) from public,anon;
grant execute on function public.english_get_daily_analysis_questions(text,integer) to authenticated,service_role;

create or replace function public.english_get_daily_analysis_question(p_category text,p_question_id text)
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
  b record;
  payload jsonb;
  revision_payload jsonb;
  attempts_json jsonb:='[]'::jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if qid='' then raise exception 'question id required'; end if;
  if cat not in ('persistent_weak','weak','retention_risk','fragile_learning','due_revision') then
    raise exception 'unknown daily analysis category';
  end if;

  select * into b
  from english.daily_analysis_base(uid) x
  where x.question_id=qid and case cat
    when 'persistent_weak' then x.is_persistent_weak
    when 'weak' then x.is_weak
    when 'retention_risk' then x.is_retention_risk
    when 'fragile_learning' then x.is_fragile_learning
    when 'due_revision' then x.is_due_revision
    else false end
  limit 1;
  if not found then raise exception 'question is not in this Daily Analysis category'; end if;

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

  select coalesce(jsonb_agg(jsonb_build_object(
    'attemptedAt',a.attempted_at,
    'selected',a.selected_answer,
    'correct',a.correct,
    'module',a.module,
    'timeSeconds',a.time_seconds
  ) order by a.attempted_at desc),'[]'::jsonb)
  into attempts_json
  from (
    select * from english.attempts
    where user_id=uid and question_id=qid
    order by attempted_at desc,attempt_id desc
    limit 6
  ) a;

  return jsonb_build_object(
    'ok',true,
    'date',(now() at time zone 'Asia/Kolkata')::date,
    'category',cat,
    'analysis',jsonb_strip_nulls(jsonb_build_object(
      'questionId',b.question_id,'displayName',b.display_name,'topic',b.topic,
      'currentState',b.current_state,'dailyReason',b.daily_reason,'conceptState',b.concept_state,
      'attemptsToday',b.attempts_today,'wrongToday',b.wrong_today,'latestSelected',b.latest_selected,
      'latestCorrect',b.latest_correct,'lastAttempt',b.last_attempt,'totalAttempts',b.total_attempts,
      'totalWrong',b.total_wrong,'accuracy',b.accuracy
    )),
    'question',payload,
    'recentAttempts',attempts_json
  );
end
$function$;

revoke execute on function public.english_get_daily_analysis_question(text,text) from public,anon;
grant execute on function public.english_get_daily_analysis_question(text,text) to authenticated,service_role;

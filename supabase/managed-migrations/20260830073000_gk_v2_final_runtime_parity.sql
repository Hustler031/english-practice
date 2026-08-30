-- GK V2 final pre-deployment runtime parity and safe recovery.
-- Forward-only schema/function correction. It does not rebuild or rewrite historical
-- attempts, exposures, sessions, notes, flags, or question_state evidence.
-- QuestionState remains a cache; all selectors below derive learning intelligence
-- from raw Attempts + Exposures, matching the old GK application's authority.

alter table gk.demand_sets
  add column if not exists user_id uuid null references auth.users(id) on delete cascade;
create index if not exists gk_demand_sets_user_active_idx
  on gk.demand_sets(user_id,active,created_at desc);

-- Exact old-GK evidence model. The 18-hour retention gap compares each real answer
-- with the immediately previous real answer for that question.
create or replace function gk.learning_profiles_v2(p_user_id uuid)
returns table(
  question_id text,
  attempts integer,
  correct integer,
  wrong integer,
  accuracy numeric,
  first_attempt_correct boolean,
  retention_attempts integer,
  retention_correct integer,
  retention_wrong integer,
  retention_accuracy numeric,
  recent_spaced_failures integer,
  last_attempt timestamptz,
  last_spaced_attempt timestamptz,
  last_meaningful_result text,
  latest_result text,
  learning_state text,
  next_review timestamptz,
  due boolean,
  guessed_attempts integer,
  repeatedly_guessed boolean,
  unconfirmed_guess boolean,
  last_guess_at timestamptz,
  confirmed_unguessed_spaced_recalls integer,
  exposure_count integer,
  first_seen timestamptz,
  last_seen timestamptz
)
language sql
stable security definer
set search_path=pg_catalog,gk,auth
as $$
with ordered as (
  select a.*,
    lag(a.attempted_at) over(
      partition by a.question_id order by a.attempted_at,a.attempt_id
    ) prev_attempted_at,
    row_number() over(
      partition by a.question_id order by a.attempted_at,a.attempt_id
    ) attempt_no
  from gk.attempts a
  where a.user_id=p_user_id and a.is_correct is not null
), marked as (
  select o.*,
    (o.prev_attempted_at is not null
      and extract(epoch from(o.attempted_at-o.prev_attempted_at))/3600.0 >= 18) spaced,
    case when o.prev_attempted_at is null then null
      else extract(epoch from(o.attempted_at-o.prev_attempted_at))/3600.0 end gap_hours_derived
  from ordered o
), spaced_ranked as (
  select m.*,
    row_number() over(
      partition by m.question_id order by m.attempted_at desc,m.attempt_id desc
    ) spaced_desc
  from marked m
  where m.spaced
), agg as (
  select m.question_id,
    count(*)::int attempts,
    count(*) filter(where m.is_correct)::int correct,
    count(*) filter(where not m.is_correct)::int wrong,
    round(count(*) filter(where m.is_correct)*100.0/nullif(count(*),0),1) accuracy,
    (array_agg(m.is_correct order by m.attempted_at,m.attempt_id))[1] first_attempt_correct,
    count(*) filter(where m.spaced)::int retention_attempts,
    count(*) filter(where m.spaced and m.is_correct)::int retention_correct,
    count(*) filter(where m.spaced and not m.is_correct)::int retention_wrong,
    round(count(*) filter(where m.spaced and m.is_correct)*100.0/
      nullif(count(*) filter(where m.spaced),0),1) retention_accuracy,
    max(m.attempted_at) last_attempt,
    max(m.attempted_at) filter(where m.spaced) last_spaced_attempt,
    (array_agg(m.is_correct order by m.attempted_at desc,m.attempt_id desc))[1] latest_correct,
    (array_agg(m.is_correct order by m.attempted_at desc,m.attempt_id desc)
      filter(where m.spaced))[1] last_spaced_correct,
    (array_agg(coalesce(m.guessed,false) order by m.attempted_at desc,m.attempt_id desc)
      filter(where m.spaced))[1] last_spaced_guessed,
    count(*) filter(where coalesce(m.guessed,false))::int guessed_attempts,
    max(m.attempted_at) filter(where coalesce(m.guessed,false)) last_guess_at,
    count(*) filter(where m.spaced and m.is_correct and not coalesce(m.guessed,false))::int
      confirmed_unguessed_spaced_recalls,
    max(m.attempted_at) filter(where m.spaced and m.is_correct and not coalesce(m.guessed,false))
      last_confirming_at
  from marked m
  group by m.question_id
), recent as (
  select sr.question_id,
    count(*) filter(where not sr.is_correct)::int recent_spaced_failures
  from spaced_ranked sr
  where sr.spaced_desc<=3
  group by sr.question_id
), exposure as (
  select e.question_id,count(*)::int exposure_count,min(e.exposed_at) first_seen,max(e.exposed_at) last_seen
  from gk.exposures e where e.user_id=p_user_id group by e.question_id
), raw as (
  select q.question_id,
    coalesce(a.attempts,0)::int attempts,
    coalesce(a.correct,0)::int correct,
    coalesce(a.wrong,0)::int wrong,
    coalesce(a.accuracy,0)::numeric accuracy,
    a.first_attempt_correct,
    coalesce(a.retention_attempts,0)::int retention_attempts,
    coalesce(a.retention_correct,0)::int retention_correct,
    coalesce(a.retention_wrong,0)::int retention_wrong,
    coalesce(a.retention_accuracy,0)::numeric retention_accuracy,
    coalesce(r.recent_spaced_failures,0)::int recent_spaced_failures,
    a.last_attempt,a.last_spaced_attempt,
    case when coalesce(a.retention_attempts,0)>0
      then case when a.last_spaced_correct then 'Correct' else 'Wrong' end
      when a.attempts is not null
      then case when a.latest_correct then 'Correct' else 'Wrong' end
      else '' end last_meaningful_result,
    case when a.attempts is not null
      then case when a.latest_correct then 'Correct' else 'Wrong' end else '' end latest_result,
    coalesce(a.guessed_attempts,0)::int guessed_attempts,
    coalesce(a.guessed_attempts,0)>=2 repeatedly_guessed,
    (a.last_guess_at is not null and
      (a.last_confirming_at is null or a.last_confirming_at<=a.last_guess_at)) unconfirmed_guess,
    a.last_guess_at,
    coalesce(a.confirmed_unguessed_spaced_recalls,0)::int confirmed_unguessed_spaced_recalls,
    a.last_spaced_correct,a.last_spaced_guessed,
    coalesce(e.exposure_count,0)::int exposure_count,e.first_seen,e.last_seen
  from gk.questions q
  left join agg a on a.question_id=q.question_id
  left join recent r on r.question_id=q.question_id
  left join exposure e on e.question_id=q.question_id
  where q.active
), stated as (
  select r.*,
    case
      when r.attempts=0 then 'New'
      when r.recent_spaced_failures>=2
        or (r.retention_wrong>=2 and r.retention_accuracy<60) then 'Persistent Weak'
      when (r.retention_wrong>=1 and coalesce(r.last_spaced_correct,false)=false)
        or (r.wrong>=2 and r.retention_correct=0) then 'Weak'
      when r.unconfirmed_guess or r.retention_attempts<2 then 'Fragile'
      when r.retention_correct>=3 and r.retention_accuracy>=85
        and r.last_spaced_correct is true and not coalesce(r.last_spaced_guessed,false)
        and r.recent_spaced_failures=0 and not r.unconfirmed_guess
        and r.confirmed_unguessed_spaced_recalls>=2 then 'Proven Mastered'
      when r.retention_correct>=2 and r.retention_accuracy>=75
        and r.last_spaced_correct is true and not r.unconfirmed_guess then 'Strong'
      when r.wrong>0 or r.retention_accuracy<70 then 'Weak'
      else 'Learning'
    end learning_state
  from raw r
), scheduled as (
  select s.*,
    case when s.last_attempt is null then null::timestamptz else
      (
        (
          (coalesce(s.last_spaced_attempt,s.last_attempt) at time zone 'Asia/Kolkata')::date
          + case s.learning_state
              when 'Persistent Weak' then 1
              when 'Weak' then 1
              when 'Fragile' then 2
              when 'Learning' then 3
              when 'Strong' then 7
              when 'Proven Mastered' then 21
              else 2
            end
        )::timestamp at time zone 'Asia/Kolkata'
      )
    end next_review
  from stated s
)
select s.question_id,s.attempts,s.correct,s.wrong,s.accuracy,s.first_attempt_correct,
  s.retention_attempts,s.retention_correct,s.retention_wrong,s.retention_accuracy,
  s.recent_spaced_failures,s.last_attempt,s.last_spaced_attempt,s.last_meaningful_result,
  s.latest_result,s.learning_state,s.next_review,
  coalesce(s.next_review<=now(),false) due,s.guessed_attempts,s.repeatedly_guessed,
  s.unconfirmed_guess,s.last_guess_at,s.confirmed_unguessed_spaced_recalls,
  s.exposure_count,s.first_seen,s.last_seen
from scheduled s
$$;

revoke execute on function gk.learning_profiles_v2(uuid) from public,anon,authenticated,service_role;

create or replace function gk.refresh_question_state_v2(p_user_id uuid,p_question_id text)
returns void
language plpgsql
security definer
set search_path=pg_catalog,gk,auth
as $$
declare p record;
begin
  select * into p from gk.learning_profiles_v2(p_user_id) where question_id=p_question_id;
  if not found then return; end if;

  insert into gk.question_state(user_id,question_id,learning_status)
  values(p_user_id,p_question_id,p.learning_state)
  on conflict(user_id,question_id) do nothing;

  update gk.question_state s set
    attempts=p.attempts,
    correct=p.correct,
    wrong=p.wrong,
    accuracy=p.accuracy,
    learning_status=p.learning_state,
    last_attempt=p.last_attempt,
    next_review=p.next_review,
    first_attempt_correct=p.first_attempt_correct,
    retention_attempts=p.retention_attempts,
    retention_correct=p.retention_correct,
    retention_wrong=p.retention_wrong,
    last_spaced_attempt=p.last_spaced_attempt,
    exposure_count=p.exposure_count,
    first_seen=p.first_seen,
    last_seen=p.last_seen,
    guessed_attempts=p.guessed_attempts,
    unconfirmed_guess=p.unconfirmed_guess,
    last_guess_at=p.last_guess_at,
    confirmed_unguessed_spaced_recalls=p.confirmed_unguessed_spaced_recalls,
    last_meaningful_result=p.last_meaningful_result,
    latest_result=p.latest_result,
    learning_updated_at=now()
  where s.user_id=p_user_id and s.question_id=p_question_id;
end
$$;
revoke execute on function gk.refresh_question_state_v2(uuid,text) from public,anon,authenticated,service_role;

create or replace function gk.question_payload_v2_read(p_user_id uuid,p_question_id text)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,gk,auth
as $$
with qrow as (
  select q.* from gk.questions q where q.question_id=p_question_id and q.active
), p as (
  select * from gk.learning_profiles_v2(p_user_id) where question_id=p_question_id
)
select to_jsonb(q)-'source_payload'
 || jsonb_build_object(
   'id',q.question_id,
   'question_id',q.question_id,
   'library_key',gk.derive_library_key(q.question_id,q.source_label,q.subject),
   'correctKey',upper(coalesce(q.correct_option,'')),
   'options',jsonb_build_array(
     jsonb_build_object('key','A','text',coalesce(q.option_a,'')),
     jsonb_build_object('key','B','text',coalesce(q.option_b,'')),
     jsonb_build_object('key','C','text',coalesce(q.option_c,'')),
     jsonb_build_object('key','D','text',coalesce(q.option_d,''))
   ),
   'state',jsonb_build_object(
     'attempts',coalesce(p.attempts,0),
     'correct',coalesce(p.correct,0),
     'wrong',coalesce(p.wrong,0),
     'accuracy',coalesce(p.accuracy,0),
     'status',coalesce(p.learning_state,'New'),
     'learningState',coalesce(p.learning_state,'New'),
     'firstAttemptCorrect',p.first_attempt_correct,
     'retentionAttempts',coalesce(p.retention_attempts,0),
     'retentionCorrect',coalesce(p.retention_correct,0),
     'retentionWrong',coalesce(p.retention_wrong,0),
     'retentionAccuracy',coalesce(p.retention_accuracy,0),
     'recentSpacedFailures',coalesce(p.recent_spaced_failures,0),
     'lastAttempt',p.last_attempt,
     'lastSpacedAttempt',p.last_spaced_attempt,
     'lastMeaningfulResult',coalesce(p.last_meaningful_result,''),
     'latestResult',coalesce(p.latest_result,''),
     'nextReview',p.next_review,
     'due',coalesce(p.due,false),
     'starred',coalesce(s.marked_review,false),
     'starredAt',s.starred_at,
     'difficult',coalesce(s.difficult,false),
     'guessedAttempts',coalesce(p.guessed_attempts,0),
     'unconfirmedGuess',coalesce(p.unconfirmed_guess,false),
     'lastGuessAt',p.last_guess_at,
     'confirmedUnguessedSpacedRecalls',coalesce(p.confirmed_unguessed_spaced_recalls,0),
     'exposureCount',coalesce(p.exposure_count,0),
     'firstSeen',p.first_seen,
     'lastSeen',p.last_seen,
     'flagged',coalesce(s.flag_active,false),
     'flagReason',coalesce(s.flag_reason,''),
     'note',coalesce(n.note,'')
   )
 )
from qrow q
left join p on p.question_id=q.question_id
left join gk.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
left join gk.user_notes n on n.user_id=p_user_id and n.question_id=q.question_id
$$;
revoke execute on function gk.question_payload_v2_read(uuid,text) from public,anon,authenticated,service_role;

-- Canonical answer write. Raw attempt is authoritative and idempotent by attempt_id.
create or replace function public.gk_submit_answer(
  p_question_id text,
  p_selected_option text,
  p_marked_review boolean default false,
  p_attempt_id text default null,
  p_mode text default null,
  p_session_id text default null
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  q gk.questions%rowtype;
  aid text:=coalesce(nullif(btrim(p_attempt_id),''),'gk-'||gen_random_uuid()::text);
  chosen text:=upper(btrim(coalesce(p_selected_option,'')));
  correct_key text;
  is_ok boolean;
  previous_at timestamptz;
  gap numeric;
  spaced boolean:=false;
  inserted boolean:=false;
  affected integer:=0;
  subkey text;
  profile record;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into q from gk.questions where question_id=btrim(p_question_id) and active;
  if not found then raise exception 'Question not found'; end if;
  correct_key:=upper(btrim(coalesce(q.correct_option,'')));
  if correct_key not in ('A','B','C','D') then raise exception 'Question has invalid canonical correct option'; end if;
  if chosen not in ('A','B','C','D') then raise exception 'Invalid option selected'; end if;

  select attempted_at into previous_at
  from gk.attempts
  where user_id=uid and question_id=q.question_id and is_correct is not null
  order by attempted_at desc,attempt_id desc limit 1;

  if previous_at is not null then
    gap:=extract(epoch from(now()-previous_at))/3600.0;
    spaced:=gap>=18;
  end if;
  is_ok:=chosen=correct_key;
  subkey:=case when nullif(btrim(coalesce(p_session_id,'')),'') is not null
    then uid::text||'|'||btrim(p_session_id)||'|'||q.question_id else aid end;

  insert into gk.attempts(
    attempt_id,user_id,attempted_at,question_id,selected_option,is_correct,marked_review,
    mode,session_id,submission_key,learning_state,guessed,attempt_kind,
    canonical_selected_option,display_selected_option,is_spaced,gap_hours,
    confidence_confirmed,study_date
  ) values(
    aid,uid,now(),q.question_id,chosen,is_ok,coalesce(p_marked_review,false),
    p_mode,p_session_id,subkey,'',false,'answer',chosen,chosen,spaced,gap,true,
    (now() at time zone 'Asia/Kolkata')::date
  )
  on conflict do nothing;
  get diagnostics affected=row_count;
  inserted:=affected>0;

  if not inserted then
    select a.is_correct,upper(coalesce(a.selected_option,'')),a.attempt_id into is_ok,chosen,aid
    from gk.attempts a
    where a.user_id=uid and a.question_id=q.question_id
      and (a.attempt_id=aid or a.submission_key=subkey)
    order by case when a.attempt_id=aid then 0 else 1 end
    limit 1;
    if not found then raise exception 'Attempt id belongs to a different answer'; end if;
  else
    insert into gk.question_state(user_id,question_id,learning_status,last_selected,last_correct)
    values(uid,q.question_id,'New',chosen,is_ok)
    on conflict(user_id,question_id) do update
      set last_selected=excluded.last_selected,last_correct=excluded.last_correct;
    perform gk.refresh_question_state_v2(uid,q.question_id);
  end if;

  select * into profile from gk.learning_profiles_v2(uid) where question_id=q.question_id;
  return jsonb_build_object(
    'ok',true,'attemptId',aid,'deduped',not inserted,'isCorrect',is_ok,
    'correctOption',correct_key,'learningState',coalesce(profile.learning_state,'New'),
    'retentionAttempt',coalesce(spaced,false),'unconfirmedGuess',coalesce(profile.unconfirmed_guess,false)
  );
end
$$;

create or replace function public.gk_record_exposure(
  p_question_id text,
  p_session_id text default null,
  p_mode text default null,
  p_exposure_id text default null
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  qid text:=btrim(coalesce(p_question_id,''));
  eid text:=coalesce(nullif(btrim(p_exposure_id),''),'gk-exp-'||gen_random_uuid()::text);
  skey text;
  inserted boolean:=false;
  affected integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from gk.questions where question_id=qid and active) then raise exception 'Question not found'; end if;
  skey:=case when nullif(btrim(coalesce(p_session_id,'')),'') is not null
    then uid::text||'|'||btrim(p_session_id)||'|'||qid else uid::text||'|'||eid end;

  insert into gk.exposures(
    exposure_id,user_id,exposed_at,question_id,session_id,mode,exposure_key,study_date
  ) values(
    eid,uid,now(),qid,nullif(btrim(coalesce(p_session_id,'')),''),p_mode,skey,
    (now() at time zone 'Asia/Kolkata')::date
  )
  on conflict(exposure_key) do nothing;
  get diagnostics affected=row_count;
  inserted:=affected>0;
  if inserted then perform gk.refresh_question_state_v2(uid,qid); end if;
  return jsonb_build_object('ok',true,'created',inserted,'exposureId',
    coalesce((select exposure_id from gk.exposures where exposure_key=skey),eid));
end
$$;

create or replace function public.gk_mark_guessed(
  p_question_id text,
  p_attempt_id text,
  p_guessed boolean default true,
  p_mutation_id text default null
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  qid text:=btrim(coalesce(p_question_id,''));
  aid text:=btrim(coalesce(p_attempt_id,''));
  profile record;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from gk.attempts a
    where a.user_id=uid and a.question_id=qid and a.attempt_id=aid and a.is_correct is not null)
  then raise exception 'Save the answer before marking it as guessed'; end if;

  update gk.attempts set
    guessed=coalesce(p_guessed,false),
    guessed_at=case when coalesce(p_guessed,false) then coalesce(guessed_at,now()) else null end,
    confidence_confirmed=not coalesce(p_guessed,false)
  where user_id=uid and question_id=qid and attempt_id=aid
    and coalesce(guessed,false) is distinct from coalesce(p_guessed,false);

  perform gk.refresh_question_state_v2(uid,qid);
  select * into profile from gk.learning_profiles_v2(uid) where question_id=qid;
  return jsonb_build_object('ok',true,'guessed',coalesce(p_guessed,false),
    'learningState',coalesce(profile.learning_state,'New'),
    'unconfirmedGuess',coalesce(profile.unconfirmed_guess,false));
end
$$;

create or replace function public.gk_save_session(
  p_session_id text,
  p_title text,
  p_mode text,
  p_position integer,
  p_answers jsonb,
  p_option_orders jsonb,
  p_question_ids text[],
  p_completed boolean default false,
  p_params jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  sid text:=btrim(coalesce(p_session_id,''));
  i integer;
  existing_owner uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if sid='' then raise exception 'Session id required'; end if;
  select user_id into existing_owner from gk.sessions where session_id=sid;
  if existing_owner is not null and existing_owner<>uid then raise exception 'Session belongs to another user'; end if;

  insert into gk.sessions(
    session_id,user_id,mode,params,current_index,updated_at,completed,title,study_day,
    composition,option_orders,answers,position_index,paused_at,session_version,created_at,study_date
  ) values(
    sid,uid,p_mode,coalesce(p_params,'{}'::jsonb),greatest(0,coalesce(p_position,0)),now(),
    coalesce(p_completed,false),coalesce(nullif(p_title,''),'GK Practice'),
    null,'{}'::jsonb,coalesce(p_option_orders,'{}'::jsonb),coalesce(p_answers,'{}'::jsonb),
    greatest(0,coalesce(p_position,0)),case when p_completed then null else now() end,'2.1',now(),
    (now() at time zone 'Asia/Kolkata')::date
  )
  on conflict(session_id) do update set
    mode=excluded.mode,params=excluded.params,
    current_index=greatest(gk.sessions.current_index,excluded.current_index),
    position_index=greatest(coalesce(gk.sessions.position_index,gk.sessions.current_index,0),excluded.position_index),
    updated_at=now(),completed=gk.sessions.completed or excluded.completed,
    title=excluded.title,
    option_orders=case when jsonb_typeof(coalesce(gk.sessions.option_orders,'{}'::jsonb))='object'
      then coalesce(gk.sessions.option_orders,'{}'::jsonb)||coalesce(excluded.option_orders,'{}'::jsonb)
      else excluded.option_orders end,
    answers=case when jsonb_typeof(coalesce(gk.sessions.answers,'{}'::jsonb))='object'
      then coalesce(gk.sessions.answers,'{}'::jsonb)||coalesce(excluded.answers,'{}'::jsonb)
      else excluded.answers end,
    paused_at=case when gk.sessions.completed or excluded.completed then null else now() end,
    study_date=coalesce(gk.sessions.study_date,excluded.study_date)
  where gk.sessions.user_id=uid;

  delete from gk.session_questions sq
  where sq.session_id=sid
    and exists(select 1 from gk.sessions s where s.session_id=sid and s.user_id=uid);
  if p_question_ids is not null then
    for i in 1..coalesce(array_length(p_question_ids,1),0) loop
      insert into gk.session_questions(session_id,question_id,position)
      select sid,p_question_ids[i],i-1
      where exists(select 1 from gk.questions q where q.question_id=p_question_ids[i] and q.active)
      on conflict do nothing;
    end loop;
  end if;

  return jsonb_build_object('ok',true,'sessionId',sid,'completed',coalesce(p_completed,false));
end
$$;

create or replace function public.gk_get_resume_session()
returns jsonb
language plpgsql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); s gk.sessions%rowtype; out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select x.* into s from gk.sessions x
  where x.user_id=uid and not x.completed
  order by
    case when x.mode like 'daily%' and coalesce(x.study_date,(x.created_at at time zone 'Asia/Kolkata')::date)
      =(now() at time zone 'Asia/Kolkata')::date then 0 else 1 end,
    x.updated_at desc nulls last,x.created_at desc
  limit 1;
  if not found then return jsonb_build_object('ok',true,'session',null); end if;

  select jsonb_build_object(
    'sessionId',s.session_id,'title',coalesce(s.title,'GK Practice'),'mode',coalesce(s.mode,'practice'),
    'position',coalesce(s.position_index,s.current_index,0),'answers',coalesce(s.answers,'{}'::jsonb),
    'optionOrders',coalesce(s.option_orders,'{}'::jsonb),'params',coalesce(s.params,'{}'::jsonb),
    'questions',coalesce((
      select jsonb_agg(gk.question_payload_v2_read(uid,sq.question_id) order by sq.position)
      from gk.session_questions sq where sq.session_id=s.session_id
    ),'[]'::jsonb)
  ) into out;
  return jsonb_build_object('ok',true,'session',out);
end
$$;

-- Helper used by Daily and Demand-set creation to persist a deterministic question list.
create or replace function gk.persist_session_questions_v2(
  p_user_id uuid,p_session_id text,p_questions jsonb
) returns void
language plpgsql security definer
set search_path=pg_catalog,gk,auth
as $$
declare item jsonb; pos integer:=0;
begin
  for item in select value from jsonb_array_elements(coalesce(p_questions,'[]'::jsonb)) loop
    insert into gk.session_questions(session_id,question_id,position)
    select p_session_id,item->>'id',pos
    where exists(select 1 from gk.sessions s where s.session_id=p_session_id and s.user_id=p_user_id)
      and exists(select 1 from gk.questions q where q.question_id=item->>'id' and q.active)
    on conflict do nothing;
    pos:=pos+1;
  end loop;
end
$$;
revoke execute on function gk.persist_session_questions_v2(uuid,text,jsonb) from public,anon,authenticated,service_role;

-- Latest central selector: raw evidence for learning state; manual flags remain in QuestionState.
create or replace function public.gk_get_batch(
 p_mode text default 'smart',
 p_count integer default 20,
 p_lane text default 'MIXED',
 p_subject text default null,
 p_topic text default null,
 p_lecture_key text default null,
 p_library_key text default null,
 p_demand_id text default null,
 p_ca_months integer default null,
 p_ca_category text default null
) returns jsonb
language plpgsql
volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
 uid uuid:=auth.uid();
 mode_name text:=lower(btrim(coalesce(p_mode,'smart')));
 lane_name text:=upper(btrim(coalesce(p_lane,'MIXED')));
 n int:=greatest(1,least(1000,coalesce(p_count,20)));
 age_from int:=null; age_to int:=null;
 group_kind text:=case when coalesce(p_count,20)=10 then 'random'
   when coalesce(p_count,20)=20 then 'smart' else 'all' end;
 out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if lane_name not in ('MAIN','RAPID','MIXED','ALL') then raise exception 'Invalid GK question style'; end if;
 if mode_name ~ '^starred_age_[0-9]+_[0-9]+$' then
   age_from:=split_part(mode_name,'_',3)::int; age_to:=split_part(mode_name,'_',4)::int;
   return public.gk_get_starred_group_batch(age_from,age_to,false,group_kind,n);
 end if;
 if mode_name='starred_earlier' then
   return public.gk_get_starred_group_batch(null,null,true,group_kind,n);
 end if;

 with legacy_owner as (
   select case when count(distinct x.user_id)=1 then min(x.user_id) end uid
   from (
     select user_id from gk.attempts union all select user_id from gk.exposures
     union all select user_id from gk.question_state union all select user_id from gk.sessions
   ) x
 ), profile as (
   select * from gk.learning_profiles_v2(uid)
 ), base as (
   select q.*,
     p.learning_state st,p.wrong,p.due,p.next_review,p.last_attempt,p.last_guess_at,
     p.guessed_attempts,p.unconfirmed_guess,
     coalesce(s.difficult,false) difficult,coalesce(s.marked_review,false) starred,
     s.starred_at,
     p.exposure_count>0 exposed,p.last_seen last_seen_evidence,
     (select max(a.attempted_at) from gk.attempts a
       where a.user_id=uid and a.question_id=q.question_id
         and (a.mode like 'starred_%' or a.mode='review')) starred_last_revision,
     case when s.starred_at is null then null else
       greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) end starred_age_days,
     case p.learning_state
       when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700
       when 'Learning' then 500 when 'New' then 300 when 'Strong' then 180
       when 'Proven Mastered' then 20 else 0 end
       +case when p.due then 300 else 0 end
       +case when coalesce(s.difficult,false) then 180 else 0 end
       +case when p.unconfirmed_guess then 240 else 0 end
       +case when coalesce(s.marked_review,false) then 80 else 0 end
       +least(180,coalesce(floor(extract(epoch from(now()-p.last_attempt))/86400)::int*6,140))
       +case when q.subject='Current Affairs' and q.source_date is not null
          then greatest(0,120-(current_date-q.source_date)) else 0 end as priority
   from gk.questions q
   join profile p on p.question_id=q.question_id
   left join gk.question_state s on s.user_id=uid and s.question_id=q.question_id
   where q.active
     and (lane_name in ('MIXED','ALL') or upper(q.content_lane)=lane_name)
     and (p_subject is null or q.subject=p_subject)
     and (p_topic is null or q.topic=p_topic)
     and (p_lecture_key is null or q.lecture_key=p_lecture_key)
     and (p_library_key is null or gk.derive_library_key(q.question_id,q.source_label,q.subject)=p_library_key)
     and (p_ca_category is null or q.topic=p_ca_category)
     and (p_ca_months is null or p_ca_months<=0
       or q.source_date>=((current_date-make_interval(months=>p_ca_months))::date))
     and (p_demand_id is null or exists(
       select 1 from gk.demand_sets d,
         jsonb_array_elements_text(coalesce(d.question_ids,'[]'::jsonb)) j(question_id),
         legacy_owner lo
       where d.demand_id=p_demand_id and d.active and j.question_id=q.question_id
         and (d.user_id=uid or (d.user_id is null and lo.uid=uid))
     ))
 ), eligible as (
   select * from base b where case
     when mode_name in ('new','unseen','new_v2','new_random') then not b.exposed
     when mode_name in ('weak','weak_practice') then b.st in ('Persistent Weak','Weak','Fragile')
     when mode_name='persistent_weak' then b.st='Persistent Weak'
     when mode_name='starred_persistent' then b.starred and b.st='Persistent Weak'
     when mode_name in ('due','due_recall') then b.due
     when mode_name='difficult' then b.difficult
     when mode_name in ('starred','starred_smart') then b.starred
     when mode_name='starred_weak' then b.starred and b.st in ('Persistent Weak','Weak','Fragile')
     when mode_name='starred_due' then b.starred and b.due
     when mode_name='starred_difficult' then b.starred and b.difficult
     when mode_name='starred_never' then b.starred and b.starred_last_revision is null
     when mode_name in ('starred_longest','starred_oldest','starred_random') then b.starred
     when mode_name in ('guessed','guessed_smart','guessed_random','guessed_oldest','guessed_longest')
       then b.unconfirmed_guess
     when mode_name='guessed_recent' then b.unconfirmed_guess
       and b.last_guess_at>=now()-interval '7 days'
     when mode_name='guessed_repeated' then b.unconfirmed_guess and b.guessed_attempts>=2
     when mode_name='guessed_weak' then b.unconfirmed_guess and b.st in ('Persistent Weak','Weak','Fragile')
     when mode_name='guessed_due' then b.unconfirmed_guess and b.due
     when mode_name='guessed_never_confirmed' then b.unconfirmed_guess
       and (select confirmed_unguessed_spaced_recalls from profile p where p.question_id=b.question_id)=0
     when mode_name in ('recall','recall_check') then b.exposed and b.st<>'Proven Mastered'
     when mode_name in ('daily','smart') then b.st<>'Proven Mastered'
     when mode_name like 'current_%' then b.subject='Current Affairs'
     else true
   end
 ), ranked as (
   select e.*,row_number() over(order by
     case when mode_name in ('random','new_random','starred_random','guessed_random','current_random')
       then random() else 0 end,
     case when mode_name='long_unseen'
       then extract(epoch from coalesce(e.last_seen_evidence,to_timestamp(0))) else 0 end asc,
     case when mode_name in ('starred_longest','starred_oldest')
       then extract(epoch from coalesce(e.starred_last_revision,to_timestamp(0))) else 0 end asc,
     case when mode_name in ('guessed_oldest','guessed_longest')
       then extract(epoch from coalesce(e.last_guess_at,to_timestamp(0))) else 0 end asc,
     case when mode_name='guessed_recent'
       then extract(epoch from coalesce(e.last_guess_at,to_timestamp(0))) else 0 end desc,
     case when mode_name='starred_smart' then
       e.priority+least(320,greatest(0,floor(extract(epoch from(
         now()-coalesce(e.starred_last_revision,e.starred_at,to_timestamp(0))
       ))/86400)::int)*10) else e.priority end desc,
     e.priority desc,e.question_id
   ) ord
   from eligible e
 ), chosen as(select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c;
 return out;
end
$$;

create or replace function public.gk_get_scope_batch(
  p_mode text default 'all',p_count integer default 20,p_lane text default 'MIXED',
  p_subject text default null,p_topic text default null,p_lecture_key text default null,
  p_library_key text default null,p_ca_months integer default null,p_ca_category text default null
) returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  return public.gk_get_batch(p_mode,greatest(1,least(1000,coalesce(p_count,20))),p_lane,
    p_subject,p_topic,p_lecture_key,p_library_key,null,p_ca_months,p_ca_category);
end
$$;

create or replace function public.gk_get_catalog()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
qb as (
 select q.*,gk.derive_library_key(q.question_id,q.source_label,q.subject) library_key,
   p.exposure_count>0 exposed,p.learning_state st
 from gk.questions q join p on p.question_id=q.question_id where q.active
), lectures as (
 select library_key,q.lecture_key,q.lecture_no,
   max(coalesce(nullif(q.source_label,''),l.title,'Lecture')) title,max(q.source_date) source_date,
   count(*)::int total,count(*) filter(where upper(q.content_lane)='MAIN')::int main,
   count(*) filter(where upper(q.content_lane)='RAPID')::int rapid,
   count(*) filter(where exposed)::int attempted,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak
 from qb q left join gk.lectures l on l.lecture_key=q.lecture_key
 where q.lecture_key is not null group by library_key,q.lecture_key,q.lecture_no
), libraries as (
 select x.key,x.title,x.icon,count(l.lecture_key)::int lectures,coalesce(sum(l.total),0)::int questions
 from (values('subject-pyq','Subject-wise PYQ','▤'),('mixed','Mixed PYQ','▦'),
   ('nitto','Nitto Series','⚡'),('misc','MISC','◫')) x(key,title,icon)
 left join lectures l on l.library_key=x.key group by x.key,x.title,x.icon
), topics as (
 select coalesce(nullif(btrim(q.subject),''),'Unclassified') subject,
   coalesce(nullif(btrim(q.topic),''),'General') topic,count(*)::int total,
   count(*) filter(where upper(q.content_lane)='MAIN')::int main,
   count(*) filter(where upper(q.content_lane)='RAPID')::int rapid,
   count(*) filter(where q.st in ('Persistent Weak','Weak','Fragile'))::int weak
 from qb q group by 1,2
), subjects as (
 select subject,sum(total)::int total,sum(main)::int main,sum(rapid)::int rapid,sum(weak)::int weak,
   jsonb_agg(jsonb_build_object('topic',topic,'total',total,'main',main,'rapidRecall',rapid,'weak',weak)
     order by total desc,topic) topics from topics group by subject
), ca as (
 select coalesce(nullif(btrim(topic),''),'General') category,count(*)::int count,
   min(source_date) "minDate",max(source_date) "maxDate"
 from qb where subject='Current Affairs' group by 1
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object(
 'ok',true,
 'libraries',(select jsonb_agg(to_jsonb(libraries)
   order by case key when 'subject-pyq' then 1 when 'mixed' then 2 when 'nitto' then 3 else 4 end) from libraries),
 'lectures',(select coalesce(jsonb_agg(jsonb_build_object(
   'libraryKey',library_key,'lectureKey',lecture_key,'lectureNo',lecture_no,'title',title,
   'sourceDate',source_date,'total',total,'main',main,'rapidRecall',rapid,'attempted',attempted,'weak',weak
 ) order by source_date,lecture_key),'[]'::jsonb) from lectures),
 'subjects',(select coalesce(jsonb_agg(jsonb_build_object(
   'subject',subject,'total',total,'main',main,'rapidRecall',rapid,'weak',weak,'topics',topics
 ) order by total desc,subject),'[]'::jsonb) from subjects),
 'currentAffairs',(select coalesce(jsonb_agg(to_jsonb(ca) order by count desc,category),'[]'::jsonb) from ca),
 'demandSets','[]'::jsonb
) end
$$;

create or replace function public.gk_get_home_snapshot()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
state as (
 select p.*,coalesce(s.marked_review,false) starred,coalesce(s.difficult,false) difficult
 from p left join gk.question_state s on s.user_id=(select uid from u) and s.question_id=p.question_id
), top as (
 select count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
   count(*) filter(where learning_state='Persistent Weak')::int persistent_weak,
   count(*) filter(where learning_state='Weak')::int weak,
   count(*) filter(where learning_state='Fragile')::int fragile,
   count(*) filter(where learning_state='Strong')::int strong,
   count(*) filter(where learning_state='Proven Mastered')::int proven_mastered,
   count(*) filter(where due)::int due,count(*) filter(where starred)::int starred,
   count(*) filter(where difficult)::int difficult,
   count(*) filter(where unconfirmed_guess)::int guessed,
   count(*) filter(where exposure_count=0)::int new_questions,
   coalesce(round(count(*) filter(where first_attempt_correct is true)*100.0/
     nullif(count(*) filter(where first_attempt_correct is not null),0),1),0) first_accuracy,
   coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention_accuracy
 from state
), resume as (
 select s.* from gk.sessions s cross join u where s.user_id=u.uid and not s.completed
 order by case when s.mode like 'daily%' and coalesce(s.study_date,(s.created_at at time zone 'Asia/Kolkata')::date)
   =(now() at time zone 'Asia/Kolkata')::date then 0 else 1 end,
   s.updated_at desc nulls last,s.created_at desc limit 1
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object('ok',true,'summary',jsonb_build_object(
 'total',total,'eligibleTotal',total-proven_mastered,
 'eligibleMain',(select count(*) from gk.questions q join state s on s.question_id=q.question_id
   where q.active and upper(q.content_lane)='MAIN' and s.learning_state<>'Proven Mastered'),
 'eligibleRapidRecall',(select count(*) from gk.questions q join state s on s.question_id=q.question_id
   where q.active and upper(q.content_lane)='RAPID' and s.learning_state<>'Proven Mastered'),
 'exposed',exposed,'bankExposure',case when total>0 then round(exposed*100.0/total,1) else 0 end,
 'persistentWeak',persistent_weak,'weak',weak,'fragile',fragile,'strong',strong,
 'provenMastered',proven_mastered,'due',due,'starred',starred,'difficult',difficult,
 'guessed',guessed,'firstAttemptAccuracy',first_accuracy,'retentionAccuracy',retention_accuracy,
 'newQuestions',new_questions
),'resume',(select to_jsonb(resume) from resume)) end
from top
$$;

create or replace function public.gk_get_starred_hub()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
rows as (
 select s.question_id,p.learning_state,p.next_review,coalesce(s.difficult,false) difficult,
   s.starred_at,p.unconfirmed_guess,
   case when s.starred_at is null then null else greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) end age,
   (select max(a.attempted_at) from gk.attempts a where a.user_id=u.uid and a.question_id=s.question_id
     and (a.mode like 'starred_%' or a.mode='review')) last_starred_revision
 from gk.question_state s cross join u join p on p.question_id=s.question_id
 join gk.questions q on q.question_id=s.question_id and q.active
 where s.user_id=u.uid and s.marked_review
), exact_days as (
 select age,('Day '||(age+1)) label,age age_from,age age_to from generate_series(0,9) age
), later_bands as (
 select 10 age,'Days 11–20' label,10 age_from,19 age_to union all
 select 20,'Days 21–30',20,29 union all
 select start_age,('Days '||(start_age+1)||'–'||(start_age+30)),start_age,start_age+29
 from generate_series(30,greatest(30,coalesce((select max(age) from rows),30)),30) start_age
), dated_groups as (
 select d.label,d.age_from,d.age_to,count(r.question_id)::int count,
   count(*) filter(where r.learning_state='Persistent Weak')::int persistent_weak,
   count(*) filter(where r.learning_state in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where r.next_review<=now())::int due,
   count(*) filter(where r.difficult)::int difficult,
   count(*) filter(where r.learning_state not in ('Persistent Weak','Weak','Fragile')
     and not coalesce(r.next_review<=now(),false))::int healthy
 from (select * from exact_days union all select * from later_bands) d
 left join rows r on r.age between d.age_from and d.age_to
 group by d.age,d.label,d.age_from,d.age_to having count(r.question_id)>0
), earlier as (
 select 'Earlier'::text label,null::int age_from,null::int age_to,count(*)::int count,
   count(*) filter(where learning_state='Persistent Weak')::int persistent_weak,
   count(*) filter(where learning_state in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where next_review<=now())::int due,count(*) filter(where difficult)::int difficult,
   count(*) filter(where learning_state not in ('Persistent Weak','Weak','Fragile')
     and not coalesce(next_review<=now(),false))::int healthy
 from rows where starred_at is null having count(*)>0
), groups as(select * from dated_groups union all select * from earlier),
summary as (
 select count(*)::int starred,
   count(*) filter(where learning_state in ('Persistent Weak','Weak','Fragile')
     or next_review<=now() or unconfirmed_guess)::int focus,
   count(*) filter(where difficult)::int difficult,
   count(*) filter(where learning_state='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,
   count(*) filter(where last_starred_revision is null)::int never_revised
 from rows
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object('ok',true,'summary',(select to_jsonb(summary) from summary),
 'groups',(select coalesce(jsonb_agg(jsonb_build_object(
   'label',label,'ageFrom',age_from,'ageTo',age_to,'count',count,
   'health',jsonb_build_object('persistentWeak',persistent_weak,'weakFragile',weak_fragile,
     'due',due,'difficult',difficult,'healthy',healthy)
 ) order by case when age_to<=9 then 0 when age_from is not null then 1 else 2 end,
   case when age_to<=9 then -age_from else age_from end nulls last),'[]'::jsonb) from groups)) end
$$;

create or replace function public.gk_get_starred_group_batch(
 p_age_from integer default null,p_age_to integer default null,p_earlier boolean default false,
 p_kind text default 'smart',p_count integer default 20
) returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); kind_name text:=lower(btrim(coalesce(p_kind,'smart')));
 n int:=greatest(1,least(1000,coalesce(p_count,20))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with p as(select * from gk.learning_profiles_v2(uid)), rows as (
   select q.question_id,p.learning_state,p.due,coalesce(s.difficult,false) difficult,
     p.unconfirmed_guess,s.starred_at,
     (select max(a.attempted_at) from gk.attempts a where a.user_id=uid and a.question_id=q.question_id
       and (a.mode like 'starred_%' or a.mode='review')) last_starred_revision,
     case p.learning_state when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700
       when 'Learning' then 500 when 'Strong' then 180 when 'Proven Mastered' then 20 else 300 end
       +case when p.due then 300 else 0 end+case when coalesce(s.difficult,false) then 180 else 0 end
       +case when p.unconfirmed_guess then 240 else 0 end priority
   from gk.question_state s join gk.questions q on q.question_id=s.question_id and q.active
   join p on p.question_id=q.question_id
   where s.user_id=uid and coalesce(s.marked_review,false) and (
     (coalesce(p_earlier,false) and s.starred_at is null) or
     (not coalesce(p_earlier,false) and s.starred_at is not null
       and greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int)
         between coalesce(p_age_from,0) and coalesce(p_age_to,2147483647))
   )
 ), ranked as (
   select r.*,row_number() over(order by
     case when kind_name='random' then random() else 0 end,
     case when kind_name='smart' then priority else 0 end desc,
     case when kind_name='all' then extract(epoch from coalesce(starred_at,to_timestamp(0))) else 0 end desc,
     question_id) ord from rows r
 ), chosen as(select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c; return out;
end
$$;

create or replace function public.gk_get_guessed_hub()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
rows as (
 select q.question_id,q.question,q.subject,q.topic,p.learning_state,p.guessed_attempts,p.due,
   p.confirmed_unguessed_spaced_recalls,p.last_guess_at
 from p join gk.questions q on q.question_id=p.question_id and q.active
 where p.unconfirmed_guess
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object('ok',true,'summary',jsonb_build_object(
 'unresolved',(select count(*) from rows),'repeated',(select count(*) from rows where guessed_attempts>=2),
 'weak',(select count(*) from rows where learning_state in ('Persistent Weak','Weak','Fragile')),
 'due',(select count(*) from rows where due)
),'rows',coalesce((select jsonb_agg(jsonb_build_object(
 'id',question_id,'question',question,'subject',coalesce(subject,'Unclassified'),'topic',coalesce(topic,'General'),
 'learningState',learning_state,'guessedAttempts',guessed_attempts,'repeatedlyGuessed',guessed_attempts>=2,
 'due',due,'confirmedUnguessedSpacedRecalls',confirmed_unguessed_spaced_recalls
) order by last_guess_at desc nulls last,question_id) from rows),'[]'::jsonb)) end
$$;

create or replace function public.gk_get_on_demand_hub()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
b as (
 select q.question_id,q.subject,q.topic,q.concept_id,p.learning_state st,p.unconfirmed_guess guessed,
   coalesce(s.difficult,false) difficult,p.retention_accuracy,p.exposure_count>0 exposed
 from gk.questions q join p on p.question_id=q.question_id
 left join gk.question_state s on s.user_id=(select uid from u) and s.question_id=q.question_id
 where q.active
), concepts as (
 select coalesce(subject,'Unclassified')||'|'||coalesce(topic,'General')||'|'||coalesce(nullif(concept_id,''),'') concept_id,
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*) filter(where st='Persistent Weak')::int persistent_weak,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   coalesce(round(avg(retention_accuracy) filter(where retention_accuracy>0),1),0) retention_accuracy
 from b group by coalesce(subject,'Unclassified'),coalesce(topic,'General'),coalesce(nullif(concept_id,''),'')
), legacy_owner as (
 select case when count(distinct x.user_id)=1 then min(x.user_id) end uid
 from (select user_id from gk.attempts union all select user_id from gk.exposures
   union all select user_id from gk.question_state union all select user_id from gk.sessions) x
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object('ok',true,'stats',jsonb_build_object(
 'weak',(select count(*) from b where st in ('Persistent Weak','Weak','Fragile')),
 'guessed',(select count(*) from b where guessed),'difficult',(select count(*) from b where difficult),
 'longUnseen',(select count(*) from b where not exposed)
),'weakTopics',(select coalesce(jsonb_agg(to_jsonb(x) order by persistent_weak desc,weak desc,topic),'[]'::jsonb)
 from (select * from concepts where weak>0 limit 30) x),
'myDemandSets',(select coalesce(jsonb_agg(jsonb_build_object(
 'demandId',demand_id,'title',coalesce(title,demand_id),'kind',kind,
 'count',jsonb_array_length(coalesce(question_ids,'[]'::jsonb)),'lastUsed',last_used
) order by coalesce(last_used,created_at) desc nulls last,demand_id),'[]'::jsonb)
 from gk.demand_sets d,legacy_owner lo
 where d.active and (d.user_id=(select uid from u) or (d.user_id is null and lo.uid=(select uid from u))))) end
$$;

create or replace function public.gk_get_progress()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
base as (
 select q.question_id,q.subject,q.topic,q.concept_id,q.lecture_key,q.source_label,q.source_date,
   p.learning_state st,p.retention_attempts ret_attempts,p.retention_correct ret_correct,
   coalesce(s.marked_review,false) starred,coalesce(s.difficult,false) difficult,
   p.guessed_attempts,p.unconfirmed_guess guessed,p.next_review,p.exposure_count>0 exposed,
   p.first_attempt_correct first_ok
 from gk.questions q join p on p.question_id=q.question_id
 left join gk.question_state s on s.user_id=(select uid from u) and s.question_id=q.question_id
 where q.active
), subject_rows as (
 select coalesce(subject,'Unclassified') subject,count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base group by 1
), concepts as (
 select coalesce(subject,'Unclassified')||'|'||coalesce(topic,'General')||'|'||coalesce(nullif(concept_id,''),'') "conceptId",
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*)::int total,count(*) filter(where exposed)::int attempted,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st in ('Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,count(*) filter(where guessed)::int guessed,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base group by coalesce(subject,'Unclassified'),coalesce(topic,'General'),coalesce(nullif(concept_id,''),'')
), lectures as (
 select lecture_key,max(source_label) title,count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered
 from base where lecture_key is not null group by lecture_key
), ca as (
 select case when source_date>=current_date-interval '1 month' then '1 Month'
   when source_date>=current_date-interval '3 months' then '3 Months'
   when source_date>=current_date-interval '6 months' then '6 Months' else 'Older' end band,
   count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where guessed)::int guessed
 from base where subject='Current Affairs' group by 1
), top as (
 select count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st='Weak')::int weak,count(*) filter(where st='Fragile')::int fragile,
   count(*) filter(where st='Strong')::int strong,count(*) filter(where st='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,count(*) filter(where starred)::int starred,
   count(*) filter(where difficult)::int difficult,count(*) filter(where guessed)::int guessed,
   coalesce(round(count(*) filter(where first_ok is true)*100.0/
     nullif(count(*) filter(where first_ok is not null),0),1),0) "firstAccuracy",
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base
), concept_top as (
 select count(*) filter(where "persistentWeak">0)::int "persistentWeakConcepts",
   count(*) filter(where weak>0 or "persistentWeak">0)::int "weakConcepts" from concepts
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object(
 'ok',true,'overview',(select to_jsonb(top)||to_jsonb(concept_top) from top cross join concept_top),
 'knowledgeHealth',(select jsonb_build_array(
   jsonb_build_object('state','Persistent Weak','count',"persistentWeak"),
   jsonb_build_object('state','Weak','count',weak),jsonb_build_object('state','Fragile','count',fragile),
   jsonb_build_object('state','Strong','count',strong),jsonb_build_object('state','Proven Mastered','count',mastered)
 ) from top),
 'subjectMastery',(select coalesce(jsonb_agg(to_jsonb(subject_rows) order by total desc,subject),'[]'::jsonb) from subject_rows),
 'weakConcepts',(select coalesce(jsonb_agg(to_jsonb(c) order by "persistentWeak" desc,weak desc,total desc),'[]'::jsonb)
   from (select * from concepts where "persistentWeak"+weak>0 limit 50) c),
 'currentAffairsHealth',(select coalesce(jsonb_agg(to_jsonb(ca)
   order by case band when '1 Month' then 1 when '3 Months' then 2 when '6 Months' then 3 else 4 end),'[]'::jsonb) from ca),
 'starredHealth',(select jsonb_build_object(
   'total',starred,'focus',(select count(*) from base where starred and
     (st in ('Persistent Weak','Weak','Fragile') or next_review<=now() or guessed)),
   'due',(select count(*) from base where starred and next_review<=now()),
   'difficult',(select count(*) from base where starred and difficult),
   'mastered',(select count(*) from base where starred and st='Proven Mastered')) from top),
 'guessedHealth',(select jsonb_build_object(
   'historicallyGuessed',(select count(*) from base where guessed_attempts>0),'unresolved',guessed,
   'repeated',(select count(*) from base where guessed and guessed_attempts>=2),
   'due',(select count(*) from base where guessed and next_review<=now())) from top),
 'difficultResolution',(select jsonb_build_object(
   'total',difficult,'resolvedStrong',(select count(*) from base where difficult and st in ('Strong','Proven Mastered')),
   'needsFocus',(select count(*) from base where difficult and
     (st in ('Persistent Weak','Weak','Fragile') or next_review<=now()))) from top),
 'lectureCoverage',(select coalesce(jsonb_agg(jsonb_build_object(
   'lecture_key',lecture_key,'title',title,'total',total,'exposed',exposed,'weak',weak,'mastered',mastered
 ) order by case when total>0 then exposed::numeric/total else 0 end asc,title),'[]'::jsonb) from lectures)
) end
$$;

create or replace function public.gk_get_question_intelligence(
 p_question_id text,p_session_id text default null
) returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), q as(
 select * from gk.questions where question_id=p_question_id and active
), profile as(
 select * from gk.learning_profiles_v2((select uid from u)) where question_id=p_question_id
), payload as(
 select gk.question_payload_v2_read((select uid from u),p_question_id) p
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else coalesce((select p->'state' from payload),'{}'::jsonb)||jsonb_build_object(
 'ok',true,'questionId',q.question_id,'conceptId',q.concept_id,'subject',q.subject,'topic',q.topic,
 'lectureKey',q.lecture_key,'selectionReason',coalesce((
   select s.composition->'reasons'->>q.question_id from gk.sessions s
   where s.user_id=(select uid from u) and s.session_id=p_session_id
 ),''),'conceptHealth',(
   select jsonb_build_object(
     'total',count(*),'attempted',count(*) filter(where px.exposure_count>0),
     'weak',count(*) filter(where px.learning_state in ('Persistent Weak','Weak','Fragile')),
     'mastered',count(*) filter(where px.learning_state='Proven Mastered'),
     'guessed',count(*) filter(where px.unconfirmed_guess)
   )
   from gk.questions q2 join gk.learning_profiles_v2((select uid from u)) px
     on px.question_id=q2.question_id
   where q2.active
     and coalesce(q2.subject,'Unclassified')=coalesce(q.subject,'Unclassified')
     and coalesce(q2.topic,'General')=coalesce(q.topic,'General')
     and coalesce(q2.concept_id,'')=coalesce(q.concept_id,'')
 )) end
from q
$$;

create or replace function public.gk_get_concept_catalog(
 p_subject text default null,p_topic text default null
) returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
rows as (
 select coalesce(q.subject,'Unclassified')||'|'||coalesce(q.topic,'General')||'|'||
     coalesce(q.concept_id,'') concept_id,
   coalesce(q.subject,'Unclassified') subject,coalesce(q.topic,'General') topic,
   count(*)::int total,count(*) filter(where upper(q.content_lane)='MAIN')::int main,
   count(*) filter(where upper(q.content_lane)='RAPID')::int rapid,
   count(*) filter(where p.learning_state in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where p.exposure_count=0)::int unseen,
   count(*) filter(where p.learning_state='Proven Mastered')::int mastered
 from gk.questions q join p on p.question_id=q.question_id
 where q.active and nullif(btrim(q.concept_id),'') is not null
   and (p_subject is null or q.subject=p_subject) and (p_topic is null or q.topic=p_topic)
 group by coalesce(q.subject,'Unclassified'),coalesce(q.topic,'General'),coalesce(q.concept_id,'')
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object('ok',true,'concepts',coalesce((select jsonb_agg(jsonb_build_object(
 'conceptId',concept_id,'subject',subject,'topic',topic,'total',total,'main',main,
 'rapidRecall',rapid,'weak',weak,'unseen',unseen,'mastered',mastered
) order by subject,topic,concept_id) from rows),'[]'::jsonb)) end
$$;

create or replace function public.gk_start_daily(p_count integer default 20)
returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); today date:=(now() at time zone 'Asia/Kolkata')::date;
 s gk.sessions%rowtype; qs jsonb; sid text; n int:=greatest(1,least(1000,coalesce(p_count,20)));
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select x.* into s from gk.sessions x where x.user_id=uid and x.mode like 'daily%'
   and coalesce(x.study_date,(x.created_at at time zone 'Asia/Kolkata')::date)=today
 order by x.completed asc,x.updated_at desc nulls last,x.created_at desc limit 1;
 if found then
   if s.completed then return jsonb_build_object('ok',false,'completed',true,'sessionId',s.session_id,
     'title',coalesce(s.title,'Daily Revision'),'mode','daily','questions','[]'::jsonb); end if;
   return (public.gk_get_resume_session()->'session')||jsonb_build_object('ok',true);
 end if;

 qs:=public.gk_get_batch('daily',n,'MIXED',null,null,null,null,null,null,null);
 if jsonb_array_length(coalesce(qs,'[]'::jsonb))=0 then
   return jsonb_build_object('ok',false,'sessionId','','title','Daily Revision','mode','daily','questions','[]'::jsonb);
 end if;
 sid:='gk-daily-'||gen_random_uuid()::text;
 insert into gk.sessions(session_id,user_id,mode,params,current_index,position_index,updated_at,completed,title,
   option_orders,answers,composition,session_version,created_at,study_date)
 values(sid,uid,'daily',jsonb_build_object('mode','daily'),0,0,now(),false,'Daily Revision',
   '{}'::jsonb,'{}'::jsonb,'{}'::jsonb,'2.1',now(),today);
 perform gk.persist_session_questions_v2(uid,sid,qs);
 return jsonb_build_object('ok',true,'sessionId',sid,'title','Daily Revision','mode','daily',
   'position',0,'answers','{}'::jsonb,'optionOrders','{}'::jsonb,'questions',qs);
end
$$;

create or replace function public.gk_create_demand_set(
 p_kind text,p_count integer default 20,p_title text default null
) returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); kind_name text:=lower(btrim(coalesce(p_kind,'weak')));
 mode_name text; title_name text; qs jsonb; sid text; ids jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 mode_name:=case kind_name when 'guessed' then 'guessed_smart' when 'difficult' then 'difficult'
   when 'long_unseen' then 'long_unseen' else 'weak' end;
 title_name:=coalesce(nullif(btrim(p_title),''),
   case kind_name when 'guessed' then 'Guessed Focus' when 'difficult' then 'Difficult Focus'
     when 'long_unseen' then 'Long Time No See' else 'Fix Weaknesses' end);
 qs:=public.gk_get_batch(mode_name,greatest(1,least(1000,coalesce(p_count,20))),'MIXED',
   null,null,null,null,null,null,null);
 if jsonb_array_length(coalesce(qs,'[]'::jsonb))=0 then
   return jsonb_build_object('ok',false,'message','No eligible questions for this set.'); end if;
 ids:=(select jsonb_agg(value->>'id' order by ord)
   from jsonb_array_elements(qs) with ordinality x(value,ord));
 sid:='DMD-'||gen_random_uuid()::text;
 insert into gk.demand_sets(demand_id,user_id,title,kind,criteria,question_ids,created_at,active)
 values(sid,uid,title_name,kind_name,jsonb_build_object('kind',kind_name,'count',p_count),ids,now(),true);
 return jsonb_build_object('ok',true,'setId',sid,'title',title_name);
end
$$;

-- Active-bank canonical corrections. Raw migration evidence and all historical user
-- attempts remain untouched; these guards only repair future answer mapping.
update gk.questions set correct_option='C'
where question_id='POL2-RR036' and active and correct_option='1/3'
  and option_c='1/6' and explanation ilike '%one-sixth%';
update gk.questions set correct_option='D'
where question_id='POL2-RR053' and active and correct_option='26 November 1949'
  and option_d='29 August 1947' and explanation ilike '%29 August%1947%';

-- Canonical client mutation path only. RLS remains defense-in-depth; browser code does
-- not need direct table DML on private learning state.
revoke all on gk.attempts,gk.exposures,gk.question_state,gk.sessions,gk.session_questions,
  gk.user_notes,gk.flags,gk.demand_sets from anon,authenticated;
grant select on gk.questions,gk.lectures to authenticated;

do $$
declare sig regprocedure;
begin
  foreach sig in array array[
    'public.gk_submit_answer(text,text,boolean,text,text,text)'::regprocedure,
    'public.gk_record_exposure(text,text,text,text)'::regprocedure,
    'public.gk_mark_guessed(text,text,boolean,text)'::regprocedure,
    'public.gk_save_session(text,text,text,integer,jsonb,jsonb,text[],boolean,jsonb)'::regprocedure,
    'public.gk_get_resume_session()'::regprocedure,
    'public.gk_start_daily(integer)'::regprocedure,
    'public.gk_create_demand_set(text,integer,text)'::regprocedure,
    'public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text)'::regprocedure,
    'public.gk_get_scope_batch(text,integer,text,text,text,text,text,integer,text)'::regprocedure,
    'public.gk_get_catalog()'::regprocedure,
    'public.gk_get_concept_catalog(text,text)'::regprocedure,
    'public.gk_get_home_snapshot()'::regprocedure,
    'public.gk_get_starred_hub()'::regprocedure,
    'public.gk_get_starred_group_batch(integer,integer,boolean,text,integer)'::regprocedure,
    'public.gk_get_guessed_hub()'::regprocedure,
    'public.gk_get_on_demand_hub()'::regprocedure,
    'public.gk_get_progress()'::regprocedure,
    'public.gk_get_question_intelligence(text,text)'::regprocedure
  ] loop
    execute format('revoke execute on function %s from public,anon',sig);
    execute format('grant execute on function %s to authenticated',sig);
  end loop;
end
$$;

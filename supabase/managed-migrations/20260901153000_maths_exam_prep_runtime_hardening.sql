-- Maths Exam Preparation runtime hardening.
-- Scope: timed-session identity/resume, exam answer secrecy, authoritative expiry,
-- review clarity, and a single active timed Maths session per user.
-- Normal Daily / Chapters / Library / On Demand selection remains unchanged.

create or replace function maths._get_session(p_uid uuid, p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  s maths.sessions%rowtype;
  attempts_ jsonb;
  flags_ jsonb;
  questions_ jsonb;
  total_ int;
  current_ int;
  hide_exam_answers boolean;
  timed_ boolean;
  remaining_ numeric;
begin
  select * into s from maths.sessions where session_id=p_session_id and user_id=p_uid;
  if not found then raise exception 'Session not found'; end if;

  total_ := coalesce(jsonb_array_length(s.rendered_questions),0);
  if total_=0 then
    select count(*) into total_ from maths.session_questions where session_id=s.session_id;
  end if;
  current_ := case when total_=0 then 0 else greatest(0,least(s.current_index,total_-1)) end;
  hide_exam_answers := lower(coalesce(s.mode,''))='section_sprint' and not s.completed;
  timed_ := lower(coalesce(s.mode,''))='section_sprint'
    or (lower(coalesce(s.mode,''))='calculation_speed' and coalesce(s.params->>'calculationTimed','false')='true');
  remaining_ := case
    when timed_ and nullif(s.params->>'deadlineAt','') is not null
      then greatest(0,extract(epoch from ((s.params->>'deadlineAt')::timestamptz-now())))
    else null
  end;

  select coalesce(jsonb_object_agg(a.question_id,jsonb_build_object(
    'result',case when hide_exam_answers then 'saved' else lower(coalesce(a.result,'')) end,
    'selectedOption',coalesce(a.selected_option,''),
    'responseSec',coalesce(a.response_sec,0),
    'attemptId',a.attempt_id
  )),'{}'::jsonb)
  into attempts_
  from (
    select distinct on(question_id) *
    from maths.attempts
    where user_id=p_uid and session_id=s.session_id
    order by question_id,attempted_at desc,attempt_id desc
  ) a;

  select coalesce(jsonb_object_agg(r.question_id,jsonb_build_object(
    'starred',r.starred,
    'difficult',r.difficult,
    'mastered',r.mastered,
    'inConcept',exists(
      select 1 from maths.concept_membership c
      where c.user_id=p_uid and c.question_id=r.question_id and c.active
    )
  )),'{}'::jsonb)
  into flags_
  from maths._user_runtime(p_uid) r
  where r.question_id in(
    select question_id from maths.session_questions where session_id=s.session_id
  );

  if hide_exam_answers then
    select coalesce(jsonb_agg(
      e - 'answer' - 'explanation' - 'memoryCue' - 'correctOption'
      order by ord
    ),'[]'::jsonb)
    into questions_
    from jsonb_array_elements(coalesce(s.rendered_questions,'[]'::jsonb)) with ordinality z(e,ord);
  else
    questions_ := coalesce(s.rendered_questions,'[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ok',true,
    'sessionId',s.session_id,
    'mode',coalesce(s.mode,''),
    'title',coalesce(s.title,''),
    'currentIndex',current_,
    'completed',s.completed,
    'target',total_,
    'params',coalesce(s.params,'{}'::jsonb),
    'remainingSeconds',remaining_,
    'expired',coalesce(remaining_<=0,false) and timed_ and not s.completed,
    'questions',questions_,
    'attempts',attempts_,
    'flags',flags_
  );
end
$$;

create or replace function public.maths_submit_answer(
  p_session_id text,
  p_question_id text,
  p_selected_option text default null,
  p_response_sec numeric default 0,
  p_client_attempt_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  s maths.sessions%rowtype;
  q maths.runtime_questions%rowtype;
  rendered jsonb;
  mode_ text;
  expected text;
  selected text:=upper(coalesce(p_selected_option,''));
  result_ text;
  idx int;
  key_ text:=coalesce(nullif(btrim(p_client_attempt_key),''),gen_random_uuid()::text);
  existing maths.attempts%rowtype;
  st maths.question_state%rowtype;
  next_ int;
  timed_ boolean;
  exam_ boolean;
begin
  perform pg_advisory_xact_lock(hashtext(uid::text||':'||p_session_id));
  select * into s from maths.sessions where session_id=p_session_id and user_id=uid;
  if not found then raise exception 'Session not found'; end if;

  exam_:=lower(coalesce(s.mode,''))='section_sprint';
  timed_:=exam_ or (lower(coalesce(s.mode,''))='calculation_speed' and coalesce(s.params->>'calculationTimed','false')='true');

  select * into existing from maths.attempts where client_attempt_key=key_ limit 1;
  if found then
    if existing.user_id<>uid or existing.session_id<>p_session_id or existing.question_id<>p_question_id then
      raise exception 'Attempt key conflict';
    end if;
    return jsonb_build_object(
      'ok',true,
      'deduped',true,
      'result',case when exam_ and not s.completed then 'saved' else existing.result end,
      'selectedOption',coalesce(existing.selected_option,''),
      'attemptId',existing.attempt_id
    );
  end if;

  if s.completed then raise exception 'Completed sessions cannot accept new attempts'; end if;

  if timed_ and nullif(s.params->>'deadlineAt','') is not null
     and (s.params->>'deadlineAt')::timestamptz<=now() then
    update maths.sessions
    set completed=true,
        updated_at=now(),
        params=jsonb_set(coalesce(params,'{}'::jsonb),'{finishedAt}',to_jsonb(now()::text),true)
    where session_id=p_session_id and user_id=uid;
    return jsonb_build_object('ok',false,'expired',true,'result','expired','message','Timed session has ended.');
  end if;

  select * into q from maths.runtime_questions where question_id=p_question_id and runtime_active;
  if not found then raise exception 'Question is missing or inactive'; end if;
  select e,ord::int-1 into rendered,idx
  from jsonb_array_elements(s.rendered_questions) with ordinality z(e,ord)
  where e->>'questionId'=p_question_id limit 1;
  if rendered is null then raise exception 'Question does not belong to this session'; end if;

  mode_:=upper(coalesce(rendered->>'answerMode','REVEAL'));
  expected:=upper(coalesce(rendered->>'correctOption',''));
  if mode_='MCQ' then
    if selected not in('A','B','C','D') then raise exception 'Selected option is required'; end if;
    if not exists(select 1 from jsonb_array_elements(rendered->'options') e where upper(e->>'key')=selected) then
      raise exception 'Selected option is invalid';
    end if;
    result_:=case when selected=expected then 'correct' else 'wrong' end;
  else
    result_:='seen';
    selected:='';
  end if;

  insert into maths.question_state(
    user_id,question_id,attempts,mastered,marked,last_attempt,last_result,last_response_sec,
    chapter,topic,subtopic,last_variant,last_correct_option,difficult
  ) values(
    uid,p_question_id,1,false,false,now(),result_,greatest(0,least(coalesce(p_response_sec,0),86400)),
    q.chapter,q.topic,q.subtopic,coalesce(rendered->>'variantType',''),expected,false
  )
  on conflict(user_id,question_id) do update
  set attempts=maths.question_state.attempts+1,
      last_attempt=excluded.last_attempt,
      last_result=excluded.last_result,
      last_response_sec=excluded.last_response_sec,
      chapter=coalesce(maths.question_state.chapter,excluded.chapter),
      topic=coalesce(maths.question_state.topic,excluded.topic),
      subtopic=coalesce(maths.question_state.subtopic,excluded.subtopic),
      last_variant=excluded.last_variant,
      last_correct_option=excluded.last_correct_option
  returning * into st;

  insert into maths.attempts(
    attempt_id,user_id,attempted_at,question_id,result,response_sec,mode,session_id,
    mastered_after,marked_after,variant_type,selected_option,question_index,client_attempt_key
  ) values(
    gen_random_uuid()::text,uid,now(),p_question_id,result_,greatest(0,least(coalesce(p_response_sec,0),86400)),
    s.mode,p_session_id,st.mastered,st.marked,coalesce(rendered->>'variantType',''),nullif(selected,''),idx,key_
  );

  next_:=least((select count(*) from maths.session_questions where session_id=p_session_id)-1,idx+1);
  update maths.sessions
  set current_index=greatest(current_index,next_),updated_at=now()
  where session_id=p_session_id and user_id=uid;

  if exam_ then
    return jsonb_build_object(
      'ok',true,'deduped',false,'result','saved','selectedOption',selected,'attemptId',key_
    );
  end if;

  return jsonb_build_object(
    'ok',true,'deduped',false,'result',result_,'correct',result_='correct','correctOption',expected,
    'selectedOption',selected,'attemptId',key_,'starred',st.marked,'difficult',st.difficult,'mastered',st.mastered
  );
end
$$;

create or replace function public.maths_get_active_exam_session()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  s maths.sessions%rowtype;
  total_ int;
  remaining_ numeric;
begin
  select * into s
  from maths.sessions
  where user_id=uid
    and not completed
    and (
      lower(coalesce(mode,''))='section_sprint'
      or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
    )
  order by updated_at desc nulls last,created_at desc
  limit 1;

  if not found then return jsonb_build_object('ok',true,'active',false); end if;
  select count(*) into total_ from maths.session_questions where session_id=s.session_id;
  remaining_:=case
    when nullif(s.params->>'deadlineAt','') is not null
      then greatest(0,extract(epoch from ((s.params->>'deadlineAt')::timestamptz-now())))
    else null
  end;
  return jsonb_build_object(
    'ok',true,'active',true,'sessionId',s.session_id,'mode',s.mode,'title',s.title,
    'currentIndex',greatest(0,least(s.current_index,greatest(0,total_-1))),'target',total_,
    'remainingSeconds',remaining_,'expired',coalesce(remaining_<=0,false),
    'review',coalesce(s.params->'examReview','[]'::jsonb),
    'visited',coalesce(s.params->'examVisited','[]'::jsonb)
  );
end
$$;

create or replace function public.maths_exam_runtime_checkpoint(
  p_session_id text,
  p_index integer,
  p_review integer[] default array[]::integer[],
  p_visited integer[] default array[]::integer[]
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  s maths.sessions%rowtype;
  total_ int;
  next_index int;
  review_ int[];
  visited_ int[];
begin
  select * into s from maths.sessions where session_id=p_session_id and user_id=uid;
  if not found then raise exception 'Timed session not found'; end if;
  if s.completed then return jsonb_build_object('ok',true,'completed',true,'currentIndex',s.current_index); end if;
  if not (
    lower(coalesce(s.mode,''))='section_sprint'
    or (lower(coalesce(s.mode,''))='calculation_speed' and coalesce(s.params->>'calculationTimed','false')='true')
  ) then raise exception 'Exam runtime checkpoint is only valid for timed sessions'; end if;

  select count(*) into total_ from maths.session_questions where session_id=p_session_id;
  next_index:=greatest(0,least(coalesce(p_index,0),greatest(0,total_-1)));
  select coalesce(array_agg(distinct x order by x),array[]::integer[]) into review_
  from unnest(coalesce(p_review,array[]::integer[])) x where x between 0 and greatest(0,total_-1);
  select coalesce(array_agg(distinct x order by x),array[]::integer[]) into visited_
  from unnest(coalesce(p_visited,array[]::integer[])) x where x between 0 and greatest(0,total_-1);

  update maths.sessions
  set current_index=next_index,
      params=jsonb_set(
        jsonb_set(coalesce(params,'{}'::jsonb),'{examReview}',to_jsonb(review_),true),
        '{examVisited}',to_jsonb(visited_),true
      ),
      updated_at=now()
  where session_id=p_session_id and user_id=uid;

  return jsonb_build_object('ok',true,'currentIndex',next_index,'review',to_jsonb(review_),'visited',to_jsonb(visited_));
end
$$;

create or replace function public.maths_get_sprint_review(p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  items jsonb;
begin
  if not exists(
    select 1 from maths.sessions s
    where s.user_id=uid and s.session_id=p_session_id
      and lower(coalesce(s.mode,''))='section_sprint' and s.completed
  ) then raise exception 'Completed Sprint not found'; end if;

  with rows as (
    select
      sq.position,
      sq.question_id,
      q.chapter,q.topic,q.subtopic,
      coalesce(rendered.e->>'prompt',q.prompt) prompt,
      coalesce(rendered.e->>'answer',q.answer) answer,
      coalesce(rendered.e->>'explanation',q.explanation) explanation,
      coalesce(rendered.e->>'correctOption',q.correct_option) correct_option,
      a.attempt_id,a.client_attempt_key,a.result,a.selected_option,a.response_sec,
      (select o->>'text' from jsonb_array_elements(coalesce(rendered.e->'options','[]'::jsonb)) o where upper(o->>'key')=upper(coalesce(a.selected_option,'')) limit 1) selected_option_text,
      (select o->>'text' from jsonb_array_elements(coalesce(rendered.e->'options','[]'::jsonb)) o where upper(o->>'key')=upper(coalesce(rendered.e->>'correctOption',q.correct_option,'')) limit 1) correct_option_text,
      pe.baseline_sec,pe.inferred_reason,pe.user_confirmed_reason,pe.final_reason,
      pe.inference_confidence,pe.slow_correct
    from maths.session_questions sq
    join maths.sessions s on s.session_id=sq.session_id and s.user_id=uid
    join maths.runtime_questions q on q.question_id=sq.question_id
    left join lateral (
      select e
      from jsonb_array_elements(coalesce(s.rendered_questions,'[]'::jsonb)) e
      where e->>'questionId'=sq.question_id limit 1
    ) rendered on true
    left join maths.attempts a
      on a.user_id=uid and a.session_id=p_session_id and a.question_id=sq.question_id
    left join lateral (
      select e.* from maths.performance_evidence e
      where e.user_id=uid and e.session_id=p_session_id and e.question_id=sq.question_id
      order by e.created_at desc limit 1
    ) pe on true
    where sq.session_id=p_session_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'position',position,'questionId',question_id,'chapter',chapter,'topic',topic,'subtopic',subtopic,
    'prompt',prompt,'answer',answer,'explanation',explanation,'correctOption',correct_option,
    'selectedOptionText',selected_option_text,'correctOptionText',correct_option_text,
    'attemptId',coalesce(attempt_id,client_attempt_key),'result',coalesce(result,'unattempted'),
    'selectedOption',selected_option,'responseSec',response_sec,'baselineSec',baseline_sec,
    'inferredReason',inferred_reason,'confirmedReason',user_confirmed_reason,'finalReason',final_reason,
    'inferenceConfidence',inference_confidence,'slowCorrect',coalesce(slow_correct,false)
  ) order by position) filter(
    where coalesce(result,'unattempted')<>'correct' or coalesce(slow_correct,false)
  ),'[]'::jsonb)
  into items from rows;

  return jsonb_build_object('ok',true,'sessionId',p_session_id,'items',items);
end
$$;

-- Prevent concurrent tabs from creating more than one live timed exam/drill for a user.
create unique index if not exists sessions_one_active_timed_exam_per_user
on maths.sessions(user_id)
where not completed and (
  lower(coalesce(mode,''))='section_sprint'
  or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
);

create or replace function public.maths_start_sprint(p_diagnostic boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  ids text[];
  active_id text;
begin
  perform pg_advisory_xact_lock(hashtext(uid::text||':timed-exam-start'));

  update maths.sessions
  set completed=true,updated_at=now(),params=jsonb_set(coalesce(params,'{}'::jsonb),'{finishedAt}',to_jsonb(now()::text),true)
  where user_id=uid and not completed
    and (
      lower(coalesce(mode,''))='section_sprint'
      or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
    )
    and nullif(params->>'deadlineAt','') is not null
    and (params->>'deadlineAt')::timestamptz<=now();

  select session_id into active_id
  from maths.sessions
  where user_id=uid and not completed
    and (
      lower(coalesce(mode,''))='section_sprint'
      or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
    )
  order by updated_at desc nulls last,created_at desc limit 1;
  if active_id is not null then return maths._get_session(uid,active_id); end if;

  ids:=maths._sprint_ids(uid,25);
  return maths._start_session(
    uid,ids,'section_sprint','SSC Maths Section Sprint',
    jsonb_build_object(
      'durationSec',900,'questionCount',25,'marksCorrect',2,'marksWrong',-.5,
      'selectionCapture',coalesce(p_diagnostic,false),'examMode',true,
      'freshnessPolicy','served_or_attempted','coolingHours',48
    ),false
  );
end
$$;

grant execute on function public.maths_get_active_exam_session() to authenticated;
grant execute on function public.maths_exam_runtime_checkpoint(text,integer,integer[],integer[]) to authenticated;
grant execute on function public.maths_get_sprint_review(text) to authenticated;
grant execute on function public.maths_start_sprint(boolean) to authenticated;

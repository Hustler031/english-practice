-- Maths Exam Preparation timed cursor precision.
-- Timed sessions advance only through the explicit exam runtime checkpoint.
-- Saving an answer must not move the authoritative resume cursor.

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

  if timed_ then
    -- The timed runner owns the resume cursor through maths_exam_runtime_checkpoint().
    -- Keep the exact current screen until the learner explicitly navigates.
    update maths.sessions
    set updated_at=now()
    where session_id=p_session_id and user_id=uid;
  else
    next_:=least((select count(*) from maths.session_questions where session_id=p_session_id)-1,idx+1);
    update maths.sessions
    set current_index=greatest(current_index,next_),updated_at=now()
    where session_id=p_session_id and user_id=uid;
  end if;

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

grant execute on function public.maths_submit_answer(text,text,text,numeric,text) to authenticated;

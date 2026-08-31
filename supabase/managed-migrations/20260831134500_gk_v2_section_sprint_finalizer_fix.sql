-- Harden Section Sprint finalization without touching adaptive Attempts / Exposures / QuestionState.
begin;

create or replace function public.gk_finish_section_sprint(p_session_id text,p_answers jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
 uid uuid:=auth.uid();
 item record;
 total int;
 correct_n int;
 wrong_n int;
 attempted_n int;
 result_json jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.exam_sessions where session_id=p_session_id and user_id=uid) then raise exception 'Sprint not found'; end if;

 for item in select key question_id,value answer from jsonb_each(coalesce(p_answers,'{}'::jsonb)) loop
   if exists(
     select 1
     from gk.exam_sessions s,
          jsonb_array_elements_text(s.question_ids) as ids(question_id)
     where s.session_id=p_session_id and s.user_id=uid and ids.question_id=item.question_id
   ) then
     insert into gk.exam_answers(session_id,question_id,selected_option,is_correct,response_ms)
     select p_session_id,q.question_id,upper(nullif(item.answer->>'selected','')),
            upper(nullif(item.answer->>'selected',''))=upper(coalesce(q.correct_option,'')),
            greatest(0,coalesce((item.answer->>'responseMs')::int,0))
     from gk.questions q
     where q.question_id=item.question_id and q.active
     on conflict(session_id,question_id) do nothing;
   end if;
 end loop;

 select jsonb_array_length(question_ids)
 into total
 from gk.exam_sessions
 where session_id=p_session_id and user_id=uid;

 select count(*) filter(where is_correct),count(*) filter(where is_correct is false),count(*)
 into correct_n,wrong_n,attempted_n
 from gk.exam_answers
 where session_id=p_session_id;

 result_json:=jsonb_build_object(
   'score',round((correct_n*2.0-wrong_n*0.5)::numeric,2),
   'maxScore',total*2,
   'correct',correct_n,
   'wrong',wrong_n,
   'unattempted',greatest(0,total-attempted_n),
   'accuracy',case when attempted_n=0 then 0 else round(correct_n*100.0/attempted_n,1) end,
   'averageTimeMs',coalesce((select round(avg(response_ms))::int from gk.exam_answers where session_id=p_session_id and response_ms>0),0)
 );

 update gk.exam_sessions
 set completed=true,completed_at=coalesce(completed_at,now()),result=result_json
 where session_id=p_session_id and user_id=uid;

 return jsonb_build_object('ok',true,'sessionId',p_session_id,'result',result_json,'learningHistoryChanged',false);
end;
$$;

revoke all on function public.gk_finish_section_sprint(text,jsonb) from public,anon;
grant execute on function public.gk_finish_section_sprint(text,jsonb) to authenticated;

commit;

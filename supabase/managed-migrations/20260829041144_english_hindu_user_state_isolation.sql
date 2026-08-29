create or replace function public.english_submit_hindu_answer(p_hindu_id text,p_selected_key text,p_time_seconds numeric default 0,p_attempt_id text default null)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');v_qid text;q english.questions%rowtype;v_key text:=upper(btrim(coalesce(p_selected_key,'')));v_correct boolean;v_id text;v_rows integer;v_state jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_key not in ('A','B','C','D') then raise exception 'Invalid answer'; end if;
 v_qid:=english.resolve_hindu_question_id(uid,raw);
 if v_qid is null then return jsonb_build_object('ok',false,'reason','not-linked','hindu_id',raw); end if;
 select * into q from english.questions where question_id=v_qid; if not found then return jsonb_build_object('ok',false,'reason','not-linked','hindu_id',raw); end if;
 v_correct:=(v_key='A');
 v_id:=coalesce(nullif(btrim(p_attempt_id),''),v_qid||'-HINDU-'||floor(extract(epoch from clock_timestamp())*1000)::bigint||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6));
 insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,marked_revision,topic,concept_id,module,submission_key,created_at)
 values(v_id,uid,v_qid,now(),v_key,v_correct,least(180,greatest(0,coalesce(p_time_seconds,0))),false,q.topic,q.concept_id,'hindu',v_id,now()) on conflict do nothing;
 get diagnostics v_rows=row_count;
 select english.recompute_question_state(uid,v_qid) into v_state;
 -- Hindu learning progress is user-specific and is derived from attempts/question_state.
 -- Never mutate the shared english.hindu_words content row with one user's practice state.
 return jsonb_build_object('ok',true,'deduped',(v_rows=0),'correct',v_correct,'correctKey','A','questionId',v_qid,'attemptId',v_id,'state',v_state);
end $$;

revoke execute on function public.english_submit_hindu_answer(text,text,numeric,text) from public,anon;
grant execute on function public.english_submit_hindu_answer(text,text,numeric,text) to authenticated,service_role;

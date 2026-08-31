-- Promote a diagnosed GPT Sprint gap using option keys, never array position.

create or replace function english.sprint_option_text(p_options jsonb,p_key text)
returns text language sql immutable as $$
select coalesce((select x->>'text' from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) x where upper(coalesce(x->>'key',''))=upper(coalesce(p_key,'')) limit 1),'');
$$;

create or replace function public.english_save_sprint_analysis(p_session_id uuid,p_analysis jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); x jsonb; pos integer; diag text; act text; confused text; i english.sprint_items%rowtype; qid text; n_targeted integer:=0; oa text; ob text; oc text; od text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid and s.status='completed') then raise exception 'Completed Sprint not found'; end if;
 if jsonb_typeof(coalesce(p_analysis,'[]'::jsonb))<>'array' then raise exception 'Analysis must be an array'; end if;
 for x in select value from jsonb_array_elements(p_analysis) value loop
   pos:=coalesce((x->>'position')::int,0);diag:=coalesce(x->>'diagnosis','');act:=coalesce(x->>'action','No Route Change');confused:=nullif(btrim(coalesce(x->>'confusedWith','')),'');
   if diag not in ('Knowledge Gap','Confusion','Rule Gap','Careless','Time Pressure','Misread','Distractor Trap') then raise exception 'Invalid diagnosis at %',pos; end if;
   if act not in ('Targeted Mastery','Weakness Drill','Trap Practice','Execution Review','No Route Change') then raise exception 'Invalid action at %',pos; end if;
   select * into i from english.sprint_items where session_id=p_session_id and position=pos; if not found then raise exception 'Sprint item not found'; end if;
   update english.sprint_answers set diagnosis=diag,action=act,confused_with=confused where session_id=p_session_id and position=pos and user_id=uid;
   if act='Targeted Mastery' and diag in ('Knowledge Gap','Confusion','Rule Gap','Distractor Trap') then
     qid:=i.canonical_question_id;
     if qid is null then
       qid:='GPTSSC_'||replace(substr(p_session_id::text,1,8),'-','')||'_'||lpad(pos::text,2,'0');
       if not exists(select 1 from english.questions q where q.question_id=qid) then
         oa:=english.sprint_option_text(i.options,'A');ob:=english.sprint_option_text(i.options,'B');oc:=english.sprint_option_text(i.options,'C');od:=english.sprint_option_text(i.options,'D');
         if oa='' or ob='' or oc='' or od='' then raise exception 'Sprint option mapping incomplete at %',pos; end if;
         insert into english.questions(question_id,topic,question,option_a,option_b,option_c,option_d,correct,explanation,question_type,source_file,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,active,created_at,updated_at)
         values(qid,i.category,i.question,oa,ob,oc,od,i.correct_key,i.explanation,i.question_type,'GPT SSC Sprint',coalesce(i.metadata->>'conceptKey',qid),'Targeted','GPT Sprint','New','Active','SSC CGL Targeted Follow-up',true,now(),now());
       end if;
       update english.sprint_items set canonical_question_id=qid where session_id=p_session_id and position=pos;
     end if;
     perform english.route_to_targeted(uid,qid,'Sprint',diag||' detected under SSC Sprint'); n_targeted:=n_targeted+1;
   end if;
 end loop;
 update english.sprint_sessions set analysis=jsonb_build_object('diagnosedAt',now(),'items',p_analysis,'targetedAdded',n_targeted) where session_id=p_session_id and user_id=uid;
 return jsonb_build_object('ok',true,'targetedAdded',n_targeted,'analysis',p_analysis);
end $$;

grant execute on function public.english_save_sprint_analysis(uuid,jsonb) to authenticated,service_role;

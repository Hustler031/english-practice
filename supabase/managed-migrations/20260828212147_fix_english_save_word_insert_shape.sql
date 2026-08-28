create or replace function public.english_save_word(p_word text,p_context text default '',p_question_id text default '',p_module text default '',p_source text default '',p_capture_type text default 'AUTO')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); v_word text:=btrim(coalesce(p_word,'')); v_capture text:=upper(btrim(coalesce(p_capture_type,'AUTO'))); s english.saved_items%rowtype; v_id text; v_resolved text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_word='' then raise exception 'Enter a word first.'; end if;
 if v_capture not in ('AUTO','V','SM','OWS','PV','IP') then raise exception 'Invalid capture type'; end if;
 select * into s from english.saved_items where user_id=uid and active and lower(btrim(coalesce(word,'')))=lower(v_word) order by created_at desc nulls last limit 1;
 if found then
  update english.saved_items set context=case when btrim(coalesce(p_context,''))<>'' then btrim(p_context) else context end,origin_question_id=case when btrim(coalesce(p_question_id,''))<>'' then btrim(p_question_id) else origin_question_id end,origin_module=case when btrim(coalesce(p_module,''))<>'' then btrim(p_module) else origin_module end,source=case when btrim(coalesce(p_source,''))<>'' then btrim(p_source) else source end,updated_at=now(),gpt_status=case when coalesce(btrim(gpt_status),'')='' and coalesce(btrim(practice_question_id),'')='' then 'Pending GPT' else gpt_status end where saved_id=s.saved_id returning * into s;
  v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,s.saved_id,v_capture,v_resolved,now()) on conflict(user_id,saved_id) do update set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;
  return jsonb_build_object('ok',true,'id',s.saved_id,'duplicate',true,'status',coalesce(s.status,'Saved'),'gpt_status',coalesce(s.gpt_status,'Pending GPT'),'capture_type',v_capture,'resolved_type',v_resolved);
 end if;
 v_id:='MW_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD_HH24MISS')||'_'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));
 insert into english.saved_items(saved_id,user_id,word,meaning,context,origin_question_id,origin_module,source,created_at,updated_at,status,practice_question_id,active,part_of_speech,synonyms,antonyms,example,explanation,question,option_a,option_b,option_c,option_d,correct_option,gpt_status,gpt_updated_at,gpt_source)
 values(v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),nullif(btrim(coalesce(p_question_id,'')),''),nullif(btrim(coalesce(p_module,'')),''),nullif(btrim(coalesce(p_source,'')),''),now(),now(),'Saved',null,true,'','','','','','','','','','','','Pending GPT',null,'') returning * into s;
 v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
 insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,v_id,v_capture,v_resolved,now());
 return jsonb_build_object('ok',true,'id',v_id,'duplicate',false,'status','Saved','gpt_status','Pending GPT','capture_type',v_capture,'resolved_type',v_resolved);
end; $$;
revoke all on function public.english_save_word(text,text,text,text,text,text) from public;
grant execute on function public.english_save_word(text,text,text,text,text,text) to authenticated;

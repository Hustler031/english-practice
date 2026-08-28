create or replace function english.resolve_saved_type(p_capture_type text,p_word text,p_meaning text,p_context text,p_part_of_speech text,p_question text,p_explanation text)
returns text language sql immutable as $$
with x as (select upper(btrim(coalesce(p_capture_type,'AUTO'))) capture,lower(coalesce(p_part_of_speech,'')) pos,lower(concat_ws(' ',p_word,p_context,p_meaning,p_question,p_explanation)) txt)
select case
 when capture in ('V','SM','OWS','PV','IP','CU') then capture
 when pos ~ '(concept\s*/\s*usage|grammar\s*[-/]?\s*usage|(^|\W)cu(\W|$))' or txt ~ '(uncountable|countable|grammar|usage|confusable|confusion|figurative|metaphor|tone|passage|belief\s+vs\s+believe|\bvs\b.*\busage)' then 'CU'
 when pos ~ 'phrasal\s+verb' or txt ~ '^brush\s+aside\b' then 'PV'
 when pos ~ '(idiom|phrase)' then 'IP'
 when pos ~ '(one[- ]word\s+substitution|\bows\b)' then 'OWS'
 when pos ~ '(spelling|misspell)' then 'SM'
 else 'V' end from x; $$;

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
 values(v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),nullif(btrim(coalesce(p_question_id,'')),''),nullif(btrim(coalesce(p_module,'')),''),nullif(btrim(coalesce(p_source,'')),''),now(),now(),'Saved',null,true,'','','','','','','','','','','Pending GPT',null,'') returning * into s;
 v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
 insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,v_id,v_capture,v_resolved,now());
 return jsonb_build_object('ok',true,'id',v_id,'duplicate',false,'status','Saved','gpt_status','Pending GPT','capture_type',v_capture,'resolved_type',v_resolved);
end; $$;

create or replace function public.english_set_saved_item_type(p_saved_id text,p_capture_type text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); s english.saved_items%rowtype; v_capture text:=upper(btrim(coalesce(p_capture_type,''))); v_resolved text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_capture not in ('AUTO','V','SM','OWS','PV','IP') then raise exception 'Invalid capture type'; end if;
 select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid; if not found then raise exception 'Saved item not found'; end if;
 v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
 insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,s.saved_id,v_capture,v_resolved,now()) on conflict(user_id,saved_id) do update set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;
 return jsonb_build_object('ok',true,'id',s.saved_id,'capture_type',v_capture,'resolved_type',v_resolved);
end; $$;

create or replace function public.english_update_saved_item(p_saved_id text,p_word text default null,p_meaning text default null,p_context text default null,p_part_of_speech text default null,p_synonyms text default null,p_antonyms text default null,p_example text default null,p_explanation text default null,p_question text default null,p_option_a text default null,p_option_b text default null,p_option_c text default null,p_option_d text default null,p_correct_option text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); s english.saved_items%rowtype; t english.saved_item_types%rowtype; v_resolved text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid; if not found then raise exception 'Saved item not found'; end if;
 if p_word is not null and btrim(p_word)='' then raise exception 'Word cannot be blank'; end if;
 update english.saved_items set word=case when p_word is null then word else btrim(p_word) end,meaning=case when p_meaning is null then meaning else btrim(p_meaning) end,context=case when p_context is null then context else btrim(p_context) end,part_of_speech=case when p_part_of_speech is null then part_of_speech else btrim(p_part_of_speech) end,synonyms=case when p_synonyms is null then synonyms else btrim(p_synonyms) end,antonyms=case when p_antonyms is null then antonyms else btrim(p_antonyms) end,example=case when p_example is null then example else btrim(p_example) end,explanation=case when p_explanation is null then explanation else btrim(p_explanation) end,question=case when p_question is null then question else btrim(p_question) end,option_a=case when p_option_a is null then option_a else btrim(p_option_a) end,option_b=case when p_option_b is null then option_b else btrim(p_option_b) end,option_c=case when p_option_c is null then option_c else btrim(p_option_c) end,option_d=case when p_option_d is null then option_d else btrim(p_option_d) end,correct_option=case when p_correct_option is null then correct_option else upper(btrim(p_correct_option)) end,updated_at=now() where saved_id=s.saved_id returning * into s;
 select * into t from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
 v_resolved:=english.resolve_saved_type(coalesce(t.capture_type,'AUTO'),s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
 insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,s.saved_id,coalesce(t.capture_type,'AUTO'),v_resolved,now()) on conflict(user_id,saved_id) do update set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;
 return jsonb_build_object('ok',true,'id',s.saved_id,'resolved_type',v_resolved);
end; $$;

revoke all on function public.english_save_word(text,text,text,text,text,text) from public;
revoke all on function public.english_set_saved_item_type(text,text) from public;
revoke all on function public.english_update_saved_item(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text) from public;
grant execute on function public.english_save_word(text,text,text,text,text,text) to authenticated;
grant execute on function public.english_set_saved_item_type(text,text) to authenticated;
grant execute on function public.english_update_saved_item(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text) to authenticated;

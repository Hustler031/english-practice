create or replace function public.english_set_saved_enrichment(p_saved_id text,p_meaning text,p_part_of_speech text,p_synonyms text,p_antonyms text,p_example text,p_explanation text,p_question text,p_option_a text,p_option_b text,p_option_c text,p_option_d text,p_correct_option text,p_source text default '',p_gpt_status text default 'Ready')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); s english.saved_items%rowtype; t english.saved_item_types%rowtype; v_resolved text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid; if not found then raise exception 'Saved item not found'; end if;
 update english.saved_items set meaning=coalesce(p_meaning,''),part_of_speech=coalesce(p_part_of_speech,''),synonyms=coalesce(p_synonyms,''),antonyms=coalesce(p_antonyms,''),example=coalesce(p_example,''),explanation=coalesce(p_explanation,''),question=coalesce(p_question,''),option_a=coalesce(p_option_a,''),option_b=coalesce(p_option_b,''),option_c=coalesce(p_option_c,''),option_d=coalesce(p_option_d,''),correct_option=upper(coalesce(p_correct_option,'')),gpt_source=coalesce(p_source,''),gpt_status=coalesce(nullif(btrim(p_gpt_status),''),'Ready'),gpt_updated_at=now(),updated_at=now() where saved_id=s.saved_id returning * into s;
 select * into t from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
 v_resolved:=english.resolve_saved_type(coalesce(t.capture_type,'AUTO'),s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
 insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,s.saved_id,coalesce(t.capture_type,'AUTO'),v_resolved,now()) on conflict(user_id,saved_id) do update set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;
 return jsonb_build_object('ok',true,'id',s.saved_id,'status',s.gpt_status,'resolved_type',v_resolved);
end; $$;

create or replace function public.english_promote_saved_item(p_saved_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); s english.saved_items%rowtype; t english.saved_item_types%rowtype; v_type text; v_topic text; v_qtype text; v_cat text; v_qid text; v_existing text; v_a text;v_b text;v_c text;v_d text;v_correct text; v_question text; v_expl text; v_digest text; distractors text[];
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid and active; if not found then raise exception 'Saved item not found'; end if;
 if lower(coalesce(s.gpt_status,''))<>'ready' then raise exception 'GPT review is not ready yet'; end if;
 if btrim(coalesce(s.word,''))='' then raise exception 'Word cannot be blank'; end if;
 if btrim(coalesce(s.meaning,''))='' then raise exception 'Prepared meaning is missing'; end if;
 select * into t from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
 v_type:=english.resolve_saved_type(coalesce(t.capture_type,'AUTO'),s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
 v_topic:=case v_type when 'SM' then 'Spelling Mistakes' when 'OWS' then 'One Word Substitution' when 'PV' then 'Phrasal Verbs' when 'IP' then 'Idioms & Phrases' when 'CU' then 'Grammar / Usage' else 'Vocabulary' end;
 v_qtype:=case v_type when 'SM' then 'Spelling' when 'OWS' then 'One Word Substitution' when 'CU' then 'Concept / Usage' else 'Meaning' end;
 v_cat:=english.canonical_category(v_topic);
 select q.question_id into v_existing from english.questions q where q.active and english.canonical_category(q.topic)=v_cat and lower(btrim(coalesce(q.word,'')))=lower(btrim(s.word)) order by q.created_at limit 1;
 if v_existing is not null then update english.saved_items set status='Added',practice_question_id=v_existing,updated_at=now() where saved_id=s.saved_id; return jsonb_build_object('ok',true,'question_id',v_existing,'linked',true,'resolved_type',v_type); end if;
 v_a:=nullif(btrim(coalesce(s.option_a,'')),'');v_b:=nullif(btrim(coalesce(s.option_b,'')),'');v_c:=nullif(btrim(coalesce(s.option_c,'')),'');v_d:=nullif(btrim(coalesce(s.option_d,'')),'');v_correct:=upper(btrim(coalesce(s.correct_option,'')));
 if v_correct not in ('A','B','C','D') or v_a is null or v_b is null or v_c is null or v_d is null then
  select array_agg(x order by random()) into distractors from (select distinct case upper(q.correct) when 'A' then q.option_a when 'B' then q.option_b when 'C' then q.option_c when 'D' then q.option_d end x from english.questions q where english.canonical_category(q.topic)='VOC') z where nullif(btrim(coalesce(x,'')),'') is not null and lower(btrim(x))<>lower(btrim(s.meaning));
  v_a:=s.meaning;v_b:=coalesce(distractors[1],'A related but incorrect meaning');v_c:=coalesce(distractors[2],'An opposite idea');v_d:=coalesce(distractors[3],'A different usage');v_correct:='A';
 end if;
 v_digest:=upper(substr(md5(lower(btrim(s.word))),1,10));v_qid:='MYWORD_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD')||'_'||v_digest;
 v_question:=coalesce(nullif(btrim(s.question),''),'Choose the closest meaning of '||s.word||'.');
 v_expl:=coalesce(nullif(btrim(s.explanation),''),concat_ws(E'\n',s.meaning,case when nullif(btrim(s.part_of_speech),'') is not null then 'Part of speech: '||s.part_of_speech end,case when nullif(btrim(s.synonyms),'') is not null then 'Synonyms: '||s.synonyms end,case when nullif(btrim(s.antonyms),'') is not null then 'Antonyms: '||s.antonyms end,case when nullif(btrim(s.example),'') is not null then 'Example: '||s.example end,case when nullif(btrim(s.context),'') is not null then 'Context: '||s.context end));
 insert into english.questions(question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,seen_count,exam_relevance,tip,usage_note,active,created_at,updated_at)
 values(v_qid,v_topic,s.word,v_question,v_a,v_b,v_c,v_d,v_correct,v_expl,'My Saved Words',v_qtype,'My Saved Words','','MYWORD_'||v_digest,'Medium','MY_SAVED_WORDS','New','Active',0,'User-saved '||v_type,case when nullif(btrim(s.synonyms),'') is not null then 'Recall with: '||s.synonyms else 'Captured during practice for deliberate revision.' end,coalesce(nullif(s.example,''),s.context),true,now(),now()) on conflict(question_id) do nothing;
 update english.saved_items set status='Added',practice_question_id=v_qid,updated_at=now() where saved_id=s.saved_id;
 insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,s.saved_id,coalesce(t.capture_type,'AUTO'),v_type,now()) on conflict(user_id,saved_id) do update set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;
 return jsonb_build_object('ok',true,'question_id',v_qid,'linked',false,'resolved_type',v_type);
end; $$;

revoke all on function public.english_set_saved_enrichment(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text) from public;
revoke all on function public.english_promote_saved_item(text) from public;
grant execute on function public.english_set_saved_enrichment(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.english_promote_saved_item(text) to authenticated;

create or replace function english.resolve_hindu_question_id(p_user_id uuid,p_hindu_id text)
returns text language plpgsql stable security definer set search_path=pg_catalog,english,auth as $$
declare raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');v_qid text;h english.hindu_words%rowtype;v_date text;
begin
 if raw='' then return null; end if;
 select r.question_id into v_qid from english.hindu_vocab_registry r join english.questions q on q.question_id=r.question_id where r.user_id=p_user_id and r.hindu_id=raw and r.active limit 1;
 if v_qid is not null then return v_qid; end if;
 select * into h from english.hindu_words where hindu_id=raw; if not found then return null; end if;
 v_date:=to_char(h.word_date,'YYYYMMDD');
 select q.question_id into v_qid from english.questions q where q.active and lower(btrim(coalesce(q.word,'')))=lower(btrim(h.word)) and (q.question_id like 'HV'||v_date||'%' or coalesce(q.source_id,'') like '%'||v_date||'%') order by q.question_id limit 1;
 return v_qid;
end; $$;

create or replace function public.english_get_hindu_today()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
 'id',h.hindu_id,'date',h.word_date,'word',h.word,'pos',coalesce(h.part_of_speech,''),'meaning',coalesce(h.meaning,''),'synonyms',coalesce(h.synonyms,''),'antonyms',coalesce(h.antonyms,''),'example',coalesce(h.example_sentence,''),'family',coalesce(h.word_family,''),'usage',coalesce(h.usage_note,''),'tip',coalesce(h.tip,''),'memory',coalesce(h.memory_aid,''),'article',coalesce(h.article_title,''),'sourceUrl',coalesce(h.source_url,''),'sourceName',coalesce(h.source_name,''),'centralQuestionId',english.resolve_hindu_question_id(auth.uid(),h.hindu_id),'marked',coalesce(r.marked,false),'inVocab',coalesce(r.in_vocab,false)
) order by h.hindu_id),'[]'::jsonb) end
from english.hindu_words h left join english.hindu_vocab_registry r on r.user_id=auth.uid() and r.hindu_id=h.hindu_id
where h.active and h.word_date=(now() at time zone 'Asia/Kolkata')::date; $$;

create or replace function public.english_get_hindu_quiz()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();v_today date:=(now() at time zone 'Asia/Kolkata')::date;out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id','HINDU_'||h.hindu_id,'hinduId',h.hindu_id,'centralQuestionId',english.resolve_hindu_question_id(uid,h.hindu_id),'category','HINDU_VOCAB','topic','The Hindu Vocabulary','word',h.word,'question','What is the closest meaning of '||h.word||'?','options',jsonb_build_array(jsonb_build_object('key','A','text',coalesce(h.meaning,'')),jsonb_build_object('key','B','text',coalesce(d.arr[1],'None of these meanings')),jsonb_build_object('key','C','text',coalesce(d.arr[2],'A different meaning')),jsonb_build_object('key','D','text',coalesce(d.arr[3],'Another usage'))),'correctKey','A','explanation',coalesce(h.meaning,''),'example',coalesce(h.example_sentence,''),'usageNote',coalesce(h.usage_note,''),'tip',coalesce(h.tip,''),'memoryAid',coalesce(h.memory_aid,''),'related',case when nullif(btrim(coalesce(h.synonyms,'')),'') is not null then 'Synonyms: '||h.synonyms else '' end,'source',coalesce(h.source_name,'The Hindu'),'sourcePage','', 'marked',coalesce(r.marked,false),'inVocab',coalesce(r.in_vocab,false)
 ) order by h.hindu_id),'[]'::jsonb) into out
 from english.hindu_words h
 left join english.hindu_vocab_registry r on r.user_id=uid and r.hindu_id=h.hindu_id
 left join lateral (select array_agg(z.meaning order by random()) arr from (select distinct h2.meaning from english.hindu_words h2 where h2.active and h2.word_date=v_today and h2.hindu_id<>h.hindu_id and nullif(btrim(coalesce(h2.meaning,'')),'') is not null and lower(btrim(h2.meaning))<>lower(btrim(coalesce(h.meaning,''))) limit 10) z) d on true
 where h.active and h.word_date=v_today and nullif(btrim(coalesce(h.word,'')),'') is not null and nullif(btrim(coalesce(h.meaning,'')),'') is not null;
 return out;
end; $$;

create or replace function public.english_submit_hindu_answer(p_hindu_id text,p_selected_key text,p_time_seconds numeric default 0,p_attempt_id text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
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
 if v_rows>0 then update english.hindu_words set learning_status='Completed',first_practiced=coalesce(first_practiced,now()),last_practiced=now() where hindu_id=raw; end if;
 return jsonb_build_object('ok',true,'deduped',(v_rows=0),'correct',v_correct,'correctKey','A','questionId',v_qid,'attemptId',v_id,'state',v_state);
end; $$;

create or replace function public.english_hindu_progress()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with words as (select h.hindu_id,english.resolve_hindu_question_id(auth.uid(),h.hindu_id) qid from english.hindu_words h where auth.uid() is not null and h.active and h.word_date=(now() at time zone 'Asia/Kolkata')::date), counts as (select w.hindu_id,w.qid,case when w.qid is null then 0 else (select count(*) from english.attempts a where a.user_id=auth.uid() and a.question_id=w.qid and lower(coalesce(a.module,''))='hindu') end n from words w)
select jsonb_build_object('total',(select count(*) from words),'completed',(select count(*) from counts where n>0),'roundsCompleted',coalesce((select min(n) from counts),0),'nextRound',coalesce((select min(n) from counts),0)+1); $$;

create or replace function public.english_set_hindu_marked(p_hindu_id text,p_marked boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');h english.hindu_words%rowtype;v_qid text;v_current boolean;v_state jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into h from english.hindu_words where hindu_id=raw; if not found then raise exception 'Hindu word not found'; end if;
 v_qid:=english.resolve_hindu_question_id(uid,raw);
 insert into english.hindu_vocab_registry(user_id,hindu_id,question_id,marked,in_vocab,active,updated_at) values(uid,raw,v_qid,coalesce(p_marked,false),false,true,now()) on conflict(user_id,hindu_id) do update set marked=excluded.marked,question_id=coalesce(english.hindu_vocab_registry.question_id,excluded.question_id),active=true,updated_at=now();
 if v_qid is not null then
  select (action='STAR') into v_current from english.star_events where user_id=uid and question_id=v_qid order by event_at desc,id desc limit 1;
  if not found or v_current is distinct from coalesce(p_marked,false) then insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action) values(uid,v_qid,now(),(now() at time zone 'Asia/Kolkata')::date,null,case when p_marked then 'STAR' else 'UNSTAR' end); end if;
  select english.recompute_question_state(uid,v_qid) into v_state;
 end if;
 return jsonb_build_object('ok',true,'hinduId',raw,'questionId',v_qid,'marked',coalesce(p_marked,false),'state',v_state);
end; $$;

create or replace function public.english_add_hindu_to_vocab(p_hindu_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();raw text:=regexp_replace(btrim(coalesce(p_hindu_id,'')),'^HINDU_','','i');h english.hindu_words%rowtype;v_qid text;v_saved jsonb;v_sid text;v_enrich jsonb;v_promote jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into h from english.hindu_words where hindu_id=raw and active; if not found then raise exception 'Hindu word not found'; end if;
 v_qid:=english.resolve_hindu_question_id(uid,raw);
 insert into english.hindu_vocab_registry(user_id,hindu_id,question_id,added_date,marked,in_vocab,active,updated_at) values(uid,raw,v_qid,(now() at time zone 'Asia/Kolkata')::date,false,true,true,now()) on conflict(user_id,hindu_id) do update set question_id=coalesce(english.hindu_vocab_registry.question_id,excluded.question_id),added_date=coalesce(english.hindu_vocab_registry.added_date,excluded.added_date),in_vocab=true,active=true,updated_at=now();
 v_saved:=public.english_save_word(h.word,coalesce(nullif(h.usage_note,''),h.example_sentence,''),coalesce(v_qid,''),'The Hindu','The Hindu','AUTO');
 v_sid:=v_saved->>'id';
 v_enrich:=public.english_set_saved_enrichment(v_sid,coalesce(h.meaning,''),coalesce(h.part_of_speech,''),coalesce(h.synonyms,''),coalesce(h.antonyms,''),coalesce(h.example_sentence,''),concat_ws(E'\n',nullif(h.meaning,''),nullif(h.usage_note,''),nullif(h.tip,'')),'','','','','','','The Hindu','Ready');
 begin v_promote:=public.english_promote_saved_item(v_sid); exception when others then v_promote:=jsonb_build_object('ok',false,'error',sqlerrm); end;
 return jsonb_build_object('ok',true,'hinduId',raw,'questionId',v_qid,'saved',v_saved,'enrichment',v_enrich,'promoted',v_promote);
end; $$;

revoke all on function public.english_get_hindu_today() from public;
revoke all on function public.english_get_hindu_quiz() from public;
revoke all on function public.english_submit_hindu_answer(text,text,numeric,text) from public;
revoke all on function public.english_hindu_progress() from public;
revoke all on function public.english_set_hindu_marked(text,boolean) from public;
revoke all on function public.english_add_hindu_to_vocab(text) from public;
grant execute on function public.english_get_hindu_today() to authenticated;
grant execute on function public.english_get_hindu_quiz() to authenticated;
grant execute on function public.english_submit_hindu_answer(text,text,numeric,text) to authenticated;
grant execute on function public.english_hindu_progress() to authenticated;
grant execute on function public.english_set_hindu_marked(text,boolean) to authenticated;
grant execute on function public.english_add_hindu_to_vocab(text) to authenticated;

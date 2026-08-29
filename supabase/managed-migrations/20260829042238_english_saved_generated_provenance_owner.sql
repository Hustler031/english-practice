alter table english.question_origins add column if not exists owner_user_id uuid references auth.users(id) on delete cascade;

with owners as (
  select o.question_id,(array_agg(distinct si.user_id))[1] owner_user_id
  from english.question_origins o
  join english.saved_items si on si.practice_question_id=o.question_id
  where o.origin_kind='saved_generated'
  group by o.question_id
  having count(distinct si.user_id)=1
)
update english.question_origins o
set owner_user_id=x.owner_user_id
from owners x
where o.question_id=x.question_id and o.origin_kind='saved_generated' and o.owner_user_id is null;

create index if not exists english_question_origins_owner_idx on english.question_origins(owner_user_id,origin_kind,question_id);

do $$ begin
  if not exists(select 1 from pg_constraint where conname='english_question_origins_saved_owner_ck') then
    alter table english.question_origins add constraint english_question_origins_saved_owner_ck
      check(origin_kind<>'saved_generated' or owner_user_id is not null) not valid;
    alter table english.question_origins validate constraint english_question_origins_saved_owner_ck;
  end if;
end $$;

create or replace function english.question_visible_to_user(p_user_id uuid,p_question_id text)
returns boolean language sql stable security definer
set search_path=pg_catalog,english,auth as $$
select case
  when p_user_id is null then false
  when o.question_id is null then true
  when o.origin_kind='saved_generated' then o.owner_user_id=p_user_id
  else true
end
from (select 1) x
left join english.question_origins o on o.question_id=p_question_id;
$$;

drop policy if exists english_questions_authenticated_read on english.questions;
create policy english_questions_authenticated_read on english.questions for select to authenticated
using (english.question_visible_to_user(auth.uid(),question_id));

drop policy if exists english_question_origins_authenticated_read on english.question_origins;
create policy english_question_origins_authenticated_read on english.question_origins for select to authenticated
using (origin_kind<>'saved_generated' or owner_user_id=auth.uid());

create or replace function english.question_payload(p_user_id uuid,p_question_id text)
returns jsonb language sql stable security definer
set search_path=pg_catalog,english,auth as $$
select jsonb_build_object(
 'id',q.question_id,'category',english.canonical_category(q.topic),'topic',coalesce(q.topic,''),'subtopic',coalesce(q.subtopic,''),'word',coalesce(q.word,''),'question',q.question,
 'options',jsonb_build_array(jsonb_build_object('key','A','text',coalesce(q.option_a,'')),jsonb_build_object('key','B','text',coalesce(q.option_b,'')),jsonb_build_object('key','C','text',coalesce(q.option_c,'')),jsonb_build_object('key','D','text',coalesce(q.option_d,''))),
 'correctKey',upper(coalesce(q.correct,'')),'explanation',coalesce(q.explanation,''),'tip',coalesce(q.tip,''),'usageNote',coalesce(q.usage_note,''),'example',coalesce(q.example_sentence,''),'memoryAid',coalesce(q.memory_aid,''),'related',coalesce(q.related_words,''),'source',coalesce(q.source_file,q.source_id,''),'sourcePage',coalesce(q.source_page,''),'sourceUrl',coalesce(q.source_url,''),'questionType',coalesce(q.question_type,''),'conceptId',coalesce(q.concept_id,''),'difficulty',coalesce(q.difficulty,''),
 'attempts',coalesce(s.attempts,0),'wrong',coalesce(s.wrong,0),'status',coalesce(s.status,'New'),'nextReview',s.next_review,'starred',coalesce(s.last_marked,false),'difficult',coalesce(d.difficult,false),'mastered',coalesce(s.mastered,false),'added',english.recent_content_date(q)
)
from english.questions q
left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
where q.question_id=p_question_id and english.question_visible_to_user(p_user_id,q.question_id);
$$;

create or replace function public.english_promote_saved_item(p_saved_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();s english.saved_items%rowtype;t english.saved_item_types%rowtype;v_type text;v_topic text;v_qtype text;v_cat text;v_qid text;v_existing text;v_a text;v_b text;v_c text;v_d text;v_correct text;v_question text;v_expl text;v_digest text;distractors text[];
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid and active;if not found then raise exception 'Saved item not found';end if;
 if lower(coalesce(s.gpt_status,''))<>'ready' then raise exception 'GPT review is not ready yet';end if;if btrim(coalesce(s.word,''))='' then raise exception 'Word cannot be blank';end if;if btrim(coalesce(s.meaning,''))='' then raise exception 'Prepared meaning is missing';end if;
 select * into t from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
 v_type:=english.resolve_saved_type(coalesce(t.capture_type,'AUTO'),s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);v_topic:=case v_type when 'SM' then 'Spelling Mistakes' when 'OWS' then 'One Word Substitution' when 'PV' then 'Phrasal Verbs' when 'IP' then 'Idioms & Phrases' when 'CU' then 'Grammar / Usage' else 'Vocabulary' end;v_qtype:=case v_type when 'SM' then 'Spelling' when 'OWS' then 'One Word Substitution' when 'CU' then 'Concept / Usage' else 'Meaning' end;v_cat:=english.canonical_category(v_topic);
 select q.question_id into v_existing from english.questions q left join english.question_origins o on o.question_id=q.question_id where q.active and english.canonical_category(q.topic)=v_cat and lower(btrim(coalesce(q.word,'')))=lower(btrim(s.word)) and (coalesce(o.origin_kind,'core')<>'saved_generated' or o.owner_user_id=uid) order by case when coalesce(o.origin_kind,'core')='core' then 0 when o.owner_user_id=uid then 1 else 2 end,q.created_at limit 1;
 if v_existing is not null then update english.saved_items set status='Added',practice_question_id=v_existing,updated_at=now() where saved_id=s.saved_id;return jsonb_build_object('ok',true,'question_id',v_existing,'linked',true,'resolved_type',v_type);end if;
 v_a:=nullif(btrim(coalesce(s.option_a,'')),'');v_b:=nullif(btrim(coalesce(s.option_b,'')),'');v_c:=nullif(btrim(coalesce(s.option_c,'')),'');v_d:=nullif(btrim(coalesce(s.option_d,'')),'');v_correct:=upper(btrim(coalesce(s.correct_option,'')));
 if v_correct not in('A','B','C','D') or v_a is null or v_b is null or v_c is null or v_d is null then select array_agg(x order by random()) into distractors from(select distinct case upper(q.correct) when 'A' then q.option_a when 'B' then q.option_b when 'C' then q.option_c when 'D' then q.option_d end x from english.questions q where english.canonical_category(q.topic)='VOC' and english.question_visible_to_user(uid,q.question_id))z where nullif(btrim(coalesce(x,'')),'') is not null and lower(btrim(x))<>lower(btrim(s.meaning));v_a:=s.meaning;v_b:=coalesce(distractors[1],'A related but incorrect meaning');v_c:=coalesce(distractors[2],'An opposite idea');v_d:=coalesce(distractors[3],'A different usage');v_correct:='A';end if;
 v_digest:=upper(substr(md5(uid::text||'|'||lower(btrim(s.word))),1,10));v_qid:='MYWORD_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD')||'_'||v_digest;v_question:=coalesce(nullif(btrim(s.question),''),'Choose the closest meaning of '||s.word||'.');v_expl:=coalesce(nullif(btrim(s.explanation),''),concat_ws(E'\n',s.meaning,case when nullif(btrim(s.part_of_speech),'') is not null then 'Part of speech: '||s.part_of_speech end,case when nullif(btrim(s.synonyms),'') is not null then 'Synonyms: '||s.synonyms end,case when nullif(btrim(s.antonyms),'') is not null then 'Antonyms: '||s.antonyms end,case when nullif(btrim(s.example),'') is not null then 'Example: '||s.example end,case when nullif(btrim(s.context),'') is not null then 'Context: '||s.context end));
 insert into english.questions(question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,seen_count,exam_relevance,tip,usage_note,active,created_at,updated_at) values(v_qid,v_topic,s.word,v_question,v_a,v_b,v_c,v_d,v_correct,v_expl,'My Saved Words',v_qtype,'My Saved Words','','MYWORD_'||v_digest,'Medium','MY_SAVED_WORDS','New','Active',0,'User-saved '||v_type,case when nullif(btrim(s.synonyms),'') is not null then 'Recall with: '||s.synonyms else 'Captured during practice for deliberate revision.' end,coalesce(nullif(s.example,''),s.context),true,now(),now()) on conflict(question_id) do nothing;
 insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id,created_at) values(v_qid,'saved_generated',s.saved_id,uid,now()) on conflict(question_id) do update set origin_kind='saved_generated',origin_ref=excluded.origin_ref,owner_user_id=excluded.owner_user_id where english.question_origins.owner_user_id is null or english.question_origins.owner_user_id=uid;
 update english.saved_items set status='Added',practice_question_id=v_qid,updated_at=now() where saved_id=s.saved_id;insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at) values(uid,s.saved_id,coalesce(t.capture_type,'AUTO'),v_type,now()) on conflict(user_id,saved_id) do update set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;return jsonb_build_object('ok',true,'question_id',v_qid,'linked',false,'resolved_type',v_type);
end $$;

revoke execute on function public.english_promote_saved_item(text) from public,anon;
grant execute on function public.english_promote_saved_item(text) to authenticated,service_role;
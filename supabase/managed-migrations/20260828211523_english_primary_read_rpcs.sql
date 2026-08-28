create or replace function public.english_get_saved_items()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
 'id',s.saved_id,'word',coalesce(s.word,''),'meaning',coalesce(s.meaning,''),'context',coalesce(s.context,''),'questionId',coalesce(s.origin_question_id,''),'module',coalesce(s.origin_module,''),'source',coalesce(s.source,''),'status',coalesce(s.status,'Saved'),'practiceQuestionId',coalesce(s.practice_question_id,''),'created',s.created_at,'updated',s.updated_at,'partOfSpeech',coalesce(s.part_of_speech,''),'synonyms',coalesce(s.synonyms,''),'antonyms',coalesce(s.antonyms,''),'example',coalesce(s.example,''),'explanation',coalesce(s.explanation,''),'question',coalesce(s.question,''),'optionA',coalesce(s.option_a,''),'optionB',coalesce(s.option_b,''),'optionC',coalesce(s.option_c,''),'optionD',coalesce(s.option_d,''),'correctOption',coalesce(s.correct_option,''),'gptStatus',coalesce(s.gpt_status,'Pending GPT'),'gptUpdated',s.gpt_updated_at,'gptSource',coalesce(s.gpt_source,''),'captureType',coalesce(t.capture_type,'AUTO'),'resolvedType',coalesce(t.resolved_type,english.resolve_saved_type('AUTO',s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation))
) order by s.created_at desc nulls last),'[]'::jsonb) end
from english.saved_items s left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
where s.user_id=auth.uid() and s.active; $$;

create or replace function public.english_get_starred_items(p_mode text default 'all',p_count integer default 100)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); v_mode text:=lower(btrim(coalesce(p_mode,'all'))); v_n integer:=greatest(1,least(1000,coalesce(p_count,100))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(english.question_payload(uid,x.question_id) order by x.ord),'[]'::jsonb) into out from (
  select q.question_id,row_number() over(order by case when v_mode in ('random','weak') then random() else 0 end,q.question_id)::int ord
  from english.questions q join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and not s.mastered and coalesce(s.last_marked,false)
    and (v_mode<>'weak' or s.status in ('Persistent Weak','Weak','Fragile') or s.wrong>0)
  order by case when v_mode in ('random','weak') then random() else 0 end,q.question_id
  limit v_n
 ) x;
 return out;
end; $$;

create or replace function public.english_get_difficult_items(p_count integer default 100)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); v_n integer:=greatest(1,least(1000,coalesce(p_count,100))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(english.question_payload(uid,x.question_id) order by x.ord),'[]'::jsonb) into out from (
  select q.question_id,row_number() over(order by q.question_id)::int ord
  from english.questions q join english.difficult_state d on d.user_id=uid and d.question_id=q.question_id and d.difficult
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false) order by q.question_id limit v_n
 ) x;
 return out;
end; $$;

create or replace function public.english_get_topic_hub()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with rows as (
 select english.canonical_category(q.topic) id,q.topic,coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.mastered,false) mastered
 from english.questions q left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
 where auth.uid() is not null and q.active and not coalesce(s.mastered,false)
), g as (
 select id,count(*) total,count(*) filter(where status in ('Persistent Weak','Weak','Fragile')) weak,count(*) filter(where attempts>0) started,count(*) filter(where attempts=0) new_count,min(topic) topic from rows group by id
), names as (
 select *,case id when 'VOC' then 'Vocabulary' when 'IDIOM' then 'Idioms & Phrases' when 'PHRASAL' then 'Phrasal Verbs' when 'OWS' then 'One Word Substitution' when 'SYN_ANT' then 'Synonyms & Antonyms' when 'CONFUSED' then 'Confused Words' when 'SPELLING' then 'Spelling' when 'GRAMMAR' then 'Grammar' when 'ERROR' then 'Error Detection' when 'SENT_IMP' then 'Sentence Improvement' when 'FILL' then 'Fill in the Blanks' when 'CLOZE' then 'Cloze Test' when 'PARA' then 'Para Jumbles' when 'RC' then 'Reading Comprehension' else coalesce(topic,'Other') end name from g
)
select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'total',total,'weak',weak,'started',started,'newCount',new_count) order by case id when 'VOC' then 1 when 'IDIOM' then 2 when 'PHRASAL' then 3 when 'OWS' then 4 when 'SYN_ANT' then 5 when 'CONFUSED' then 6 when 'SPELLING' then 7 when 'GRAMMAR' then 8 when 'ERROR' then 9 when 'SENT_IMP' then 10 when 'FILL' then 11 when 'CLOZE' then 12 when 'PARA' then 13 when 'RC' then 14 else 99 end,name),'[]'::jsonb) from names; $$;

create or replace function public.english_get_topic_batch(p_category text,p_mode text default 'all',p_count integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); v_cat text:=upper(btrim(coalesce(p_category,'')));v_mode text:=lower(btrim(coalesce(p_mode,'all')));v_n integer:=greatest(1,least(120,coalesce(p_count,20)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(english.question_payload(uid,x.question_id) order by x.ord),'[]'::jsonb) into out from (
  select q.question_id,row_number() over(order by case
    when v_mode='random' and coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') then 0
    when v_mode='random' and english.recent_content_date(q)>=((now() at time zone 'Asia/Kolkata')::date-6) then 1
    when v_mode='random' and coalesce(s.attempts,0)>0 then 2 else 3 end,random())::int ord
  from english.questions q left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false) and english.canonical_category(q.topic)=v_cat
    and (v_mode not in ('weak','started','new') or (v_mode='weak' and (s.status in ('Persistent Weak','Weak','Fragile') or coalesce(s.wrong,0)>0)) or (v_mode='started' and coalesce(s.attempts,0)>0) or (v_mode='new' and coalesce(s.attempts,0)=0))
  order by case when v_mode='random' and coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') then 0 when v_mode='random' and english.recent_content_date(q)>=((now() at time zone 'Asia/Kolkata')::date-6) then 1 when v_mode='random' and coalesce(s.attempts,0)>0 then 2 else 3 end,case when v_mode<>'all' then random() else 0 end,q.question_id limit v_n
 ) x;
 return out;
end; $$;

create or replace function public.english_get_demand_sets()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with g as (
 select ps.set_id,ps.name,ps.description,ps.created_at,
 count(*) filter(where q.active and not coalesce(s.mastered,false)) count,
 count(*) filter(where q.active and not coalesce(s.mastered,false) and (coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') or coalesce(s.wrong,0)>0 or coalesce(s.attempts,0)>0)) weak_started
 from english.practice_sets ps join english.practice_set_items i on i.set_id=ps.set_id join english.questions q on q.question_id=i.question_id left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
 where auth.uid() is not null and ps.active group by ps.set_id,ps.name,ps.description,ps.created_at
)
select coalesce(jsonb_agg(jsonb_build_object('id',set_id,'name',name,'count',count,'weakStarted',weak_started,'created',created_at,'notes',coalesce(description,'')) order by created_at desc),'[]'::jsonb) from g; $$;

create or replace function public.english_get_demand_batch(p_set_id text default '__ALL__',p_mode text default 'all',p_count integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();v_id text:=btrim(coalesce(p_set_id,'__ALL__'));v_mode text:=lower(btrim(coalesce(p_mode,'all')));v_n integer:=greatest(1,least(100,coalesce(p_count,20)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(english.question_payload(uid,x.question_id) order by x.ord),'[]'::jsonb) into out from (
  select distinct on (i.question_id) i.question_id,
    row_number() over(order by case when v_mode='random' and (coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') or coalesce(s.wrong,0)>0) then 0 when v_mode='random' and english.recent_content_date(q)>=((now() at time zone 'Asia/Kolkata')::date-6) then 1 when v_mode='random' and coalesce(s.last_marked,false) then 2 when v_mode='random' and coalesce(s.attempts,0)>0 then 3 else 4 end,case when v_mode in ('weak','random') then random() else min(i.sequence) over(partition by i.question_id) end)::int ord
  from english.practice_set_items i join english.practice_sets ps on ps.set_id=i.set_id join english.questions q on q.question_id=i.question_id left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where ps.active and (v_id='__ALL__' or i.set_id=v_id) and q.active and not coalesce(s.mastered,false)
   and (v_mode<>'weak' or coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') or coalesce(s.wrong,0)>0 or coalesce(s.attempts,0)>0)
  order by i.question_id,ord
 ) x order by x.ord limit case when v_mode='all' then 100 else v_n end;
 return out;
end; $$;

revoke all on function public.english_get_saved_items() from public;
revoke all on function public.english_get_starred_items(text,integer) from public;
revoke all on function public.english_get_difficult_items(integer) from public;
revoke all on function public.english_get_topic_hub() from public;
revoke all on function public.english_get_topic_batch(text,text,integer) from public;
revoke all on function public.english_get_demand_sets() from public;
revoke all on function public.english_get_demand_batch(text,text,integer) from public;
grant execute on function public.english_get_saved_items() to authenticated;
grant execute on function public.english_get_starred_items(text,integer) to authenticated;
grant execute on function public.english_get_difficult_items(integer) to authenticated;
grant execute on function public.english_get_topic_hub() to authenticated;
grant execute on function public.english_get_topic_batch(text,text,integer) to authenticated;
grant execute on function public.english_get_demand_sets() to authenticated;
grant execute on function public.english_get_demand_batch(text,text,integer) to authenticated;

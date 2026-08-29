create or replace function public.english_get_hindu_quiz()
returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();v_today date:=(now() at time zone 'Asia/Kolkata')::date;out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id','HINDU_'||h.hindu_id,'hinduId',h.hindu_id,'centralQuestionId',cx.question_id,
  'category','HINDU_VOCAB','topic','The Hindu Vocabulary','word',h.word,
  'question','What is the closest meaning of '||h.word||'?',
  'options',jsonb_build_array(
    jsonb_build_object('key','A','text',coalesce(h.meaning,'')),
    jsonb_build_object('key','B','text',coalesce(d.arr[1],'None of these meanings')),
    jsonb_build_object('key','C','text',coalesce(d.arr[2],'A different meaning')),
    jsonb_build_object('key','D','text',coalesce(d.arr[3],'Another usage'))
  ),'correctKey','A','explanation',coalesce(h.meaning,''),'example',coalesce(h.example_sentence,''),
  'usageNote',coalesce(h.usage_note,''),'tip',coalesce(h.tip,''),'memoryAid',coalesce(h.memory_aid,''),
  'related',case when nullif(btrim(coalesce(h.synonyms,'')),'') is not null then 'Synonyms: '||h.synonyms else '' end,
  'source',coalesce(h.source_name,'The Hindu'),'sourcePage','',
  'marked',coalesce(r.marked,false),'inVocab',coalesce(r.in_vocab,false),
  'difficult',coalesce(ds.difficult,false),'mastered',coalesce(qs.mastered,false),'status',coalesce(qs.status,'New')
 ) order by h.hindu_id),'[]'::jsonb) into out
 from english.hindu_words h
 left join english.hindu_vocab_registry r on r.user_id=uid and r.hindu_id=h.hindu_id
 left join lateral (select english.resolve_hindu_question_id(uid,h.hindu_id) question_id) cx on true
 left join english.difficult_state ds on ds.user_id=uid and ds.question_id=cx.question_id
 left join english.question_state qs on qs.user_id=uid and qs.question_id=cx.question_id
 left join lateral (select array_agg(z.meaning order by random()) arr from (select distinct h2.meaning from english.hindu_words h2 where h2.active and h2.word_date=v_today and h2.hindu_id<>h.hindu_id and nullif(btrim(coalesce(h2.meaning,'')),'') is not null and lower(btrim(h2.meaning))<>lower(btrim(coalesce(h.meaning,''))) limit 10) z) d on true
 where h.active and h.word_date=v_today and nullif(btrim(coalesce(h.word,'')),'') is not null and nullif(btrim(coalesce(h.meaning,'')),'') is not null;
 return out;
end $$;

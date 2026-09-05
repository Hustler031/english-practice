\set ON_ERROR_STOP on
create extension if not exists pgcrypto;
create schema if not exists english;
create schema if not exists auth;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create table english.hindu_words(
  hindu_id text primary key,word_date date,word text not null,part_of_speech text,meaning text,synonyms text,antonyms text,
  example_sentence text,word_family text,usage_note text,tip text,memory_aid text,article_title text,source_url text,source_name text,
  learning_status text,content_status text,active boolean not null default true
);
create table english.questions(
  question_id text primary key,topic text,word text,question text not null,option_a text,option_b text,option_c text,option_d text,correct text,
  explanation text,subtopic text,question_type text,source_file text,source_page text,concept_id text,difficulty text,source_id text,
  learning_status text,content_status text,exam_relevance text,tip text,usage_note text,example_sentence text,memory_aid text,related_words text,
  source_url text,review_notes text,active boolean not null default true,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table english.sources(
  source_id text primary key,source_type text,source_name text,source_file text,source_date date,active boolean not null default true,
  imported_on timestamptz,question_count integer,source_ref text,notes text,import_status text,new_count integer,recall_count integer,
  duplicate_count integer,category_summary text,processed_on timestamptz
);
create table english.concepts(
  concept_id text primary key,domain text not null default 'English',skill_family text not null default 'Unclassified',name text not null,
  description text,confidence text not null default 'medium',exam_relevance text not null default 'medium',priority_score numeric not null default 0,
  coverage_state text not null default 'unseen',is_atomic boolean not null default true,active boolean not null default true,metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table english.question_concept_mappings(
  question_id text primary key,concept_id text not null,family_id text,mapping_confidence numeric not null default .5,
  mapping_method text not null default 'deterministic_metadata',model text,review_status text not null default 'mapped',relation_type text not null default 'primary',
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

-- Minimal production-helper stubs for the Phrasal task wrapper.
create or replace function english.maintenance_phrasal_batch(integer default 20) returns jsonb language sql as $$
  select jsonb_build_object('ok',true,'date',(now() at time zone 'Asia/Kolkata')::date,'sourceId','PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD'),'sourceFile','Phrasal Daily test','count',20,'existingToday',0,'items',(select jsonb_agg(jsonb_build_object('conceptId','PC'||g)) from generate_series(1,20) g))
$$;
create or replace function english.maintenance_apply_phrasal_daily(jsonb) returns jsonb language plpgsql as $$
declare i int; sid text:='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD'); begin
  for i in 1..20 loop
    insert into english.concepts(concept_id,name,skill_family,active) values('PC'||i,'Phrasal concept '||i,'Phrasal Verb',true) on conflict do nothing;
    insert into english.questions(question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,concept_id,source_id,active)
    values('PVTEST'||i,'Phrasal Verb','pv'||i,'Q'||i,'A','B','C','D','A','Explanation','PC'||i,sid,true) on conflict do nothing;
  end loop;
  return jsonb_build_object('ok',true,'count',20);
end $$;
create or replace function english.maintenance_verify_phrasal_daily() returns jsonb language sql as $$
  select jsonb_build_object('ok',(select count(*)=20 from english.questions where source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')))
$$;

\ir ../../supabase/managed-migrations/20260905084500_english_phrasal_hindu_chatgpt_bridge.sql
\ir ../../supabase/managed-migrations/20260905084600_english_phrasal_task_central_mapping.sql

-- Candidate duplicate check must catch an exact historical target.
insert into english.questions(question_id,topic,word,question,active) values('OLD1','Vocabulary','MITIGATE','old',true);
do $$ declare x jsonb; begin
  x:=english.maintenance_hindu_check_candidates('[{"word":"mitigate","familyKeys":["mitigate","mitigation"]}]'::jsonb);
  if not (x->'items'->0->>'duplicate')::boolean then raise exception 'Hindu duplicate check missed exact historical target: %',x; end if;
end $$;
delete from english.questions where question_id='OLD1';

-- One valid partial Hindu item must atomically create registry + question + concept mapping + partial source.
do $$ declare x jsonb; vdate text:=to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD'); begin
  x:=english.maintenance_apply_hindu_daily(jsonb_build_array(jsonb_build_object(
    'word','ABSTRUSE','partOfSpeech','adjective','meaning','difficult to understand','synonyms','obscure','antonyms','clear',
    'example','The argument was too abstruse for a general audience.','wordFamily','abstruse, abstruseness','usageNote','formal register',
    'tip','','memoryAid','','articleTitle','Test article','sourceUrl','https://example.com/test','sourceName','Test News; Merriam-Webster verification',
    'question','Choose the closest meaning of abstruse.','optionA','obvious','optionB','difficult to understand','optionC','cheerful','optionD','temporary',
    'correctKey','B','explanation','Abstruse means difficult to understand; obscure is a close synonym.','questionType','Meaning','difficulty','Hard',
    'familyKeys',jsonb_build_array('abstruse','abstruseness'),'relatedWords','obscure','distinctSenseException',false,'reviewNotes',''
  )));
  if not (x->>'ok')::boolean then raise exception 'Hindu apply verification failed: %',x; end if;
  if (select count(*) from english.hindu_words)<>1 then raise exception 'Hindu registry row missing'; end if;
  if (select count(*) from english.questions where source_id='HINDU_'||vdate)<>1 then raise exception 'Hindu canonical question missing'; end if;
  if (select count(*) from english.question_concept_mappings m join english.questions q on q.question_id=m.question_id where q.source_id='HINDU_'||vdate and m.concept_id=q.concept_id)<>1 then raise exception 'Hindu Central Intelligence mapping missing'; end if;
  if not exists(select 1 from english.sources where source_id='HINDU_'||vdate and import_status='Partial' and question_count=1) then raise exception 'Hindu partial source metadata missing'; end if;
end $$;

-- Phrasal task wrappers must map all 20 Central-selected concepts immediately.
do $$ declare c jsonb; a jsonb; rid uuid; items jsonb; begin
  c:=public.english_phrasal_task_claim();
  rid:=(c->>'runId')::uuid;
  items:=(select jsonb_agg(jsonb_build_object('conceptId','PC'||g)) from generate_series(1,20) g);
  a:=public.english_phrasal_task_apply(rid,items);
  if not (a->>'ok')::boolean or (a->>'centralMapped')::int<>20 then raise exception 'Phrasal Central mapping failed: %',a; end if;
end $$;

select 'English Phrasal/Hindu private ChatGPT bridge PostgreSQL contracts passed' result;

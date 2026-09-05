\set ON_ERROR_STOP on
create schema if not exists auth;
create schema if not exists english;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create table auth.users(id uuid primary key,deleted_at timestamptz);
create table english.questions(
  question_id text primary key,
  topic text,word text,question text,option_a text,option_b text,option_c text,option_d text,correct text,explanation text,
  subtopic text,question_type text,source_file text,source_page text,concept_id text,difficulty text,source_id text,
  learning_status text,content_status text,exam_relevance text,tip text,usage_note text,example_sentence text,memory_aid text,
  related_words text,source_url text,review_notes text,active boolean not null default true,
  created_at timestamptz default now(),updated_at timestamptz default now()
);
create table english.question_origins(
  question_id text not null,origin_kind text not null,origin_ref text not null,owner_user_id uuid,
  primary key(question_id,origin_kind,origin_ref)
);
create table english.attempts(
  attempt_id text primary key,user_id uuid not null,question_id text not null,attempted_at timestamptz default now()
);
create table english.sources(
  source_id text primary key,source_type text,source_name text,source_file text,source_date date,active boolean,
  imported_on timestamptz,question_count integer,source_ref text,notes text,import_status text,new_count integer,
  recall_count integer,duplicate_count integer,category_summary text,processed_on timestamptz
);

insert into auth.users(id) values('00000000-0000-0000-0000-000000000001');

create or replace function public.english_get_phrasal_maintenance_batch(p_mode text default 'smart',p_count integer default 20)
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'phrasalConceptId','PC'||lpad(g::text,2,'0'),
    'conceptId','PC'||lpad(g::text,2,'0'),
    'missingFamily','recognition',
    'phrasalQuestionFamily','recognition'
  ) order by g),'[]'::jsonb)
  from generate_series(1,greatest(0,least(20,p_count))) g;
$$;

create or replace function public.english_get_phrasal_hub()
returns jsonb language sql stable as $$ select jsonb_build_object('today',jsonb_build_object('count',20)) $$;

create or replace function english.phrasal_question_family(p_q english.questions)
returns text language sql immutable as $$ select case when coalesce(($1).question_type,'')='Recall' then 'recall' else 'recognition' end $$;

-- The recovered migration safely raises the HTTP budget by rewriting this existing function.
create or replace function english.kick_context_worker(p_context_limit integer default 6,p_transfer_limit integer default 1)
returns bigint
language plpgsql
security definer
as $fn$
begin
  perform 'timeout_milliseconds:=55000';
  return 0;
end
$fn$;

\ir ../../supabase/managed-migrations/20260904193012_english_phrasal_maintenance_and_ai_budgets.sql

create or replace function pg_temp.final_payload(p_bad_concept boolean default false)
returns jsonb
language sql
stable
as $$
  select jsonb_agg(jsonb_build_object(
    'conceptId',case when p_bad_concept and g=20 then 'WRONG' else 'PC'||lpad(g::text,2,'0') end,
    'family','recognition',
    'questionType','Recognition',
    'question','Choose the correct phrasal verb meaning for item '||g||'.',
    'optionA','Correct meaning '||g,
    'optionB','Close distractor B '||g,
    'optionC','Close distractor C '||g,
    'optionD','Close distractor D '||g,
    'correctKey','A',
    'explanation','The correct option matches the phrasal verb; the close distractors express different meanings for item '||g||'.',
    'difficulty','Hard',
    'word','phrasal-'||g,
    'baseQuestionId','BASE'||g,
    'contentGap',false
  ) order by g)
  from generate_series(1,20) g;
$$;

-- Publication refuses an incomplete payload before touching canonical data.
do $$ declare failed boolean:=false; before_n integer; after_n integer; begin
  select count(*) into before_n from english.questions;
  begin
    perform english.maintenance_apply_phrasal_daily((select jsonb_agg(x) from jsonb_array_elements(pg_temp.final_payload(false)) with ordinality e(x,n) where n<=19));
  exception when others then failed:=true; end;
  if not failed then raise exception '19-item Phrasal payload unexpectedly succeeded'; end if;
  select count(*) into after_n from english.questions;
  if after_n<>before_n then raise exception 'Incomplete payload caused partial canonical writes'; end if;
end $$;

-- Exact 20 is not enough if the concepts do not match the Central-selected slots.
do $$ declare failed boolean:=false; before_n integer; after_n integer; begin
  select count(*) into before_n from english.questions;
  begin perform english.maintenance_apply_phrasal_daily(pg_temp.final_payload(true));
  exception when others then failed:=true; end;
  if not failed then raise exception 'Wrong-concept Phrasal payload unexpectedly succeeded'; end if;
  select count(*) into after_n from english.questions;
  if after_n<>before_n then raise exception 'Wrong-concept payload caused partial canonical writes'; end if;
end $$;

-- A partial current-day batch with learner history is protected from destructive rebuild.
insert into english.questions(question_id,topic,question,option_a,option_b,option_c,option_d,correct,explanation,question_type,concept_id,source_id,active)
values('PVTEMP','Phrasal Verb','Protected partial item','A','B','C','D','A','Protected explanation','Recognition','PC01','PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD'),true);
insert into english.attempts(attempt_id,user_id,question_id) values('ATT-PVTEMP','00000000-0000-0000-0000-000000000001','PVTEMP');
do $$ declare failed boolean:=false; keep_n integer; begin
  begin perform english.maintenance_apply_phrasal_daily(pg_temp.final_payload(false));
  exception when others then failed:=true; end;
  if not failed then raise exception 'Attempted partial Phrasal batch was destructively rebuilt'; end if;
  select count(*) into keep_n from english.questions where question_id='PVTEMP';
  if keep_n<>1 then raise exception 'Attempted partial Phrasal row was not preserved'; end if;
end $$;
delete from english.attempts where attempt_id='ATT-PVTEMP';
delete from english.questions where question_id='PVTEMP';

-- A valid exact-20 payload publishes atomically and passes the verification projection.
do $$ declare result jsonb; verify jsonb; qn integer; on_ integer; begin
  result:=english.maintenance_apply_phrasal_daily(pg_temp.final_payload(false));
  if coalesce((result->>'ok')::boolean,false) is not true or (result->>'count')::int<>20 then
    raise exception 'Valid Phrasal materialization did not report exact 20: %',result;
  end if;
  select count(*) into qn from english.questions where source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD') and active;
  select count(*) into on_ from english.question_origins o join english.questions q on q.question_id=o.question_id
  where q.source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD') and o.origin_kind='core';
  if qn<>20 or on_<>20 then raise exception 'Phrasal canonical/origin exact-20 invariant failed: questions %, origins %',qn,on_; end if;
  verify:=english.maintenance_verify_phrasal_daily();
  if coalesce((verify->>'ok')::boolean,false) is not true then raise exception 'Phrasal verification projection failed: %',verify; end if;
end $$;

-- Re-running a completed day is idempotent: no duplicates, no replacement.
do $$ declare result jsonb; before_ids jsonb; after_ids jsonb; begin
  select jsonb_agg(question_id order by question_id) into before_ids from english.questions where source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD');
  result:=english.maintenance_apply_phrasal_daily(pg_temp.final_payload(false));
  if coalesce((result->>'alreadyComplete')::boolean,false) is not true then raise exception 'Completed Phrasal day was not idempotent: %',result; end if;
  select jsonb_agg(question_id order by question_id) into after_ids from english.questions where source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD');
  if before_ids is distinct from after_ids then raise exception 'Idempotent rerun changed Phrasal question IDs'; end if;
end $$;

select 'English Phrasal exact-20 atomic publication contracts passed' result;

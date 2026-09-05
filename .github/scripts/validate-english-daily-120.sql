\set ON_ERROR_STOP on

-- Minimal English V2 Daily harness. The revision CI step has already created auth/english
-- and several shared tables; make the harness idempotent so it can also run independently.
create extension if not exists pgcrypto;
create schema if not exists auth;
create schema if not exists english;

do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create table if not exists auth.users(id uuid primary key);
create table if not exists english.questions(
  question_id text primary key, topic text, question text not null default '', active boolean not null default true,
  concept_id text, source_id text, word text, option_a text, option_b text, option_c text, option_d text,
  correct text, explanation text, subtopic text, question_type text, source_file text, source_page text,
  difficulty text, learning_status text, content_status text, exam_relevance text, related_words text, review_notes text
);
alter table english.questions add column if not exists active boolean not null default true;
alter table english.questions add column if not exists topic text;
alter table english.questions add column if not exists concept_id text;

create table if not exists english.question_state(
  user_id uuid,question_id text,mastered boolean not null default false,last_attempt timestamptz,
  primary key(user_id,question_id)
);
alter table english.question_state add column if not exists attempts integer not null default 0;
alter table english.question_state add column if not exists status text not null default 'New';
alter table english.question_state add column if not exists next_review timestamptz;
alter table english.question_state add column if not exists last_marked boolean not null default false;
alter table english.question_state add column if not exists correct integer not null default 0;
alter table english.question_state add column if not exists wrong integer not null default 0;
alter table english.question_state add column if not exists accuracy numeric not null default 0;

create table if not exists english.difficult_state(
  user_id uuid,question_id text,difficult boolean not null default false,primary key(user_id,question_id)
);
create table if not exists english.question_concept_mappings(
  question_id text primary key,concept_id text,family_id text,mapping_confidence numeric,mapping_method text,
  model text,review_status text,relation_type text,updated_at timestamptz default now()
);
create table if not exists english.concepts(
  concept_id text primary key,name text,skill_family text,description text,exam_relevance text,active boolean not null default true
);
create table if not exists english.concept_evidence(
  user_id uuid,concept_id text,coverage_state text,confidence_score numeric,next_review timestamptz,primary key(user_id,concept_id)
);
create table if not exists english.learning_route_state(
  user_id uuid,question_id text,route text,metadata jsonb not null default '{}'::jsonb,origins text[] not null default '{}',
  last_route_reason text,targeted_at timestamptz,updated_at timestamptz not null default now(),primary key(user_id,question_id)
);
create table if not exists english.attempts(
  attempt_id text primary key,user_id uuid,question_id text,attempted_at timestamptz default now(),
  selected_answer text,correct boolean,time_seconds numeric
);
alter table english.attempts add column if not exists module text;

create table if not exists english.daily_current(
  user_id uuid not null,question_id text not null,sequence integer not null,priority integer not null default 0,
  reason text,quiz_date date,status text,topic text,concept_id text,selection_signals text[],selection_snapshot jsonb,
  primary key(user_id,question_id),unique(user_id,sequence)
);

create or replace function english.question_visible_to_user(uuid,text) returns boolean language sql stable as $$ select true $$;
create or replace function english.is_genuine_bank_question(english.questions) returns boolean language sql stable as $$ select true $$;
create or replace function english.learning_category(text) returns text language sql immutable as $$ select coalesce($1,'Other') $$;
create or replace function english.daily_category_penalties(uuid) returns table(category text,penalty numeric) language sql stable as $$ select null::text,null::numeric where false $$;
create or replace function english.daily_reason_base_score(text) returns integer language sql immutable as $$
  select case $1 when 'Persistent Weak' then 900 when 'Weak' then 800 when 'Fragile' then 700
    when 'Due Spaced Revision' then 600 when 'Learning' then 500 when 'Marked Review' then 450
    when 'Difficult Review' then 425 when 'Controlled New' then 300 else 100 end
$$;
create or replace function english.daily_signal_codes(text,text,boolean,boolean,boolean,boolean)
returns text[] language sql immutable as $$ select array[replace(upper(coalesce($1,'')),' ','_')]::text[] $$;
create or replace function english.daily_quota(text,integer) returns integer language sql immutable as $$
  select greatest(1,floor($2*case $1 when 'Persistent Weak' then .20 when 'Weak' then .16 when 'Fragile' then .14
    when 'Due Spaced Revision' then .15 when 'Learning' then .08 when 'Marked Review' then .05
    when 'Difficult Review' then .05 when 'Controlled New' then .10 when 'Mixed Revision' then .02 else 0 end)::int)
$$;
create or replace function english.daily_cap(text,integer) returns integer language sql immutable as $$
  select greatest(1,ceil($2*case $1 when 'Persistent Weak' then .30 when 'Weak' then .25 when 'Fragile' then .20
    when 'Due Spaced Revision' then .25 when 'Learning' then .15 when 'Marked Review' then .10
    when 'Difficult Review' then .10 when 'Controlled New' then .15 when 'Mixed Revision' then .05 else .02 end)::int)
$$;
create or replace function english.archive_daily(uuid,date) returns integer language plpgsql as $$
declare n int; begin delete from english.daily_current where user_id=$1 and quiz_date=$2; get diagnostics n=row_count; return n; end $$;

-- Stub is replaced only for test presentation; the Stage-1 migration's ensure_daily resolves it at runtime.
create or replace function english.current_daily_items(p_user_id uuid)
returns table(sequence integer,priority integer,reason text,quiz_date date,status text,question_id text)
language sql stable as $$
  select d.sequence,d.priority,d.reason,d.quiz_date,d.status,d.question_id
  from english.daily_current d where d.user_id=p_user_id order by d.sequence
$$;

\ir ../../supabase/managed-migrations/20260905094500_english_daily_ai_priority_nonstarvation.sql

-- Recreate the compact test helper after migration (production has the richer existing function).
create or replace function english.current_daily_items(p_user_id uuid)
returns table(sequence integer,priority integer,reason text,quiz_date date,status text,question_id text)
language sql stable as $$
  select d.sequence,d.priority,d.reason,d.quiz_date,d.status,d.question_id
  from english.daily_current d
  where d.user_id=p_user_id
    and (lower(coalesce(d.status,''))='completed' or english.daily_reason(p_user_id,d.question_id,d.quiz_date)<>'')
  order by d.sequence
$$;

-- Fixture helpers.
insert into auth.users(id) values('00000000-0000-0000-0000-000000000001') on conflict do nothing;

create or replace function pg_temp.reset_daily_fixture(p_count integer,p_attempts integer,p_state text,p_targeted integer)
returns void language plpgsql as $$
declare i integer; qid text; cid text; begin
  delete from english.daily_current;
  delete from english.attempts;
  delete from english.learning_route_state;
  delete from english.concept_evidence;
  delete from english.question_state;
  delete from english.question_concept_mappings;
  delete from english.concepts;
  delete from english.questions;
  for i in 1..p_count loop
    qid:='Q'||lpad(i::text,4,'0'); cid:='C'||lpad(i::text,4,'0');
    insert into english.questions(question_id,topic,question,active,concept_id) values(qid,'Vocabulary','Question '||i,true,cid);
    insert into english.concepts(concept_id,name,exam_relevance,active) values(cid,'Concept '||i,'high',true);
    insert into english.question_concept_mappings(question_id,concept_id) values(qid,cid);
    insert into english.question_state(user_id,question_id,attempts,status,next_review,mastered)
    values('00000000-0000-0000-0000-000000000001',qid,p_attempts,p_state,
      case when p_attempts=0 then null else now()-interval '2 days' end,false);
    if i<=p_targeted then
      insert into english.learning_route_state(user_id,question_id,route,metadata,targeted_at)
      values('00000000-0000-0000-0000-000000000001',qid,'targeted','{"targeted_kind":"need_learning"}'::jsonb,now());
    end if;
  end loop;
end $$;

-- 200 Weak with 100 Targeted: Targeted must not replace Weak as the base reason or starve capacity.
select pg_temp.reset_daily_fixture(200,1,'Weak',100);
do $$ declare n int; targeted_n int; bad_reason int; distinct_n int; begin
  n:=english.create_daily('00000000-0000-0000-0000-000000000001',((now() at time zone 'Asia/Kolkata')::date),120);
  if n<>120 then raise exception 'Daily targeted/weak non-starvation failed: expected 120 got %',n; end if;
  select count(*) into bad_reason from english.daily_current where reason='Targeted Repair';
  if bad_reason<>0 then raise exception 'Targeted incorrectly replaced base Daily reason'; end if;
  select count(*) into targeted_n from english.daily_current where coalesce(selection_signals,'{}') @> array['TARGET']::text[];
  if targeted_n>18 then raise exception 'Targeted overlay exceeded hard maximum: %',targeted_n; end if;
  select count(distinct coalesce(m.concept_id,d.question_id)) into distinct_n
  from english.daily_current d left join english.question_concept_mappings m on m.question_id=d.question_id;
  if distinct_n<>120 then raise exception 'Daily concept dedupe failed: % distinct',distinct_n; end if;
end $$;

-- Controlled New is intentionally capped for balance first; final capacity fill must still reach 120.
select pg_temp.reset_daily_fixture(200,0,'New',0);
do $$ declare n int; begin
  n:=english.create_daily('00000000-0000-0000-0000-000000000001',((now() at time zone 'Asia/Kolkata')::date),120);
  if n<>120 then raise exception 'Controlled-New capacity fill failed: expected 120 got %',n; end if;
end $$;

-- Scarcity is the only legitimate under-target outcome.
select pg_temp.reset_daily_fixture(119,1,'Weak',0);
do $$ declare n int; begin
  n:=english.create_daily('00000000-0000-0000-0000-000000000001',((now() at time zone 'Asia/Kolkata')::date),120);
  if n<>119 then raise exception 'Scarcity contract failed: expected 119 got %',n; end if;
end $$;

-- Same-day repair: preserve 43 completed rows and an attempted stale row, while restoring 120 visible items.
select pg_temp.reset_daily_fixture(200,1,'Weak',60);
insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
select '00000000-0000-0000-0000-000000000001',q.question_id,row_number() over(order by q.question_id),800,'Weak',
       ((now() at time zone 'Asia/Kolkata')::date),'completed','Vocabulary',q.concept_id,'{}','{}'
from english.questions q where q.question_id between 'Q0001' and 'Q0043';
insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
select '00000000-0000-0000-0000-000000000001','Q0044',44,100,'Weak',((now() at time zone 'Asia/Kolkata')::date),'New','Vocabulary','C0044','{}','{}';
update english.question_state set status='Strong',next_review=now()+interval '10 days' where user_id='00000000-0000-0000-0000-000000000001' and question_id='Q0044';
insert into english.attempts(attempt_id,user_id,question_id,attempted_at,module) values(
  'ATTEMPT_STALE','00000000-0000-0000-0000-000000000001','Q0044',now(),'Daily'
);

do $$ declare added int; visible_n int; completed_n int; raw_stale int; attempt_n int; begin
  added:=english.repair_daily_shortfall('00000000-0000-0000-0000-000000000001',((now() at time zone 'Asia/Kolkata')::date),120);
  select count(*) into visible_n from english.daily_current d where d.user_id='00000000-0000-0000-0000-000000000001'
    and (lower(coalesce(d.status,''))='completed' or english.daily_reason(d.user_id,d.question_id,d.quiz_date)<>'');
  select count(*) into completed_n from english.daily_current where user_id='00000000-0000-0000-0000-000000000001' and status='completed';
  select count(*) into raw_stale from english.daily_current where user_id='00000000-0000-0000-0000-000000000001' and question_id='Q0044';
  select count(*) into attempt_n from english.attempts where attempt_id='ATTEMPT_STALE';
  if visible_n<>120 then raise exception 'Same-day top-up failed: expected 120 visible got % (added %)',visible_n,added; end if;
  if completed_n<>43 then raise exception 'Completed rows were not preserved: %',completed_n; end if;
  if raw_stale<>1 or attempt_n<>1 then raise exception 'Attempted stale row/history was not preserved'; end if;
end $$;

select 'English Daily exact-120/non-starvation PostgreSQL contracts passed' as result;

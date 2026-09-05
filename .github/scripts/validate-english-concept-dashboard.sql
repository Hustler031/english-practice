\set ON_ERROR_STOP on
create schema if not exists auth;
create schema if not exists english;
create schema if not exists cron;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;
create or replace function auth.uid() returns uuid language sql stable as $$ select '00000000-0000-0000-0000-000000000001'::uuid $$;

create table english.questions(question_id text primary key,active boolean not null default true,concept_id text);
create table english.question_concept_mappings(question_id text primary key,concept_id text);
create table english.concepts(concept_id text primary key,domain text,skill_family text,name text,exam_relevance text,priority_score numeric,active boolean not null default true);
create table english.concept_evidence(user_id uuid,concept_id text,coverage_state text,confidence_score numeric,attempts integer,wrong integer,next_review timestamptz,primary key(user_id,concept_id));
create table english.learner_confusions(confusion_id uuid primary key,user_id uuid,status text);
create table english.question_state(user_id uuid,question_id text,mastered boolean not null default false,primary key(user_id,question_id));
create table english.semantic_queue(entity_type text,entity_id text,user_id uuid,status text,next_attempt_at timestamptz,created_at timestamptz default now(),updated_at timestamptz default now());
create table english.learner_context_notes(note_id uuid primary key,user_id uuid,ai_status text,ai_next_attempt_at timestamptz,created_at timestamptz default now(),processed_at timestamptz);
create table english.targeted_transfer_jobs(job_id uuid primary key,user_id uuid,status text,next_attempt_at timestamptz,created_at timestamptz default now(),updated_at timestamptz default now());
create table english.question_revision_proposals(proposal_id uuid primary key,user_id uuid,status text,next_attempt_at timestamptz,created_at timestamptz default now(),updated_at timestamptz default now());
create table english.question_quality_reviews(review_id uuid primary key,user_id uuid,status text,next_attempt_at timestamptz,created_at timestamptz default now(),updated_at timestamptz default now());
create table cron.job(jobid bigint primary key,jobname text);
create table cron.job_run_details(jobid bigint,start_time timestamptz,status text);
create or replace function english.question_visible_to_user(uuid,text) returns boolean language sql stable as $$ select true $$;

insert into english.concepts values
 ('C_SEEN','Vocabulary','Words','Seen concept','medium',50,true),
 ('C_WEAK','Grammar','Rule','Weak concept','high',90,true),
 ('C_RET','Vocabulary','Words','Retention concept','high',85,true),
 ('C_SEC','Grammar','Rule','Secure concept','medium',70,true),
 ('C_EXAM','Vocabulary','Words','Exam-ready concept','high',100,true),
 ('C_UNSEEN','Grammar','Rule','Unseen high-yield concept','high',95,true);
insert into english.questions values
 ('Q1',true,'C_SEEN'),('Q2',true,'C_WEAK'),('Q3',true,'C_RET'),('Q4',true,'C_SEC'),('Q5',true,'C_EXAM'),('Q6',true,'C_UNSEEN'),('Q_UNMAPPED',true,null);
insert into english.question_concept_mappings values
 ('Q1','C_SEEN'),('Q2','C_WEAK'),('Q3','C_RET'),('Q4','C_SEC'),('Q5','C_EXAM'),('Q6','C_UNSEEN');
insert into english.concept_evidence values
 ('00000000-0000-0000-0000-000000000001','C_SEEN','seen',45,1,0,null),
 ('00000000-0000-0000-0000-000000000001','C_WEAK','weak',30,4,3,now()),
 ('00000000-0000-0000-0000-000000000001','C_RET','retention_risk',65,5,1,now()),
 ('00000000-0000-0000-0000-000000000001','C_SEC','secure',75,5,0,now()+interval '2 days'),
 ('00000000-0000-0000-0000-000000000001','C_EXAM','exam_ready',90,8,0,now()+interval '10 days');
insert into english.learner_confusions values(gen_random_uuid(),'00000000-0000-0000-0000-000000000001','open');
insert into cron.job values(1,'english-semantic-refinement'),(2,'english-context-intelligence'),(3,'english-question-revision');
insert into cron.job_run_details values(1,now(),'succeeded'),(2,now(),'succeeded'),(3,now(),'succeeded');

\ir ../../supabase/managed-migrations/20260905100000_english_concept_dashboard_and_worker_health.sql

do $$ declare s jsonb; d jsonb; h jsonb; begin
  s:=public.english_get_concept_intelligence_summary();
  if (s->>'concepts')::int<>6 then raise exception 'concept total mismatch: %',s; end if;
  if (s->>'active_questions')::int<>7 or (s->>'mapped_questions')::int<>6 or (s->>'unmapped_questions')::int<>1 then raise exception 'mapping reconciliation mismatch: %',s; end if;
  if (s->>'seen')::int<>1 or (s->>'weak_only')::int<>1 or (s->>'retention_risk')::int<>1 or (s->>'secure')::int<>1 or (s->>'exam_ready')::int<>1 or (s->>'unseen')::int<>1 then raise exception 'coverage-state reconciliation mismatch: %',s; end if;
  if (s->>'weak')::int<>2 then raise exception 'legacy weak aggregate changed: %',s; end if;
  if (s->>'covered')::int<>5 or (s->>'high_yield_unseen')::int<>1 or not (s->>'reconciles')::boolean then raise exception 'coverage summary mismatch: %',s; end if;
  d:=public.english_get_concept_intelligence_detail('weak');
  if jsonb_array_length(d)<>1 or d->0->>'concept_id'<>'C_WEAK' or d->0->>'question_id'<>'Q2' then raise exception 'weak drilldown mismatch: %',d; end if;
  d:=public.english_get_concept_intelligence_detail('high_yield_unseen');
  if jsonb_array_length(d)<>1 or d->0->>'concept_id'<>'C_UNSEEN' then raise exception 'high-yield unseen drilldown mismatch: %',d; end if;
  h:=public.english_get_ai_worker_health();
  if not (h->'workers'->'semantic'->>'healthy')::boolean or not (h->'workers'->'learning'->>'healthy')::boolean or not (h->'workers'->'quality'->>'healthy')::boolean then raise exception 'worker scheduler health mismatch: %',h; end if;
  if (h->>'queued')::int<>0 or (h->>'processing')::int<>0 or (h->>'retrying')::int<>0 then raise exception 'empty queue health mismatch: %',h; end if;
end $$;
select 'English concept dashboard and worker-health contracts passed' result;

\set ON_ERROR_STOP on
create extension if not exists pgcrypto;
create schema if not exists english;
create schema if not exists auth;

do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;

create table auth.users(
  id uuid primary key,
  deleted_at timestamptz
);

create table english.ai_content_feature_flags(
  flag text primary key,
  enabled boolean not null default false,
  activated_at timestamptz,
  metadata jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  constraint ai_content_feature_flags_name check(flag = any(array[
    'gemini_content_v1','groq_critic_v1','phrasal_sense_v1','phrasal_context_fill_v1','phrasal_variant_rotation_v1',
    'chatgpt_sprint_v1','hindu_tone_v1','antigravity_writer_v1','luna_critic_v1'
  ]))
);

create table english.chatgpt_content_task_runs(
  run_id uuid primary key default gen_random_uuid(),
  lane text not null,
  batch_date date not null,
  status text not null default 'claimed',
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  applied_at timestamptz,
  constraint chatgpt_content_task_runs_lane_check check(lane = any(array['phrasal','hindu'])),
  constraint chatgpt_content_task_runs_status_check check(status = any(array['claimed','checked','applied','superseded','failed']))
);

create table english.content_generation_audits(
  audit_id uuid primary key default gen_random_uuid(),
  lane text not null,
  entity_key text,
  generator_provider text not null,
  generator_model text,
  critic_provider text,
  critic_model text,
  quality_score numeric,
  critic_decision text,
  repair_count integer not null default 0 check(repair_count between 0 and 2),
  question_family text,
  sense_key text,
  variant_key text,
  variant_fingerprint text,
  publication_result text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  constraint content_generation_audits_lane_check check(lane = any(array['phrasal','hindu','saved','tone','sprint']))
);

create table english.questions(
  question_id text primary key,
  topic text,word text,question text not null,
  option_a text,option_b text,option_c text,option_d text,correct text,explanation text,
  subtopic text,question_type text,source_file text,source_page text,concept_id text,difficulty text,source_id text,
  learning_status text,content_status text,exam_relevance text,tip text,usage_note text,example_sentence text,memory_aid text,
  related_words text,source_url text,review_notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

create table english.question_state(
  user_id uuid not null,
  question_id text not null,
  attempts integer not null default 0,
  last_attempt timestamptz,
  primary key(user_id,question_id)
);

create table english.attempts(
  attempt_id text primary key,
  user_id uuid not null,
  question_id text not null,
  attempted_at timestamptz not null,
  selected_answer text,
  correct boolean,
  time_seconds numeric,
  marked_revision boolean,
  topic text,
  concept_id text,
  module text,
  submission_key text,
  created_at timestamptz not null default now(),
  source_row bigint
);

create table english.sprint_sessions(
  session_id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  mode text not null,
  status text not null default 'in_progress',
  question_count integer not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table english.sprint_items(
  session_id uuid not null,
  position integer not null,
  item_key text not null,
  canonical_question_id text,
  source_type text not null,
  category text not null,
  question_type text not null,
  question text not null,
  options jsonb not null,
  correct_key text not null,
  explanation text not null,
  metadata jsonb not null default '{}',
  primary key(session_id,position)
);

create table english.sprint_answers(
  session_id uuid not null,
  position integer not null,
  user_id uuid not null,
  selected_key text,
  correct boolean not null default false,
  time_seconds numeric not null default 0,
  diagnosis text,
  action text,
  confused_with text,
  created_at timestamptz not null default now(),
  visited boolean not null default false,
  marked_for_review boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key(session_id,position)
);

create table english.concepts(
  concept_id text primary key,
  domain text not null default 'English',
  skill_family text not null default 'Unclassified',
  name text not null,
  description text,
  confidence text not null default 'medium',
  exam_relevance text not null default 'medium',
  priority_score numeric not null default 0,
  coverage_state text not null default 'unseen',
  is_atomic boolean not null default true,
  active boolean not null default true,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table english.question_concept_mappings(
  question_id text primary key,
  concept_id text not null,
  family_id text,
  mapping_confidence numeric not null default .5,
  mapping_method text not null default 'deterministic_metadata',
  model text,
  embedding jsonb,
  review_status text not null default 'mapped',
  relation_type text not null default 'primary',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table english.question_origins(
  question_id text primary key,
  origin_kind text not null,
  origin_ref text,
  created_at timestamptz not null default now(),
  owner_user_id uuid
);

create table english.question_generation_provenance(
  question_id text primary key,
  owner_user_id uuid,
  source_question_id text,
  concept_id text,
  intent text not null,
  generation_source text not null,
  critic jsonb not null default '{}',
  related_terms jsonb not null default '[]',
  model text,
  usage jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create table english.sources(
  source_id text primary key,source_type text,source_name text,source_file text,source_date date,
  active boolean not null default true,imported_on timestamptz,question_count integer,source_ref text,notes text,import_status text,
  new_count integer,recall_count integer,duplicate_count integer,category_summary text,processed_on timestamptz
);

create or replace function english.generated_item_hard_gates_pass(p_item jsonb)
returns boolean language sql immutable as $$
select
  coalesce((p_item->'quality'->>'score')::numeric,0) >= 85
  and upper(coalesce(p_item->'quality'->>'decision','')) in ('PASS','PASS_WITH_MINOR_ISSUES')
  and coalesce((p_item->'quality'->'hardGates'->>'exactlyOneCorrect')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'correctKeyMatches')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'linguisticallyValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'conceptPreserved')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'sensePreserved')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'learnerRequestPreserved')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noFactualError')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noLexicalGrammarError')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'requiredOptionsValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'explanationMatchesQuestion')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'explanationMatchesAnswer')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noStaleExplanation')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noAmbiguity')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noSecondCorrectOption')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'intentSpecificTaskValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'questionFamilyValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'plausibleDistractors')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'distractorsNotObvious')::boolean,false)
$$;

\ir ../../supabase/migrations/20260909011500_english_grammar_preflight.sql
\ir ../../supabase/migrations/20260909012000_english_grammar_intelligence_foundation.sql
\ir ../../supabase/migrations/20260909012500_english_grammar_curriculum_sync.sql
\ir ../../supabase/migrations/20260909013000_english_grammar_daily_pipeline.sql

-- Feature is present but must remain disabled until the explicit deployment stage.
do $$ begin
  if not exists(select 1 from english.ai_content_feature_flags where flag='grammar_ai_v1' and enabled=false) then
    raise exception 'Grammar feature flag is not safely disabled after Stage 1 migrations';
  end if;
end $$;

-- Build a realistic 260-rule snapshot through the same validated sync function used for Stage 3.
do $$
declare payload jsonb; x jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'ruleKey','grammar_ci_rule_'||lpad(g::text,3,'0'),
    'chapter',(array['Subject–Verb Agreement','Articles & Determiners','Pronouns & Relative Clauses','Verb Patterns & Non-finites','Tense & Time','Conditionals & Wishes','Modals','Inversion & Negation','Comparison & Degree','Modifiers & Word Order','Conjunctions & Clauses','Voice','Narration','Sentence Structure & Parallelism'])[1+((g-1)%14)],
    'ruleFamily','CI behavior contract','ruleTitle','Verified rule '||g,
    'canonicalRule','Verified atomic grammar rule '||g||' for deterministic CI behavior testing.',
    'commonTrap','Trap '||g,'contrastWith','','priority',60+((g-1)%41),
    'difficulty',case when g%5=0 then 'Advanced' when g%2=0 then 'Moderate' else 'Basic' end,
    'supportedFamilies',jsonb_build_array('context_fill','sentence_improvement','error_detection','transfer'),
    'sourceName','Cambridge Grammar contract fixture','sourceUrl','https://dictionary.cambridge.org/grammar/british-grammar/',
    'verificationNote','Disposable PostgreSQL behavior fixture; production curriculum comes from the frozen verified manifest.',
    'sheetStatus','DORMANT'
  ) order by g) into payload from generate_series(1,260) g;
  x:=english.grammar_sync_curriculum('ci-260','',payload,'ci-spreadsheet');
  if not (x->>'ok')::boolean or (x->>'ruleCount')::int<>260 then raise exception 'Grammar curriculum sync failed: %',x; end if;
  if (select count(*) from english.grammar_rules where active)<>260 then raise exception 'Expected 260 active Grammar rules after sync'; end if;
end $$;

-- Sprint identity is bridged non-destructively into the same rule evidence system.
do $$
declare x jsonb; uid uuid:='11111111-1111-1111-1111-111111111111'; sid uuid:='22222222-2222-2222-2222-222222222222';
begin
  insert into auth.users(id) values(uid);
  x:=english.grammar_sync_sprint_aliases('ci-alias-v1',jsonb_build_array(jsonb_build_object(
    'aliasKey','grammar_ci_historical_alias','ruleKey','grammar_ci_rule_001','confidence',1,'notes','CI test alias'
  )));
  if not (x->>'ok')::boolean then raise exception 'Grammar Sprint alias sync failed: %',x; end if;
  insert into english.sprint_sessions(session_id,user_id,mode,status,question_count,started_at,completed_at)
    values(sid,uid,'standard','completed',1,now()-interval '2 minutes',now()-interval '1 minute');
  insert into english.sprint_items(session_id,position,item_key,canonical_question_id,source_type,category,question_type,question,options,correct_key,explanation,metadata)
    values(sid,1,'CI-SPRINT-1',null,'generated','Grammar','Fill in the Blank','Historical Sprint grammar question',
      '[{"key":"A","text":"a"},{"key":"B","text":"b"},{"key":"C","text":"c"},{"key":"D","text":"d"}]'::jsonb,'A','CI explanation',
      jsonb_build_object('conceptKey','grammar_ci_historical_alias'));
  insert into english.sprint_answers(session_id,position,user_id,selected_key,correct,time_seconds,visited)
    values(sid,1,uid,'A',true,8,true);
  if not exists(select 1 from english.grammar_rule_events where user_id=uid and rule_key='grammar_ci_rule_001' and source='sprint' and correct) then
    raise exception 'Sprint answer did not feed Grammar rule evidence';
  end if;
end $$;

-- Claim must produce exactly 20 Central-selected slots and preserve cold-start breadth.
do $$
declare c jsonb; rid uuid; bad jsonb; good jsonb; result jsonb; item jsonb; gates jsonb;
begin
  c:=public.english_grammar_task_claim();
  if not (c->>'ok')::boolean or (c->>'count')::int<>20 or jsonb_array_length(c->'items')<>20 then
    raise exception 'Grammar exact-20 claim failed: %',c;
  end if;
  if (c->>'reviewCap')::int<>0 then raise exception 'Cold start must begin with zero Daily reviews before 20 introduced rules: %',c; end if;
  if (c->>'generatedNeeded')::int<>20 then raise exception 'Empty canonical Grammar bank should require 20 generated variants in CI fixture: %',c; end if;
  rid:=(c->>'runId')::uuid;

  gates:=jsonb_build_object(
    'exactlyOneCorrect',true,'correctKeyMatches',true,'linguisticallyValid',true,'conceptPreserved',true,
    'sensePreserved',true,'learnerRequestPreserved',true,'noFactualError',true,'noLexicalGrammarError',true,
    'requiredOptionsValid',true,'explanationMatchesQuestion',true,'explanationMatchesAnswer',true,'noStaleExplanation',true,
    'noAmbiguity',true,'noSecondCorrectOption',true,'intentSpecificTaskValid',true,'questionFamilyValid',true,
    'plausibleDistractors',true,'distractorsNotObvious',true
  );

  select jsonb_agg(jsonb_build_object(
    'slotNo',(e.value->>'slotNo')::int,'ruleKey',e.value->>'ruleKey',
    'plannerDecision',jsonb_build_object('family',e.value->>'preferredQuestionFamily','reason','CI-selected allowed family'),
    'questionFamily',e.value->>'preferredQuestionFamily','question','Grammar CI question '||(e.value->>'slotNo'),
    'optionA','Correct '||(e.value->>'slotNo'),'optionB','Plausible B '||(e.value->>'slotNo'),
    'optionC','Plausible C '||(e.value->>'slotNo'),'optionD','Plausible D '||(e.value->>'slotNo'),
    'correctKey','A','explanation','This explanation teaches the verified atomic rule and why the distractors fail.',
    'difficulty','Moderate','generatorProvider','chatgpt','generatorModel','GPT-5.6 Sol',
    'criticProvider','chatgpt_self_critic','criticModel','GPT-5.6 Sol','repairCount',0,
    'quality',jsonb_build_object('score',92,'decision','PASS','hardGates',gates)
  ) order by (e.value->>'slotNo')::int)
  into good from jsonb_array_elements(c->'items') e(value);

  -- Deliberately omit one required generated slot. The call must fail closed and publish nothing.
  bad:=good-19;
  begin
    perform public.english_grammar_task_ingest(rid,bad);
    raise exception 'Incomplete Grammar ingest unexpectedly succeeded';
  exception when others then
    if sqlerrm='Incomplete Grammar ingest unexpectedly succeeded' then raise; end if;
  end;
  if (select count(*) from english.grammar_daily_items)<>0 then raise exception 'Failed Grammar ingest leaked partial daily membership'; end if;
  if exists(select 1 from english.questions where question_id like 'GRM%') then raise exception 'Failed Grammar ingest leaked canonical questions'; end if;

  result:=public.english_grammar_task_ingest(rid,good);
  if not (result->>'ok')::boolean or (result->>'count')::int<>20 or (result->>'generatedByChatGPT')::int<>20 or (result->>'reused')::int<>0 then
    raise exception 'Grammar exact-20 publication failed: %',result;
  end if;
  if (select count(*) from english.grammar_daily_items where batch_date=(now() at time zone 'Asia/Kolkata')::date)<>20 then
    raise exception 'Grammar publication did not materialize exactly 20 daily rows';
  end if;
  if (select count(*) from english.questions where question_id like 'GRM%' and active)<>20 then
    raise exception 'Grammar publication did not create 20 permanent GRM Question_IDs';
  end if;
  if (select count(*) from english.question_concept_mappings m join english.questions q on q.question_id=m.question_id where q.question_id like 'GRM%' and m.review_status='verified')<>20 then
    raise exception 'Grammar canonical questions are not fully mapped to Central Intelligence concepts';
  end if;
  if not exists(select 1 from english.sources where source_id='GRAMMAR_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD') and import_status='Complete' and question_count=20) then
    raise exception 'Grammar source metadata is not Complete exact-20';
  end if;
  result:=public.english_get_grammar_today();
  if not (result->>'ready')::boolean or (result->>'count')::int<>20 or jsonb_array_length(result->'items')<>20 then
    raise exception 'Grammar app getter is not exact-20 ready: %',result;
  end if;
end $$;

-- Normal attempt stream must incrementally update rule evidence; repeated failure becomes Weak.
do $$
declare uid uuid:='11111111-1111-1111-1111-111111111111'; qid text; rkey text; ev record;
begin
  select question_id,rule_key into qid,rkey from english.grammar_daily_items order by slot_no limit 1;
  insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,module)
    values('grammar-ci-attempt-1',uid,qid,now(),'B',false,11,'grammar_daily');
  insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,module)
    values('grammar-ci-attempt-2',uid,qid,now()+interval '1 second','C',false,9,'grammar_daily');
  select * into ev from english.grammar_rule_evidence where user_id=uid and rule_key=rkey;
  if ev.attempts<>2 or ev.wrong<>2 or ev.recent_failures<2 or ev.coverage_state<>'weak' then
    raise exception 'Grammar adaptive evidence did not become Weak after repeated failures: attempts %, wrong %, recent %, state %',ev.attempts,ev.wrong,ev.recent_failures,ev.coverage_state;
  end if;
  if ev.next_review is null or ev.next_review>now()+interval '2 days' then raise exception 'Weak Grammar rule was not scheduled soon enough'; end if;
end $$;

select 'English Grammar Stage 1 PostgreSQL behavior contracts passed' result;

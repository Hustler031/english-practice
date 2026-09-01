-- English V2 concept-centric intelligence foundation.
-- Non-destructive: adds additive tables, mappings, evidence and RPCs only.
create extension if not exists pgcrypto;

create table if not exists english.concepts (
  concept_id text primary key,
  domain text not null default 'English',
  skill_family text not null default 'Unclassified',
  name text not null,
  description text,
  confidence text not null default 'medium' check (confidence in ('high','medium','low')),
  exam_relevance text not null default 'medium' check (exam_relevance in ('high','medium','low')),
  priority_score numeric not null default 0,
  coverage_state text not null default 'unseen' check (coverage_state in ('unseen','seen','secure','exam_ready','deprioritized')),
  is_atomic boolean not null default true,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists english.question_concept_mappings (
  question_id text primary key references english.questions(question_id) on delete restrict,
  concept_id text not null references english.concepts(concept_id) on delete restrict,
  family_id text,
  mapping_confidence numeric not null default 0.5 check (mapping_confidence between 0 and 1),
  mapping_method text not null default 'deterministic_metadata',
  model text,
  embedding jsonb,
  review_status text not null default 'mapped' check (review_status in ('mapped','needs_review','unresolved','verified')),
  relation_type text not null default 'primary' check (relation_type in ('primary','related','variant')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists english_qcm_concept_idx on english.question_concept_mappings(concept_id);
create index if not exists english_qcm_review_idx on english.question_concept_mappings(review_status);

create table if not exists english.concept_relationships (
  concept_id text not null references english.concepts(concept_id) on delete restrict,
  related_concept_id text not null references english.concepts(concept_id) on delete restrict,
  relationship text not null check (relationship in ('family','confusion','related','duplicate_candidate','transfer')),
  confidence numeric not null default 0.5 check (confidence between 0 and 1),
  method text not null default 'deterministic_metadata',
  model text,
  created_at timestamptz not null default now(),
  primary key (concept_id, related_concept_id, relationship),
  check (concept_id <> related_concept_id)
);

create table if not exists english.concept_evidence (
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id text not null references english.concepts(concept_id) on delete restrict,
  attempts integer not null default 0,
  correct integer not null default 0,
  wrong integer not null default 0,
  guessed integer not null default 0,
  distinct_questions integer not null default 0,
  distinct_variants integer not null default 0,
  transfer_successes integer not null default 0,
  delayed_successes integer not null default 0,
  recent_failures integer not null default 0,
  confusion_count integer not null default 0,
  confidence_score numeric not null default 0,
  coverage_state text not null default 'unseen' check (coverage_state in ('unseen','seen','secure','exam_ready','weak','retention_risk')),
  next_review timestamptz,
  last_attempt_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, concept_id)
);

create index if not exists english_concept_evidence_due_idx
  on english.concept_evidence(user_id, next_review)
  where next_review is not null;

create table if not exists english.ai_interventions (
  intervention_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  trigger text not null,
  request_type text not null,
  question_id text references english.questions(question_id) on delete set null,
  concept_id text references english.concepts(concept_id) on delete set null,
  session_id text,
  model text,
  diagnosis jsonb not null default '{}'::jsonb,
  confidence numeric,
  recommended_action text,
  action_taken text,
  input_tokens integer,
  output_tokens integer,
  reasoning_tokens integer,
  status text not null default 'completed' check (status in ('queued','completed','failed')),
  created_at timestamptz not null default now()
);

create index if not exists english_ai_interventions_user_idx
  on english.ai_interventions(user_id, created_at desc);

create table if not exists english.learner_confidence_signals (
  signal_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete restrict,
  attempt_id text references english.attempts(attempt_id) on delete set null,
  signal text not null check (signal in ('guessed','certain','uncertain')),
  reversible boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists english_confidence_signals_user_question_idx
  on english.learner_confidence_signals(user_id, question_id, created_at desc);

create table if not exists english.question_quality_flags (
  question_id text primary key references english.questions(question_id) on delete restrict,
  status text not null default 'valid' check (status in ('valid','needs_review','potentially_ambiguous','quarantined','repaired')),
  flags jsonb not null default '[]'::jsonb,
  provenance jsonb not null default '{}'::jsonb,
  updated_by text not null default 'system',
  updated_at timestamptz not null default now()
);

alter table english.concepts enable row level security;
alter table english.question_concept_mappings enable row level security;
alter table english.concept_relationships enable row level security;
alter table english.concept_evidence enable row level security;
alter table english.ai_interventions enable row level security;
alter table english.learner_confidence_signals enable row level security;
alter table english.question_quality_flags enable row level security;

drop policy if exists english_concepts_read on english.concepts;
create policy english_concepts_read on english.concepts for select to authenticated using (active);

drop policy if exists english_qcm_read on english.question_concept_mappings;
create policy english_qcm_read on english.question_concept_mappings for select to authenticated using (true);

drop policy if exists english_relationships_read on english.concept_relationships;
create policy english_relationships_read on english.concept_relationships for select to authenticated using (true);

drop policy if exists english_concept_evidence_owner on english.concept_evidence;
create policy english_concept_evidence_owner on english.concept_evidence for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists english_ai_interventions_owner on english.ai_interventions;
create policy english_ai_interventions_owner on english.ai_interventions for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists english_confidence_signals_owner on english.learner_confidence_signals;
create policy english_confidence_signals_owner on english.learner_confidence_signals for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists english_quality_read on english.question_quality_flags;
create policy english_quality_read on english.question_quality_flags for select to authenticated using (true);

-- Deterministic first-pass mapping. Existing question concept ids win; otherwise
-- topic/subtopic/word form a conservative atomic key. No historical rows are changed.
with src as (
  select distinct on (coalesce(nullif(trim(q.concept_id), ''), 'C_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified') || '|' || coalesce(q.word,''))))))
    coalesce(nullif(trim(q.concept_id), ''), 'C_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified') || '|' || coalesce(q.word,''))))) as concept_id,
    'English' as domain,
    coalesce(nullif(trim(q.topic), ''), 'Unclassified') as skill_family,
    coalesce(nullif(trim(q.subtopic), ''), nullif(trim(q.word), ''), nullif(trim(q.topic), ''), 'Unclassified concept') as name,
    case when nullif(trim(q.concept_id), '') is not null then 'high' else 'medium' end as confidence,
    case when lower(coalesce(q.topic,'')) ~ '(grammar|vocab|phrasal|idiom|spelling|preposition|one word|synonym|antonym)' then 'high' else 'medium' end as exam_relevance,
    jsonb_build_object('initial_source','english.questions','question_type',q.question_type) as metadata
  from english.questions q
  where coalesce(q.active,true)
  order by coalesce(nullif(trim(q.concept_id), ''), 'C_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified') || '|' || coalesce(q.word,''))))), q.question_id
)
insert into english.concepts (concept_id, domain, skill_family, name, confidence, exam_relevance, metadata)
select concept_id,domain,skill_family,name,confidence,exam_relevance,metadata from src
on conflict (concept_id) do update set updated_at=now();

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
insert into english.concepts (concept_id, domain, skill_family, name, confidence, exam_relevance, metadata)
select distinct
  coalesce(nullif(trim(q.concept_id), ''), 'C_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified') || '|' || coalesce(q.word,''))))),
  'English',
  coalesce(nullif(trim(q.topic), ''), 'Unclassified'),
  coalesce(nullif(trim(q.subtopic), ''), nullif(trim(q.word), ''), nullif(trim(q.topic), ''), 'Unclassified concept'),
  case when nullif(trim(q.concept_id), '') is not null then 'high' else 'medium' end,
  case when lower(coalesce(q.topic,'')) ~ '(grammar|vocab|phrasal|idiom|spelling|preposition|one word|synonym|antonym)' then 'high' else 'medium' end,
  jsonb_build_object('initial_source','english.questions','question_type',q.question_type)
from english.questions q
where coalesce(q.active,true)
on conflict (concept_id) do update set updated_at=now();

with src as (
  select q.question_id,
    coalesce(nullif(trim(q.concept_id), ''), 'C_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified') || '|' || coalesce(q.word,''))))) as concept_id,
    'F_' || md5(lower(trim(coalesce(q.topic,'English') || '|' || coalesce(q.subtopic,q.question_type,'Unclassified')))) as family_id,
    case when nullif(trim(q.concept_id), '') is not null then 0.95 else 0.78 end as mapping_confidence,
    case when nullif(trim(q.concept_id), '') is not null then 'existing_concept_id' else 'deterministic_metadata' end as mapping_method,
    case when nullif(trim(q.concept_id), '') is not null then 'verified' else 'mapped' end as review_status
  from english.questions q
  where coalesce(q.active,true)
)
insert into english.question_concept_mappings
  (question_id, concept_id, family_id, mapping_confidence, mapping_method, review_status)
select question_id, concept_id, family_id, mapping_confidence, mapping_method, review_status
from src
on conflict (question_id) do nothing;

-- Keep the legacy question-level field compatible for existing callers.
update english.questions q
set concept_id = m.concept_id, updated_at = now()
from english.question_concept_mappings m
where m.question_id=q.question_id and (q.concept_id is null or trim(q.concept_id)='');

create or replace function english.recompute_concept_evidence(p_user_id uuid, p_concept_id text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, english
as $$
declare r record; score numeric;
begin
  if p_user_id is null or p_concept_id is null then return; end if;
  select
    count(*)::int as attempts,
    count(*) filter (where a.correct is true)::int as correct,
    count(*) filter (where a.correct is false)::int as wrong,
    count(distinct a.question_id)::int as distinct_questions,
    count(distinct coalesce(a.module,'practice'))::int as distinct_variants,
    count(*) filter (where a.correct is true and a.attempted_at < now() - interval '3 days')::int as delayed_successes,
    count(*) filter (where a.correct is false and a.attempted_at > now() - interval '7 days')::int as recent_failures,
    max(a.attempted_at) as last_attempt_at
  into r
  from english.attempts a
  join english.question_concept_mappings m on m.question_id=a.question_id
  where a.user_id=p_user_id and m.concept_id=p_concept_id;

  score := greatest(0, least(100,
    coalesce(r.correct,0)*12
    + coalesce(r.delayed_successes,0)*8
    + least(coalesce(r.distinct_questions,0),4)*5
    - coalesce(r.wrong,0)*14
    - coalesce(r.recent_failures,0)*10
  ));

  insert into english.concept_evidence(user_id,concept_id,attempts,correct,wrong,distinct_questions,distinct_variants,delayed_successes,recent_failures,confidence_score,coverage_state,last_attempt_at,updated_at)
  values (p_user_id,p_concept_id,coalesce(r.attempts,0),coalesce(r.correct,0),coalesce(r.wrong,0),coalesce(r.distinct_questions,0),coalesce(r.distinct_variants,0),coalesce(r.delayed_successes,0),coalesce(r.recent_failures,0),score,
    case when score >= 78 and coalesce(r.delayed_successes,0) >= 1 and coalesce(r.distinct_questions,0) >= 2 then 'exam_ready'
         when score >= 55 and coalesce(r.distinct_questions,0) >= 2 then 'secure'
         when coalesce(r.attempts,0) > 0 and coalesce(r.recent_failures,0) > 0 then 'retention_risk'
         when coalesce(r.attempts,0) > 0 then 'seen' else 'unseen' end,
    r.last_attempt_at,now())
  on conflict (user_id,concept_id) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,
    distinct_questions=excluded.distinct_questions,distinct_variants=excluded.distinct_variants,
    delayed_successes=excluded.delayed_successes,recent_failures=excluded.recent_failures,
    confidence_score=excluded.confidence_score,coverage_state=excluded.coverage_state,
    last_attempt_at=excluded.last_attempt_at,updated_at=now();
end;
$$;
revoke all on function english.recompute_concept_evidence(uuid,text) from public;

create or replace function english.on_attempt_concept_evidence()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, english
as $$
declare cid text;
begin
  select m.concept_id into cid from english.question_concept_mappings m where m.question_id=NEW.question_id;
  if cid is not null then perform english.recompute_concept_evidence(NEW.user_id,cid); end if;
  return NEW;
end;
$$;
revoke all on function english.on_attempt_concept_evidence() from public;
drop trigger if exists english_attempt_concept_evidence on english.attempts;
create trigger english_attempt_concept_evidence after insert on english.attempts
for each row execute function english.on_attempt_concept_evidence();

-- Backfill user evidence without deleting or rewriting attempts.
do $$
declare u record; c record;
begin
  for u in select distinct user_id from english.attempts where user_id is not null loop
    for c in select distinct m.concept_id from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id where a.user_id=u.user_id loop
      perform english.recompute_concept_evidence(u.user_id,c.concept_id);
    end loop;
  end loop;
end $$;

create or replace function english.english_get_concept_intelligence_summary()
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, english
as $$
declare uid uuid := (select auth.uid()); outv jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;
  select jsonb_build_object(
    'concepts', (select count(*) from english.concepts where active),
    'mapped_questions', (select count(*) from english.question_concept_mappings),
    'unresolved_mappings', (select count(*) from english.question_concept_mappings where review_status='unresolved'),
    'needs_review', (select count(*) from english.question_concept_mappings where review_status='needs_review'),
    'seen', (select count(*) from english.concept_evidence where user_id=uid and coverage_state='seen'),
    'secure', (select count(*) from english.concept_evidence where user_id=uid and coverage_state='secure'),
    'exam_ready', (select count(*) from english.concept_evidence where user_id=uid and coverage_state='exam_ready'),
    'weak', (select count(*) from english.concept_evidence where user_id=uid and coverage_state in ('weak','retention_risk')),
    'retention_risk', (select count(*) from english.concept_evidence where user_id=uid and coverage_state='retention_risk')
  ) into outv;
  return outv;
end;
$$;
grant execute on function english.english_get_concept_intelligence_summary() to authenticated;

create or replace function english.english_record_guess(p_question_id text, p_attempt_id text default null)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, english
as $$
declare uid uuid := (select auth.uid()); cid text;
begin
  if uid is null then raise exception 'authentication required'; end if;
  select m.concept_id into cid from english.question_concept_mappings m where m.question_id=p_question_id;
  insert into english.learner_confidence_signals(user_id,question_id,attempt_id,signal)
  values(uid,p_question_id,p_attempt_id,'guessed');
  if cid is not null then
    update english.concept_evidence
    set guessed=guessed+1,
        confidence_score=greatest(0,confidence_score-10),
        coverage_state=case when coverage_state='exam_ready' then 'retention_risk' else coverage_state end,
        updated_at=now()
    where user_id=uid and concept_id=cid;
  end if;
  return jsonb_build_object('ok',true,'signal','guessed','concept_id',cid);
end;
$$;
grant execute on function english.english_record_guess(text,text) to authenticated;

create or replace function english.english_get_concept_intelligence_detail(p_kind text default 'all')
returns jsonb
language sql
security invoker
set search_path = pg_catalog, english
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.priority_score desc, x.confidence_score asc), '[]'::jsonb)
  from (
    select c.concept_id,c.domain,c.skill_family,c.name,c.exam_relevance,c.priority_score,
      coalesce(e.coverage_state,'unseen') coverage_state,coalesce(e.confidence_score,0) confidence_score,
      coalesce(e.attempts,0) attempts,coalesce(e.wrong,0) wrong,e.next_review
    from english.concepts c
    left join english.concept_evidence e on e.concept_id=c.concept_id and e.user_id=(select auth.uid())
    where c.active and (
      p_kind='all' or (p_kind='weak' and coalesce(e.coverage_state,'unseen') in ('weak','retention_risk'))
      or (p_kind='retention' and coalesce(e.coverage_state,'unseen')='retention_risk')
      or (p_kind='coverage' and coalesce(e.coverage_state,'unseen') in ('unseen','seen','secure','exam_ready'))
    )
  ) x;
$$;
grant execute on function english.english_get_concept_intelligence_detail(text) to authenticated;

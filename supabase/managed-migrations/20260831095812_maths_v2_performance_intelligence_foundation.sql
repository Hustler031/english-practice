-- Maths V2 performance intelligence foundation.
-- Additive only: canonical Maths content/history/session tables are preserved.

create table if not exists maths.concept_catalog (
  concept_id text primary key,
  concept_name text not null,
  chapter text,
  topic text,
  subtopic text,
  formula_ref text,
  active boolean not null default true,
  source text not null default 'academic_metadata',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists maths.question_concepts (
  question_id text not null references maths.questions(question_id) on delete restrict,
  concept_id text not null references maths.concept_catalog(concept_id) on delete restrict,
  source text not null default 'academic_metadata',
  confidence numeric not null default 1 check (confidence between 0 and 1),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (question_id, concept_id)
);

create table if not exists maths.family_catalog (
  family_id text primary key,
  family_name text not null,
  chapter text,
  topic text,
  subtopic text,
  recognition_trigger text,
  common_method text,
  expected_complexity text,
  active boolean not null default true,
  source text not null default 'template_group',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists maths.question_families (
  question_id text primary key references maths.questions(question_id) on delete restrict,
  family_id text not null references maths.family_catalog(family_id) on delete restrict,
  source text not null default 'template_group',
  confidence numeric not null default 1 check (confidence between 0 and 1),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists maths.performance_evidence (
  evidence_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text references maths.questions(question_id) on delete restrict,
  attempt_id text,
  session_id text,
  evidence_source text not null,
  inferred_reason text check (inferred_reason is null or inferred_reason in ('CAL','APP','CON','FOR','SILLY','TIME')),
  user_confirmed_reason text check (user_confirmed_reason is null or user_confirmed_reason in ('CAL','APP','CON','FOR','SILLY','TIME')),
  final_reason text generated always as (coalesce(user_confirmed_reason,inferred_reason)) stored,
  inference_confidence numeric check (inference_confidence is null or inference_confidence between 0 and 1),
  correctness text check (correctness is null or correctness in ('correct','wrong','seen','unattempted')),
  response_sec numeric,
  baseline_sec numeric,
  timing_class text check (timing_class is null or timing_class in ('correct_fast','correct_normal','correct_slow','wrong_fast','wrong_normal','wrong_slow','seen')),
  slow_correct boolean not null default false,
  confidence_response text check (confidence_response is null or confidence_response in ('sure','50_50','guess')),
  selection_decision text check (selection_decision is null or selection_decision in ('SOLVE','LATER','SKIP')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists maths_performance_attempt_unique
  on maths.performance_evidence(attempt_id) where attempt_id is not null;
create index if not exists maths_performance_user_question_time_idx
  on maths.performance_evidence(user_id,question_id,created_at desc);
create index if not exists maths_performance_user_reason_time_idx
  on maths.performance_evidence(user_id,final_reason,created_at desc);
create index if not exists maths_performance_user_session_idx
  on maths.performance_evidence(user_id,session_id,created_at);

create table if not exists maths.concept_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id text not null references maths.concept_catalog(concept_id) on delete restrict,
  evidence_count integer not null default 0,
  graded_count integer not null default 0,
  correct_count integer not null default 0,
  wrong_count integer not null default 0,
  slow_correct_count integer not null default 0,
  recent_accuracy numeric,
  recent_median_sec numeric,
  knowledge_score numeric,
  performance_score numeric,
  cold_confirmed boolean not null default false,
  last_negative_at timestamptz,
  last_positive_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id,concept_id)
);

create table if not exists maths.family_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  family_id text not null references maths.family_catalog(family_id) on delete restrict,
  evidence_count integer not null default 0,
  graded_count integer not null default 0,
  correct_count integer not null default 0,
  wrong_count integer not null default 0,
  slow_correct_count integer not null default 0,
  recent_accuracy numeric,
  recent_median_sec numeric,
  personal_baseline_sec numeric,
  persistent_weak boolean not null default false,
  cold_confirmed boolean not null default false,
  last_negative_at timestamptz,
  last_positive_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id,family_id)
);

create index if not exists maths_family_state_user_weak_idx
  on maths.family_state(user_id,persistent_weak,updated_at desc);

create table if not exists maths.repair_queue (
  repair_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  scope_type text not null check (scope_type in ('question','concept','family','skill')),
  scope_id text not null,
  question_id text references maths.questions(question_id) on delete restrict,
  reason text check (reason is null or reason in ('CAL','APP','CON','FOR','SILLY','TIME')),
  priority text not null check (priority in ('P0','P1','P2','MAINTENANCE')),
  status text not null default 'open' check (status in ('open','in_progress','waiting_confirmation','resolved','dismissed')),
  priority_score numeric not null default 0,
  source_evidence_id uuid references maths.performance_evidence(evidence_id) on delete set null,
  due_at timestamptz not null default now(),
  repair_attempts integer not null default 0,
  repair_successes integer not null default 0,
  last_repair_at timestamptz,
  next_confirmation_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists maths_repair_user_open_idx
  on maths.repair_queue(user_id,status,due_at,priority_score desc);
create index if not exists maths_repair_scope_idx
  on maths.repair_queue(user_id,scope_type,scope_id,status);

create table if not exists maths.selection_evidence (
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text not null,
  question_id text not null references maths.questions(question_id) on delete restrict,
  decision text not null check (decision in ('SOLVE','LATER','SKIP')),
  decision_sec numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id,session_id,question_id)
);
create index if not exists maths_selection_user_time_idx
  on maths.selection_evidence(user_id,created_at desc);

create table if not exists maths.approach_cards (
  card_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  family_id text references maths.family_catalog(family_id) on delete restrict,
  concept_id text references maths.concept_catalog(concept_id) on delete restrict,
  pattern text not null,
  trigger_text text,
  first_thought text,
  fast_method text,
  trap text,
  source text not null default 'personal',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists maths_approach_user_active_idx
  on maths.approach_cards(user_id,active,updated_at desc);

create table if not exists maths.approach_recall_evidence (
  recall_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  family_id text not null references maths.family_catalog(family_id) on delete restrict,
  got_approach boolean not null,
  recognition_sec numeric,
  created_at timestamptz not null default now()
);
create index if not exists maths_approach_recall_user_family_idx
  on maths.approach_recall_evidence(user_id,family_id,created_at desc);

create table if not exists maths.external_mock_staging (
  stage_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source_label text,
  source_ref text,
  extracted_payload jsonb not null,
  normalized_prompt text,
  matched_question_id text references maths.questions(question_id) on delete restrict,
  match_confidence numeric check (match_confidence is null or match_confidence between 0 and 1),
  match_method text,
  review_status text not null default 'pending' check (review_status in ('pending','matched','needs_review','resolved','rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists maths_external_mock_user_status_idx
  on maths.external_mock_staging(user_id,review_status,created_at desc);

alter table maths.concept_catalog enable row level security;
alter table maths.question_concepts enable row level security;
alter table maths.family_catalog enable row level security;
alter table maths.question_families enable row level security;
alter table maths.performance_evidence enable row level security;
alter table maths.concept_state enable row level security;
alter table maths.family_state enable row level security;
alter table maths.repair_queue enable row level security;
alter table maths.selection_evidence enable row level security;
alter table maths.approach_cards enable row level security;
alter table maths.approach_recall_evidence enable row level security;
alter table maths.external_mock_staging enable row level security;

revoke all on table maths.concept_catalog,maths.question_concepts,maths.family_catalog,maths.question_families,
  maths.performance_evidence,maths.concept_state,maths.family_state,maths.repair_queue,maths.selection_evidence,
  maths.approach_cards,maths.approach_recall_evidence,maths.external_mock_staging
from public,anon,authenticated;

create or replace function maths._concept_key(p_chapter text,p_topic text,p_subtopic text)
returns text language sql immutable set search_path='pg_catalog','maths' as $$
select 'C_'||substr(md5(lower(regexp_replace(coalesce(nullif(btrim(p_chapter),''),'general'),'\s+',' ','g'))||'|'||lower(regexp_replace(coalesce(nullif(btrim(p_topic),''),'general'),'\s+',' ','g'))||'|'||lower(regexp_replace(coalesce(nullif(btrim(p_subtopic),''),nullif(btrim(p_topic),''),'general'),'\s+',' ','g'))),1,20)
$$;

insert into maths.concept_catalog(concept_id,concept_name,chapter,topic,subtopic,source)
select distinct on (maths._concept_key(q.chapter,q.topic,q.subtopic)) maths._concept_key(q.chapter,q.topic,q.subtopic),coalesce(nullif(btrim(q.subtopic),''),nullif(btrim(q.topic),''),nullif(btrim(q.chapter),''),'General'),q.chapter,q.topic,q.subtopic,'academic_metadata'
from maths.runtime_questions q where q.runtime_active and q.academic_eligible order by maths._concept_key(q.chapter,q.topic,q.subtopic),q.question_id
on conflict (concept_id) do update set concept_name=excluded.concept_name,chapter=coalesce(maths.concept_catalog.chapter,excluded.chapter),topic=coalesce(maths.concept_catalog.topic,excluded.topic),subtopic=coalesce(maths.concept_catalog.subtopic,excluded.subtopic),active=true,updated_at=now();

insert into maths.question_concepts(question_id,concept_id,source,confidence,active)
select q.question_id,maths._concept_key(q.chapter,q.topic,q.subtopic),'academic_metadata',1,true from maths.runtime_questions q where q.runtime_active and q.academic_eligible
on conflict (question_id,concept_id) do update set active=true,confidence=greatest(maths.question_concepts.confidence,excluded.confidence);

insert into maths.family_catalog(family_id,family_name,chapter,topic,subtopic,recognition_trigger,source)
select q.template_group,q.template_group,min(nullif(btrim(q.chapter),'')),min(nullif(btrim(q.topic),'')),min(nullif(btrim(q.subtopic),'')),max(nullif(btrim(q.memory_cue),'')),'template_group'
from maths.runtime_questions q where q.runtime_active and nullif(btrim(q.template_group),'') is not null group by q.template_group
on conflict (family_id) do update set family_name=excluded.family_name,chapter=coalesce(maths.family_catalog.chapter,excluded.chapter),topic=coalesce(maths.family_catalog.topic,excluded.topic),subtopic=coalesce(maths.family_catalog.subtopic,excluded.subtopic),recognition_trigger=coalesce(maths.family_catalog.recognition_trigger,excluded.recognition_trigger),active=true,updated_at=now();

insert into maths.question_families(question_id,family_id,source,confidence,active)
select q.question_id,q.template_group,'template_group',1,true from maths.runtime_questions q where q.runtime_active and nullif(btrim(q.template_group),'') is not null
on conflict (question_id) do update set family_id=excluded.family_id,active=true,confidence=greatest(maths.question_families.confidence,excluded.confidence);

create or replace function maths._baseline_sec(p_uid uuid,p_question_id text,p_before timestamptz default now()) returns numeric language plpgsql stable security definer set search_path='pg_catalog','public','maths' as $$
declare family_ text; chapter_ text; fallback_ numeric:=30; n_ int; med_ numeric;
begin
select q.template_group,q.chapter,case when maths._norm(q.chapter) in ('geometry','coordinate geometry') or length(coalesce(q.prompt,''))>=220 then 45 else 30 end into family_,chapter_,fallback_ from maths.runtime_questions q where q.question_id=p_question_id;
select count(*),percentile_cont(.5) within group(order by response_sec) into n_,med_ from (select a.response_sec from maths.attempts a where a.user_id=p_uid and a.question_id=p_question_id and a.attempted_at<p_before and a.response_sec>0 and lower(coalesce(a.result,'')) in ('correct','wrong') order by a.attempted_at desc limit 12)x;
if n_>=3 and med_ is not null then return greatest(3,med_); end if;
if nullif(btrim(family_),'') is not null then select count(*),percentile_cont(.5) within group(order by response_sec) into n_,med_ from (select a.response_sec from maths.attempts a join maths.runtime_questions q on q.question_id=a.question_id where a.user_id=p_uid and q.template_group=family_ and a.attempted_at<p_before and a.response_sec>0 and lower(coalesce(a.result,'')) in ('correct','wrong') order by a.attempted_at desc limit 40)x; if n_>=5 and med_ is not null then return greatest(3,med_); end if; end if;
select count(*),percentile_cont(.5) within group(order by response_sec) into n_,med_ from (select a.response_sec from maths.attempts a join maths.runtime_questions q on q.question_id=a.question_id where a.user_id=p_uid and maths._norm(q.chapter)=maths._norm(chapter_) and a.attempted_at<p_before and a.response_sec>0 and lower(coalesce(a.result,'')) in ('correct','wrong') order by a.attempted_at desc limit 60)x;
if n_>=8 and med_ is not null then return greatest(3,med_); end if; return fallback_; end $$;

create or replace function maths._timing_class(p_result text,p_response numeric,p_baseline numeric) returns text language sql immutable as $$select case when lower(coalesce(p_result,''))='seen' then 'seen' when lower(coalesce(p_result,''))='correct' and coalesce(p_response,0)>coalesce(p_baseline,30)*1.25 then 'correct_slow' when lower(coalesce(p_result,''))='correct' and coalesce(p_response,0)>0 and p_response<=coalesce(p_baseline,30)*.80 then 'correct_fast' when lower(coalesce(p_result,''))='correct' then 'correct_normal' when lower(coalesce(p_result,''))='wrong' and coalesce(p_response,0)>coalesce(p_baseline,30)*1.50 then 'wrong_slow' when lower(coalesce(p_result,''))='wrong' and coalesce(p_response,0)>0 and p_response<=coalesce(p_baseline,30)*.75 then 'wrong_fast' when lower(coalesce(p_result,''))='wrong' then 'wrong_normal' else null end$$;

create or replace function maths._refresh_concept_state(p_uid uuid,p_concept_id text) returns void language plpgsql security definer set search_path='pg_catalog','public','maths' as $$
declare ev int; gr int; cor int; wr int; sl int; acc numeric; med numeric; neg timestamptz; pos timestamptz; cold boolean;
begin
with recent as (select e.* from maths.performance_evidence e join maths.question_concepts qc on qc.question_id=e.question_id and qc.concept_id=p_concept_id and qc.active where e.user_id=p_uid order by e.created_at desc limit 30)
select count(*),count(*)filter(where correctness in('correct','wrong')),count(*)filter(where correctness='correct'),count(*)filter(where correctness='wrong'),count(*)filter(where slow_correct),count(*)filter(where correctness='correct')::numeric/nullif(count(*)filter(where correctness in('correct','wrong')),0),percentile_cont(.5) within group(order by response_sec)filter(where response_sec>0 and correctness in('correct','wrong')),max(created_at)filter(where correctness='wrong' or slow_correct),max(created_at)filter(where correctness='correct' and not slow_correct) into ev,gr,cor,wr,sl,acc,med,neg,pos from recent;
select exists(select 1 from maths.performance_evidence good join maths.question_concepts qcg on qcg.question_id=good.question_id and qcg.concept_id=p_concept_id and qcg.active where good.user_id=p_uid and good.correctness='correct' and not good.slow_correct and exists(select 1 from maths.performance_evidence bad join maths.question_concepts qcb on qcb.question_id=bad.question_id and qcb.concept_id=p_concept_id and qcb.active where bad.user_id=p_uid and (bad.correctness='wrong' or bad.slow_correct) and bad.created_at<=good.created_at-interval '20 hours')) into cold;
insert into maths.concept_state(user_id,concept_id,evidence_count,graded_count,correct_count,wrong_count,slow_correct_count,recent_accuracy,recent_median_sec,knowledge_score,performance_score,cold_confirmed,last_negative_at,last_positive_at,updated_at)
values(p_uid,p_concept_id,coalesce(ev,0),coalesce(gr,0),coalesce(cor,0),coalesce(wr,0),coalesce(sl,0),acc,med,case when gr>0 then round(least(100,greatest(0,100*acc+case when cold then 8 else 0 end)),1) end,case when gr>0 then round(least(100,greatest(0,100*(cor-sl)::numeric/gr)),1) end,coalesce(cold,false),neg,pos,now())
on conflict(user_id,concept_id) do update set evidence_count=excluded.evidence_count,graded_count=excluded.graded_count,correct_count=excluded.correct_count,wrong_count=excluded.wrong_count,slow_correct_count=excluded.slow_correct_count,recent_accuracy=excluded.recent_accuracy,recent_median_sec=excluded.recent_median_sec,knowledge_score=excluded.knowledge_score,performance_score=excluded.performance_score,cold_confirmed=excluded.cold_confirmed,last_negative_at=excluded.last_negative_at,last_positive_at=excluded.last_positive_at,updated_at=now(); end $$;

create or replace function maths._refresh_family_state(p_uid uuid,p_family_id text) returns void language plpgsql security definer set search_path='pg_catalog','public','maths' as $$
declare ev int;gr int;cor int;wr int;sl int;acc numeric;med numeric;neg timestamptz;pos timestamptz;recent_bad int;recent_wrong int;persistent boolean;cold boolean;
begin
with recent as(select e.* from maths.performance_evidence e join maths.question_families qf on qf.question_id=e.question_id and qf.family_id=p_family_id and qf.active where e.user_id=p_uid order by e.created_at desc limit 30)
select count(*),count(*)filter(where correctness in('correct','wrong')),count(*)filter(where correctness='correct'),count(*)filter(where correctness='wrong'),count(*)filter(where slow_correct),count(*)filter(where correctness='correct')::numeric/nullif(count(*)filter(where correctness in('correct','wrong')),0),percentile_cont(.5) within group(order by response_sec)filter(where response_sec>0 and correctness in('correct','wrong')),max(created_at)filter(where correctness='wrong' or slow_correct),max(created_at)filter(where correctness='correct' and not slow_correct) into ev,gr,cor,wr,sl,acc,med,neg,pos from recent;
with last5 as(select e.correctness,e.slow_correct from maths.performance_evidence e join maths.question_families qf on qf.question_id=e.question_id and qf.family_id=p_family_id and qf.active where e.user_id=p_uid and e.correctness in('correct','wrong') order by e.created_at desc limit 5) select count(*)filter(where correctness='wrong' or slow_correct),count(*)filter(where correctness='wrong') into recent_bad,recent_wrong from last5;
persistent:=coalesce(recent_wrong,0)>=2 and coalesce(recent_bad,0)>=3;
select exists(select 1 from maths.performance_evidence good join maths.question_families qfg on qfg.question_id=good.question_id and qfg.family_id=p_family_id and qfg.active where good.user_id=p_uid and good.correctness='correct' and not good.slow_correct and exists(select 1 from maths.performance_evidence bad join maths.question_families qfb on qfb.question_id=bad.question_id and qfb.family_id=p_family_id and qfb.active where bad.user_id=p_uid and (bad.correctness='wrong' or bad.slow_correct) and bad.created_at<=good.created_at-interval '20 hours')) into cold;
insert into maths.family_state(user_id,family_id,evidence_count,graded_count,correct_count,wrong_count,slow_correct_count,recent_accuracy,recent_median_sec,personal_baseline_sec,persistent_weak,cold_confirmed,last_negative_at,last_positive_at,updated_at)
values(p_uid,p_family_id,coalesce(ev,0),coalesce(gr,0),coalesce(cor,0),coalesce(wr,0),coalesce(sl,0),acc,med,med,coalesce(persistent,false),coalesce(cold,false),neg,pos,now())
on conflict(user_id,family_id) do update set evidence_count=excluded.evidence_count,graded_count=excluded.graded_count,correct_count=excluded.correct_count,wrong_count=excluded.wrong_count,slow_correct_count=excluded.slow_correct_count,recent_accuracy=excluded.recent_accuracy,recent_median_sec=excluded.recent_median_sec,personal_baseline_sec=excluded.personal_baseline_sec,persistent_weak=excluded.persistent_weak,cold_confirmed=excluded.cold_confirmed,last_negative_at=excluded.last_negative_at,last_positive_at=excluded.last_positive_at,updated_at=now(); end $$;

create or replace function maths._sync_repair_from_evidence(p_evidence_id uuid) returns void language plpgsql security definer set search_path='pg_catalog','public','maths' as $$
declare e maths.performance_evidence%rowtype;family_ text;concept_ text;scope_type_ text;scope_id_ text;priority_ text;score_ numeric;persistent_ boolean:=false;
begin select * into e from maths.performance_evidence where evidence_id=p_evidence_id;if not found or e.question_id is null then return;end if;select family_id into family_ from maths.question_families where question_id=e.question_id and active limit 1;select concept_id into concept_ from maths.question_concepts where question_id=e.question_id and active order by confidence desc limit 1;if family_ is not null then scope_type_:='family';scope_id_:=family_;select coalesce(persistent_weak,false) into persistent_ from maths.family_state where user_id=e.user_id and family_id=family_;elsif concept_ is not null then scope_type_:='concept';scope_id_:=concept_;else scope_type_:='question';scope_id_:=e.question_id;end if;
if e.correctness='correct' and not e.slow_correct then update maths.repair_queue set repair_successes=repair_successes+1,status=case when due_at<=e.created_at and e.created_at>=created_at+interval '20 hours' then 'resolved' else 'waiting_confirmation' end,next_confirmation_at=case when e.created_at<created_at+interval '20 hours' then created_at+interval '20 hours' else next_confirmation_at end,updated_at=now() where user_id=e.user_id and scope_type=scope_type_ and scope_id=scope_id_ and status in('open','in_progress','waiting_confirmation');return;end if;if e.correctness<>'wrong' and not e.slow_correct then return;end if;
priority_:=case when e.correctness='wrong' and e.confidence_response='sure' then 'P0' when persistent_ then 'P0' when e.correctness='wrong' then 'P1' when e.slow_correct then 'P1' else 'P2' end;score_:=case priority_ when 'P0' then 100 when 'P1' then 70 when 'P2' then 40 else 20 end+case when e.correctness='wrong' then 15 else 0 end+case when e.slow_correct then 8 else 0 end+case when persistent_ then 20 else 0 end;update maths.repair_queue set status='dismissed',updated_at=now() where user_id=e.user_id and scope_type=scope_type_ and scope_id=scope_id_ and status='open';insert into maths.repair_queue(user_id,scope_type,scope_id,question_id,reason,priority,status,priority_score,source_evidence_id,due_at,next_confirmation_at,metadata)values(e.user_id,scope_type_,scope_id_,e.question_id,e.final_reason,priority_,'open',score_,e.evidence_id,case when priority_='P0' then now() when priority_='P1' then now()+interval '18 hours' else now()+interval '3 days' end,case when priority_='P0' then now()+interval '20 hours' else now()+interval '2 days' end,jsonb_build_object('timingClass',e.timing_class,'slowCorrect',e.slow_correct,'diagnosisNeeded',e.final_reason is null));end $$;

create or replace function maths._capture_attempt_evidence_trigger() returns trigger language plpgsql security definer set search_path='pg_catalog','public','maths' as $$
declare baseline_ numeric;timing_ text;reason_ text;conf_ numeric;eid_ uuid;family_ text;concept_ text;is_calc boolean:=false;is_formula boolean:=false;
begin if exists(select 1 from maths.performance_evidence where attempt_id=new.attempt_id)then return new;end if;baseline_:=maths._baseline_sec(new.user_id,new.question_id,new.attempted_at);timing_:=maths._timing_class(new.result,new.response_sec,baseline_);select coalesce(r.bank_calculation or r.in_calc_set,false),coalesce(r.in_formula_revision,false)into is_calc,is_formula from maths.runtime_questions r where r.question_id=new.question_id;if lower(coalesce(new.result,''))='wrong' then if lower(coalesce(new.mode,''))like'%formula%' or is_formula then reason_:='FOR';conf_:=.72;elsif lower(coalesce(new.mode,''))like'%calculation%' or is_calc then reason_:='CAL';conf_:=.78;elsif timing_='wrong_fast' then reason_:='APP';conf_:=.62;elsif timing_='wrong_slow' then reason_:='TIME';conf_:=.58;else reason_:=null;conf_:=null;end if;elsif timing_='correct_slow' then reason_:='TIME';conf_:=.72;end if;insert into maths.performance_evidence(user_id,question_id,attempt_id,session_id,evidence_source,inferred_reason,inference_confidence,correctness,response_sec,baseline_sec,timing_class,slow_correct,metadata,created_at)values(new.user_id,new.question_id,new.attempt_id,new.session_id,coalesce(nullif(new.mode,''),'practice'),reason_,conf_,lower(coalesce(new.result,'seen')),new.response_sec,baseline_,timing_,timing_='correct_slow',jsonb_build_object('variantType',coalesce(new.variant_type,''),'questionIndex',new.question_index),new.attempted_at)returning evidence_id into eid_;select family_id into family_ from maths.question_families where question_id=new.question_id and active limit 1;select concept_id into concept_ from maths.question_concepts where question_id=new.question_id and active order by confidence desc limit 1;if concept_ is not null then perform maths._refresh_concept_state(new.user_id,concept_);end if;if family_ is not null then perform maths._refresh_family_state(new.user_id,family_);end if;perform maths._sync_repair_from_evidence(eid_);return new;end $$;

drop trigger if exists maths_capture_attempt_performance on maths.attempts;create trigger maths_capture_attempt_performance after insert on maths.attempts for each row execute function maths._capture_attempt_evidence_trigger();

insert into maths.performance_evidence(user_id,question_id,attempt_id,session_id,evidence_source,inferred_reason,inference_confidence,correctness,response_sec,baseline_sec,timing_class,slow_correct,metadata,created_at)
select a.user_id,a.question_id,a.attempt_id,a.session_id,coalesce(nullif(a.mode,''),'historical_attempt'),null,null,lower(coalesce(a.result,'seen')),a.response_sec,maths._baseline_sec(a.user_id,a.question_id,a.attempted_at),maths._timing_class(a.result,a.response_sec,maths._baseline_sec(a.user_id,a.question_id,a.attempted_at)),maths._timing_class(a.result,a.response_sec,maths._baseline_sec(a.user_id,a.question_id,a.attempted_at))='correct_slow',jsonb_build_object('backfilled',true,'variantType',coalesce(a.variant_type,'')),a.attempted_at from maths.attempts a where not exists(select 1 from maths.performance_evidence e where e.attempt_id=a.attempt_id);

do $$declare r record;begin for r in select distinct e.user_id,qc.concept_id from maths.performance_evidence e join maths.question_concepts qc on qc.question_id=e.question_id and qc.active loop perform maths._refresh_concept_state(r.user_id,r.concept_id);end loop;for r in select distinct e.user_id,qf.family_id from maths.performance_evidence e join maths.question_families qf on qf.question_id=e.question_id and qf.active loop perform maths._refresh_family_state(r.user_id,r.family_id);end loop;end $$;

create or replace function public.maths_confirm_diagnosis(p_attempt_id text,p_reason text,p_confidence_response text default null)returns jsonb language plpgsql security definer set search_path='pg_catalog','public','maths' as $$declare uid uuid:=maths._require_uid();e maths.performance_evidence%rowtype;reason_ text:=upper(nullif(btrim(p_reason),''));confidence_ text:=lower(nullif(btrim(p_confidence_response),''));begin if reason_ not in('CAL','APP','CON','FOR','SILLY','TIME')then raise exception 'Invalid Maths diagnosis';end if;if confidence_ is not null and confidence_ not in('sure','50_50','guess')then raise exception 'Invalid confidence response';end if;update maths.performance_evidence set user_confirmed_reason=reason_,confidence_response=coalesce(confidence_,confidence_response),updated_at=now() where user_id=uid and attempt_id=p_attempt_id returning * into e;if not found then raise exception 'Attempt evidence not found';end if;update maths.repair_queue set status='dismissed',updated_at=now() where user_id=uid and source_evidence_id=e.evidence_id and status in('open','in_progress','waiting_confirmation');perform maths._sync_repair_from_evidence(e.evidence_id);return jsonb_build_object('ok',true,'attemptId',p_attempt_id,'reason',e.final_reason,'confidence',e.confidence_response);end $$;
create or replace function public.maths_record_confidence(p_attempt_id text,p_confidence_response text)returns jsonb language plpgsql security definer set search_path='pg_catalog','public','maths' as $$declare uid uuid:=maths._require_uid();c text:=lower(nullif(btrim(p_confidence_response),''));begin if c not in('sure','50_50','guess')then raise exception 'Invalid confidence response';end if;update maths.performance_evidence set confidence_response=c,updated_at=now() where user_id=uid and attempt_id=p_attempt_id;if not found then raise exception 'Attempt evidence not found';end if;return jsonb_build_object('ok',true,'attemptId',p_attempt_id,'confidence',c);end $$;
create or replace function public.maths_record_selection(p_session_id text,p_question_id text,p_decision text,p_decision_sec numeric default null)returns jsonb language plpgsql security definer set search_path='pg_catalog','public','maths' as $$declare uid uuid:=maths._require_uid();d text:=upper(nullif(btrim(p_decision),''));begin if d not in('SOLVE','LATER','SKIP')then raise exception 'Invalid selection decision';end if;if not exists(select 1 from maths.sessions s join maths.session_questions sq on sq.session_id=s.session_id where s.user_id=uid and s.session_id=p_session_id and sq.question_id=p_question_id)then raise exception 'Question does not belong to this session';end if;insert into maths.selection_evidence(user_id,session_id,question_id,decision,decision_sec)values(uid,p_session_id,p_question_id,d,greatest(0,least(coalesce(p_decision_sec,0),600)))on conflict(user_id,session_id,question_id)do update set decision=excluded.decision,decision_sec=excluded.decision_sec,updated_at=now();update maths.performance_evidence set selection_decision=d,updated_at=now() where user_id=uid and session_id=p_session_id and question_id=p_question_id;return jsonb_build_object('ok',true,'decision',d);end $$;
create or replace function public.maths_get_question_performance(p_question_id text)returns jsonb language plpgsql stable security definer set search_path='pg_catalog','public','maths' as $$declare uid uuid:=maths._require_uid();e maths.performance_evidence%rowtype;family_ text;concept_ text;fs maths.family_state%rowtype;cs maths.concept_state%rowtype;begin if not exists(select 1 from maths.runtime_questions where question_id=p_question_id and runtime_active)then raise exception 'Question not found';end if;select * into e from maths.performance_evidence where user_id=uid and question_id=p_question_id order by created_at desc limit 1;select family_id into family_ from maths.question_families where question_id=p_question_id and active limit 1;select concept_id into concept_ from maths.question_concepts where question_id=p_question_id and active order by confidence desc limit 1;if family_ is not null then select * into fs from maths.family_state where user_id=uid and family_id=family_;end if;if concept_ is not null then select * into cs from maths.concept_state where user_id=uid and concept_id=concept_;end if;return jsonb_build_object('ok',true,'questionId',p_question_id,'latest',case when e.evidence_id is null then null else jsonb_build_object('attemptId',e.attempt_id,'reason',e.final_reason,'inferredReason',e.inferred_reason,'userReason',e.user_confirmed_reason,'inferenceConfidence',e.inference_confidence,'correctness',e.correctness,'responseSec',e.response_sec,'baselineSec',e.baseline_sec,'timingClass',e.timing_class,'slowCorrect',e.slow_correct,'confidence',e.confidence_response)end,'family',case when family_ is null then null else jsonb_build_object('id',family_,'persistentWeak',coalesce(fs.persistent_weak,false),'coldConfirmed',coalesce(fs.cold_confirmed,false),'accuracy',fs.recent_accuracy,'medianSec',fs.recent_median_sec)end,'concept',case when concept_ is null then null else jsonb_build_object('id',concept_,'coldConfirmed',coalesce(cs.cold_confirmed,false),'knowledgeScore',cs.knowledge_score,'performanceScore',cs.performance_score)end);end $$;

revoke all on function maths._concept_key(text,text,text) from public,anon,authenticated;revoke all on function maths._baseline_sec(uuid,text,timestamptz) from public,anon,authenticated;revoke all on function maths._timing_class(text,numeric,numeric) from public,anon,authenticated;revoke all on function maths._refresh_concept_state(uuid,text) from public,anon,authenticated;revoke all on function maths._refresh_family_state(uuid,text) from public,anon,authenticated;revoke all on function maths._sync_repair_from_evidence(uuid) from public,anon,authenticated;revoke all on function maths._capture_attempt_evidence_trigger() from public,anon,authenticated;
revoke all on function public.maths_confirm_diagnosis(text,text,text) from public,anon;grant execute on function public.maths_confirm_diagnosis(text,text,text) to authenticated;revoke all on function public.maths_record_confidence(text,text) from public,anon;grant execute on function public.maths_record_confidence(text,text) to authenticated;revoke all on function public.maths_record_selection(text,text,text,numeric) from public,anon;grant execute on function public.maths_record_selection(text,text,text,numeric) to authenticated;revoke all on function public.maths_get_question_performance(text) from public,anon;grant execute on function public.maths_get_question_performance(text) to authenticated;

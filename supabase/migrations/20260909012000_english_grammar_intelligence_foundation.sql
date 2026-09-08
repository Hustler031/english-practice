-- ENGLISH V2 — Grammar Intelligence Stage 1 foundation
-- Source of truth remains GitHub migrations. This migration is intentionally not deployed
-- during Stage 1; Stage 3 owns production deployment after end-to-end validation.

-- ChatGPT content transport and audit ledgers need a first-class Grammar lane.
alter table english.chatgpt_content_task_runs
  drop constraint if exists chatgpt_content_task_runs_lane_check;
alter table english.chatgpt_content_task_runs
  add constraint chatgpt_content_task_runs_lane_check
  check (lane = any (array['phrasal'::text,'hindu'::text,'grammar'::text]));

alter table english.content_generation_audits
  drop constraint if exists content_generation_audits_lane_check;
alter table english.content_generation_audits
  add constraint content_generation_audits_lane_check
  check (lane = any (array['phrasal'::text,'hindu'::text,'saved'::text,'tone'::text,'sprint'::text,'grammar'::text]));

alter table english.ai_content_feature_flags
  drop constraint if exists ai_content_feature_flags_flag_check;
alter table english.ai_content_feature_flags
  add constraint ai_content_feature_flags_flag_check
  check (flag = any (array[
    'gemini_content_v1'::text,'groq_critic_v1'::text,'phrasal_sense_v1'::text,
    'phrasal_context_fill_v1'::text,'phrasal_variant_rotation_v1'::text,
    'chatgpt_sprint_v1'::text,'hindu_tone_v1'::text,'antigravity_writer_v1'::text,
    'luna_critic_v1'::text,'grammar_ai_v1'::text
  ]));
insert into english.ai_content_feature_flags(flag,enabled,metadata)
values('grammar_ai_v1',false,jsonb_build_object('stage','stage1','owner','chatgpt_planner_generator','dailyTarget',20))
on conflict(flag) do update set metadata=excluded.metadata,updated_at=now();

create sequence if not exists english.grammar_question_seq start with 1 increment by 1;

create table if not exists english.grammar_rules(
  rule_key text primary key,
  chapter text not null,
  rule_family text not null,
  rule_title text not null,
  canonical_rule text not null,
  common_trap text,
  contrast_with text,
  priority integer not null default 50 check(priority between 0 and 100),
  difficulty text not null default 'Moderate' check(difficulty in ('Basic','Moderate','Advanced')),
  supported_families text[] not null default array['context_fill','sentence_improvement','error_detection','transfer']::text[],
  source_name text not null,
  source_url text not null,
  verification_note text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table english.grammar_rules is 'Verified SSC-relevant grammar curriculum. A row existing here does not mean the learner has been introduced to it.';

create table if not exists english.grammar_rule_aliases(
  alias_key text primary key,
  rule_key text not null references english.grammar_rules(rule_key) on delete cascade,
  source text not null default 'sprint_concept_key',
  confidence numeric not null default 1 check(confidence between 0 and 1),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table english.grammar_rule_aliases is 'Non-destructive bridge from historical Sprint concept keys to stable Grammar Rule keys; old concept identities are never rewritten.';

create table if not exists english.grammar_question_variants(
  question_id text primary key references english.questions(question_id) on delete restrict,
  rule_key text not null references english.grammar_rules(rule_key) on delete restrict,
  question_family text not null check(question_family in ('direct_fill','context_fill','sentence_improvement','error_detection','transformation','contrast','transfer')),
  variant_key text,
  variant_fingerprint text,
  generator_provider text,
  critic_provider text,
  quality_score numeric,
  critic_decision text,
  difficulty text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists grammar_question_variants_rule_family_idx
  on english.grammar_question_variants(rule_key,question_family,created_at);

create table if not exists english.grammar_rule_events(
  event_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  rule_key text not null references english.grammar_rules(rule_key) on delete restrict,
  source text not null check(source in ('grammar_daily','sprint')),
  source_key text not null,
  question_id text references english.questions(question_id) on delete restrict,
  question_family text,
  correct boolean,
  time_seconds numeric,
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(user_id,source,source_key)
);
create index if not exists grammar_rule_events_user_rule_idx
  on english.grammar_rule_events(user_id,rule_key,occurred_at desc);

create table if not exists english.grammar_rule_evidence(
  user_id uuid not null references auth.users(id) on delete cascade,
  rule_key text not null references english.grammar_rules(rule_key) on delete restrict,
  introduced_at timestamptz,
  last_selected_at timestamptz,
  selection_count integer not null default 0,
  attempts integer not null default 0,
  correct integer not null default 0,
  wrong integer not null default 0,
  distinct_questions integer not null default 0,
  distinct_families integer not null default 0,
  transfer_successes integer not null default 0,
  recent_failures integer not null default 0,
  confidence_score numeric not null default 0,
  coverage_state text not null default 'introduced' check(coverage_state in ('introduced','learning','weak','strong','mastered')),
  next_review timestamptz,
  last_attempt_at timestamptz,
  last_family text,
  updated_at timestamptz not null default now(),
  primary key(user_id,rule_key)
);
create index if not exists grammar_rule_evidence_due_idx
  on english.grammar_rule_evidence(user_id,coverage_state,next_review,last_attempt_at);

create table if not exists english.grammar_generation_batches(
  batch_date date primary key,
  run_id uuid not null unique,
  source_id text not null,
  status text not null default 'building' check(status in ('building','ready','applied','abandoned')),
  selection jsonb not null default '[]'::jsonb,
  expected_count integer not null default 20 check(expected_count=20),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  applied_at timestamptz
);

create table if not exists english.grammar_generation_slots(
  batch_date date not null references english.grammar_generation_batches(batch_date) on delete cascade,
  slot_no integer not null check(slot_no between 1 and 20),
  rule_key text not null references english.grammar_rules(rule_key) on delete restrict,
  preferred_family text not null,
  assignment jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check(status in ('pending','processing','ready','failed')),
  finalized jsonb,
  attempt_count integer not null default 0 check(attempt_count>=0),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ready_at timestamptz,
  primary key(batch_date,slot_no)
);

create table if not exists english.grammar_daily_items(
  batch_date date not null,
  slot_no integer not null check(slot_no between 1 and 20),
  source_id text not null,
  question_id text not null references english.questions(question_id) on delete restrict,
  rule_key text not null references english.grammar_rules(rule_key) on delete restrict,
  requested_family text not null,
  question_family text not null,
  generator_provider text,
  is_new_variant boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  primary key(batch_date,slot_no),
  unique(batch_date,question_id)
);
create index if not exists grammar_daily_items_rule_idx
  on english.grammar_daily_items(rule_key,batch_date desc);

-- RLS is enabled from birth. Service-role generation uses SECURITY DEFINER functions;
-- learner-facing reads are explicitly scoped below.
alter table english.grammar_rules enable row level security;
alter table english.grammar_rule_aliases enable row level security;
alter table english.grammar_question_variants enable row level security;
alter table english.grammar_rule_events enable row level security;
alter table english.grammar_rule_evidence enable row level security;
alter table english.grammar_generation_batches enable row level security;
alter table english.grammar_generation_slots enable row level security;
alter table english.grammar_daily_items enable row level security;

drop policy if exists grammar_rules_authenticated_read on english.grammar_rules;
create policy grammar_rules_authenticated_read on english.grammar_rules for select to authenticated using(active);
drop policy if exists grammar_variants_authenticated_read on english.grammar_question_variants;
create policy grammar_variants_authenticated_read on english.grammar_question_variants for select to authenticated using(true);
drop policy if exists grammar_evidence_owner_read on english.grammar_rule_evidence;
create policy grammar_evidence_owner_read on english.grammar_rule_evidence for select to authenticated using(user_id=auth.uid());
drop policy if exists grammar_events_owner_read on english.grammar_rule_events;
create policy grammar_events_owner_read on english.grammar_rule_events for select to authenticated using(user_id=auth.uid());
drop policy if exists grammar_daily_authenticated_read on english.grammar_daily_items;
create policy grammar_daily_authenticated_read on english.grammar_daily_items for select to authenticated using(true);

grant select on english.grammar_rules,english.grammar_question_variants,english.grammar_rule_evidence,english.grammar_rule_events,english.grammar_daily_items to authenticated;

create or replace function english.grammar_concept_id(p_rule_key text)
returns text
language sql
immutable
set search_path to 'pg_catalog'
as $function$
select 'GRC_'||upper(regexp_replace(regexp_replace(coalesce(p_rule_key,''),'^grammar_','','i'),'[^a-zA-Z0-9]+','_','g'))
$function$;

create or replace function english.grammar_normalize_family(p_family text)
returns text
language sql
immutable
set search_path to 'pg_catalog'
as $function$
select case lower(regexp_replace(coalesce(p_family,''),'[^a-zA-Z]+','_','g'))
  when 'fill_in_the_blank' then 'context_fill'
  when 'fill_blank' then 'context_fill'
  when 'sentence_improvement' then 'sentence_improvement'
  when 'error_detection' then 'error_detection'
  when 'identify_the_error' then 'error_detection'
  when 'transformation' then 'transformation'
  when 'contrast' then 'contrast'
  when 'transfer' then 'transfer'
  when 'direct_fill' then 'direct_fill'
  when 'context_fill' then 'context_fill'
  else lower(btrim(coalesce(p_family,''))) end
$function$;

create or replace function english.recompute_grammar_rule_evidence(p_user uuid,p_rule_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare
  v_attempts integer:=0; v_correct integer:=0; v_wrong integer:=0;
  v_questions integer:=0; v_families integer:=0; v_transfer integer:=0; v_recent_fail integer:=0;
  v_last timestamptz; v_last_family text; v_accuracy numeric:=0; v_score numeric:=0; v_state text:='introduced'; v_next timestamptz;
begin
  select count(*)::int,
         count(*) filter(where correct is true)::int,
         count(*) filter(where correct is false)::int,
         count(distinct question_id) filter(where question_id is not null)::int,
         count(distinct question_family) filter(where nullif(question_family,'') is not null)::int,
         count(*) filter(where correct is true and question_family in ('transfer','contrast','transformation'))::int,
         count(*) filter(where correct is false and occurred_at>=now()-interval '14 days')::int,
         max(occurred_at)
  into v_attempts,v_correct,v_wrong,v_questions,v_families,v_transfer,v_recent_fail,v_last
  from english.grammar_rule_events where user_id=p_user and rule_key=p_rule_key;

  select question_family into v_last_family
  from english.grammar_rule_events
  where user_id=p_user and rule_key=p_rule_key and nullif(question_family,'') is not null
  order by occurred_at desc limit 1;

  v_accuracy:=case when v_attempts>0 then v_correct::numeric/v_attempts else 0 end;
  v_score:=least(1,greatest(0,
    (v_accuracy*0.62)
    +(least(v_families,4)::numeric/4*0.18)
    +(least(v_transfer,2)::numeric/2*0.15)
    -(least(v_recent_fail,3)::numeric/3*0.20)
  ));
  v_state:=case
    when v_attempts=0 then 'introduced'
    when (v_attempts>=2 and v_accuracy<0.55) or v_recent_fail>=2 then 'weak'
    when v_attempts>=5 and v_families>=3 and v_transfer>=1 and v_accuracy>=0.80 and v_recent_fail=0 then 'mastered'
    when v_attempts>=3 and v_families>=2 and v_accuracy>=0.72 and v_recent_fail<=1 then 'strong'
    else 'learning' end;
  v_next:=case v_state
    when 'weak' then coalesce(v_last,now())+interval '1 day'
    when 'learning' then coalesce(v_last,now())+interval '2 days'
    when 'strong' then coalesce(v_last,now())+interval '5 days'
    when 'mastered' then coalesce(v_last,now())+interval '10 days'
    else now()+interval '1 day' end;

  insert into english.grammar_rule_evidence(user_id,rule_key,attempts,correct,wrong,distinct_questions,distinct_families,transfer_successes,recent_failures,confidence_score,coverage_state,next_review,last_attempt_at,last_family,updated_at)
  values(p_user,p_rule_key,v_attempts,v_correct,v_wrong,v_questions,v_families,v_transfer,v_recent_fail,round(v_score,4),v_state,v_next,v_last,v_last_family,now())
  on conflict(user_id,rule_key) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,
    distinct_questions=excluded.distinct_questions,distinct_families=excluded.distinct_families,
    transfer_successes=excluded.transfer_successes,recent_failures=excluded.recent_failures,
    confidence_score=excluded.confidence_score,coverage_state=excluded.coverage_state,
    next_review=excluded.next_review,last_attempt_at=excluded.last_attempt_at,last_family=excluded.last_family,updated_at=now();

  return jsonb_build_object('ruleKey',p_rule_key,'attempts',v_attempts,'correct',v_correct,'wrong',v_wrong,
    'distinctQuestions',v_questions,'distinctFamilies',v_families,'transferSuccesses',v_transfer,
    'recentFailures',v_recent_fail,'confidence',round(v_score,4),'state',v_state,'nextReview',v_next);
end
$function$;

create or replace function english.on_attempt_grammar_evidence()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare v_rule text; v_family text;
begin
  select rule_key,question_family into v_rule,v_family
  from english.grammar_question_variants where question_id=new.question_id;
  if v_rule is null then return new; end if;
  insert into english.grammar_rule_events(user_id,rule_key,source,source_key,question_id,question_family,correct,time_seconds,occurred_at,metadata)
  values(new.user_id,v_rule,'grammar_daily',new.attempt_id,new.question_id,v_family,new.correct,new.time_seconds,new.attempted_at,
    jsonb_build_object('module',coalesce(new.module,'')))
  on conflict(user_id,source,source_key) do update set correct=excluded.correct,time_seconds=excluded.time_seconds,occurred_at=excluded.occurred_at,metadata=excluded.metadata;
  perform english.recompute_grammar_rule_evidence(new.user_id,v_rule);
  return new;
end
$function$;

drop trigger if exists english_attempt_grammar_evidence on english.attempts;
create trigger english_attempt_grammar_evidence
after insert on english.attempts
for each row execute function english.on_attempt_grammar_evidence();

create or replace function english.on_sprint_answer_grammar_evidence()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare v_alias text; v_rule text; v_family text; v_qid text; v_at timestamptz;
begin
  if new.selected_key is null or upper(new.selected_key) not in ('A','B','C','D') then return new; end if;
  select coalesce(nullif(i.metadata->>'conceptKey',''),nullif(i.metadata->>'concept_key','')),
         english.grammar_normalize_family(i.question_type),i.canonical_question_id,
         coalesce(s.completed_at,s.started_at,new.updated_at,new.created_at)
  into v_alias,v_family,v_qid,v_at
  from english.sprint_items i join english.sprint_sessions s on s.session_id=i.session_id
  where i.session_id=new.session_id and i.position=new.position;
  if v_alias is null then return new; end if;
  select rule_key into v_rule from english.grammar_rule_aliases where alias_key=v_alias and active limit 1;
  if v_rule is null then return new; end if;
  insert into english.grammar_rule_events(user_id,rule_key,source,source_key,question_id,question_family,correct,time_seconds,occurred_at,metadata)
  values(new.user_id,v_rule,'sprint',new.session_id::text||':'||new.position::text,v_qid,v_family,new.correct,new.time_seconds,coalesce(v_at,now()),
    jsonb_build_object('sprintConceptKey',v_alias,'sessionId',new.session_id,'position',new.position))
  on conflict(user_id,source,source_key) do update set correct=excluded.correct,time_seconds=excluded.time_seconds,occurred_at=excluded.occurred_at,metadata=excluded.metadata;
  perform english.recompute_grammar_rule_evidence(new.user_id,v_rule);
  return new;
end
$function$;

drop trigger if exists english_sprint_answer_grammar_evidence on english.sprint_answers;
create trigger english_sprint_answer_grammar_evidence
after insert or update of selected_key,correct,time_seconds on english.sprint_answers
for each row execute function english.on_sprint_answer_grammar_evidence();

create or replace function english.grammar_sync_existing_sprint_evidence()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare r record; v_count integer:=0; v_rules integer:=0;
begin
  for r in
    select a.user_id,a.session_id,a.position,a.correct,a.time_seconds,
      coalesce(s.completed_at,s.started_at,a.updated_at,a.created_at) occurred_at,
      i.canonical_question_id,
      coalesce(nullif(i.metadata->>'conceptKey',''),nullif(i.metadata->>'concept_key','')) alias_key,
      english.grammar_normalize_family(i.question_type) question_family,
      ga.rule_key
    from english.sprint_answers a
    join english.sprint_items i on i.session_id=a.session_id and i.position=a.position
    join english.sprint_sessions s on s.session_id=a.session_id
    join english.grammar_rule_aliases ga on ga.alias_key=coalesce(nullif(i.metadata->>'conceptKey',''),nullif(i.metadata->>'concept_key','')) and ga.active
    where a.selected_key is not null and upper(a.selected_key) in ('A','B','C','D')
  loop
    insert into english.grammar_rule_events(user_id,rule_key,source,source_key,question_id,question_family,correct,time_seconds,occurred_at,metadata)
    values(r.user_id,r.rule_key,'sprint',r.session_id::text||':'||r.position::text,r.canonical_question_id,r.question_family,r.correct,r.time_seconds,r.occurred_at,
      jsonb_build_object('sprintConceptKey',r.alias_key,'sessionId',r.session_id,'position',r.position))
    on conflict(user_id,source,source_key) do update set correct=excluded.correct,time_seconds=excluded.time_seconds,occurred_at=excluded.occurred_at,metadata=excluded.metadata;
    v_count:=v_count+1;
  end loop;
  for r in select distinct user_id,rule_key from english.grammar_rule_events where source='sprint' loop
    perform english.recompute_grammar_rule_evidence(r.user_id,r.rule_key); v_rules:=v_rules+1;
  end loop;
  return jsonb_build_object('ok',true,'sprintEvents',v_count,'rulesRecomputed',v_rules);
end
$function$;

revoke all on function english.recompute_grammar_rule_evidence(uuid,text) from public;
revoke all on function english.grammar_sync_existing_sprint_evidence() from public;
grant execute on function english.recompute_grammar_rule_evidence(uuid,text) to service_role;
grant execute on function english.grammar_sync_existing_sprint_evidence() to service_role;

\set ON_ERROR_STOP on

-- Build the complete Stage 2 disposable Grammar harness first.
\ir validate-english-grammar-stage2.sql

-- These shared learner-signal tables exist in production. Keep the disposable
-- Grammar harness self-contained so the carry-forward migration is executed,
-- not merely parsed.
create table if not exists english.difficult_state(
  user_id uuid not null,
  question_id text not null,
  difficult boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key(user_id,question_id)
);

create table if not exists english.learner_confidence_signals(
  signal_id uuid primary key default gen_random_uuid(),
  user_id uuid,
  question_id text,
  attempt_id text,
  signal text,
  created_at timestamptz not null default now()
);
alter table english.learner_confidence_signals add column if not exists user_id uuid;
alter table english.learner_confidence_signals add column if not exists question_id text;
alter table english.learner_confidence_signals add column if not exists attempt_id text;
alter table english.learner_confidence_signals add column if not exists signal text;
alter table english.learner_confidence_signals add column if not exists created_at timestamptz not null default now();

\ir ../../supabase/migrations/20260910091000_english_grammar_daily_carry_forward_round2.sql

-- Create a previous-day copy of the exact-20 fixture and answer only 12 of it
-- using the legacy module format. The oldest unfinished batch must become the
-- active Grammar Daily batch and today's batch must be locked behind it.
do $$
declare
  uid uuid:='11111111-1111-1111-1111-111111111111'::uuid;
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_old date:=((now() at time zone 'Asia/Kolkata')::date-1);
  h jsonb; x jsonb;
begin
  insert into english.grammar_daily_items(
    batch_date,slot_no,source_id,question_id,rule_key,requested_family,
    question_family,generator_provider,is_new_variant,metadata
  )
  select
    v_old,slot_no,'GRAMMAR_DAILY_CARRY_FORWARD_TEST',question_id,rule_key,requested_family,
    question_family,generator_provider,is_new_variant,metadata
  from english.grammar_daily_items
  where batch_date=v_today
  on conflict(batch_date,slot_no) do nothing;

  insert into english.attempts(
    attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,
    marked_revision,topic,concept_id,module,submission_key,created_at
  )
  select
    'grammar-legacy-old-'||i.slot_no,uid,i.question_id,
    ((v_old::timestamp+interval '12 hours') at time zone 'Asia/Kolkata'),
    'A',true,5,false,'Grammar',null,'grammardaily','grammar-legacy-old-'||i.slot_no,now()
  from english.grammar_daily_items i
  where i.batch_date=v_old and i.slot_no<=12
  on conflict(attempt_id) do nothing;

  h:=public.english_get_grammar_hub();
  if (h->'daily'->>'activeDate')::date<>v_old then
    raise exception 'Oldest incomplete Grammar batch was not selected: %',h;
  end if;
  if (h->'daily'->>'activePracticed')::int<>12 or (h->'daily'->>'activeRemaining')::int<>8 then
    raise exception 'Backlog progress is incorrect: %',h;
  end if;
  if not coalesce((h->'daily'->>'isBacklog')::boolean,false) or not coalesce((h->'daily'->>'todayLocked')::boolean,false) then
    raise exception 'Today was not locked behind unfinished Grammar backlog: %',h;
  end if;

  x:=public.english_get_grammar_today();
  if (x->>'date')::date<>v_old or not coalesce((x->>'isBacklog')::boolean,false) then
    raise exception 'Grammar getter did not serve the oldest backlog: %',x;
  end if;
  if coalesce((x->'items'->0->>'attemptedBatch')::boolean,true) then
    raise exception 'Grammar backlog did not put unattempted questions first: %',x->'items'->0;
  end if;
end $$;

-- Finish the 8 old questions with the date-encoded module. The old batch must
-- become complete even though these answers happen on the following day. Then
-- answer today's 20 with 3 wrong answers; Today becomes complete and Round 2
-- must contain exactly those 3 focus questions.
do $$
declare
  uid uuid:='11111111-1111-1111-1111-111111111111'::uuid;
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_old date:=((now() at time zone 'Asia/Kolkata')::date-1);
  h jsonb; r jsonb;
begin
  insert into english.attempts(
    attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,
    marked_revision,topic,concept_id,module,submission_key,created_at
  )
  select
    'grammar-encoded-old-'||i.slot_no,uid,i.question_id,now(),'A',true,5,false,'Grammar',null,
    'grammardaily:'||v_old::text,'grammar-encoded-old-'||i.slot_no,now()
  from english.grammar_daily_items i
  where i.batch_date=v_old and i.slot_no>12
  on conflict(attempt_id) do nothing;

  h:=public.english_get_grammar_hub();
  if (h->'daily'->>'activeDate')::date<>v_today or coalesce((h->'daily'->>'isBacklog')::boolean,true) then
    raise exception 'Current Grammar batch did not unlock after backlog completion: %',h;
  end if;

  insert into english.attempts(
    attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,
    marked_revision,topic,concept_id,module,submission_key,created_at
  )
  select
    'grammar-today-'||i.slot_no,uid,i.question_id,now(),'A',(i.slot_no>3),5,false,'Grammar',null,
    'grammardaily:'||v_today::text,'grammar-today-'||i.slot_no,now()
  from english.grammar_daily_items i
  where i.batch_date=v_today
  on conflict(attempt_id) do nothing;

  h:=public.english_get_grammar_hub();
  if not coalesce((h->'today'->>'complete')::boolean,false) or (h->'today'->>'practiced')::int<>20 then
    raise exception 'Completed Grammar Today was not marked complete: %',h;
  end if;
  if (h->'today'->>'wrong')::int<>3 or (h->'today'->>'round2Focus')::int<>3 then
    raise exception 'Grammar Round 2 focus count drifted: %',h;
  end if;

  r:=public.english_get_grammar_round2(v_today);
  if not coalesce((r->>'ok')::boolean,false) or (r->>'count')::int<>3 or jsonb_array_length(r->'items')<>3 then
    raise exception 'Grammar Round 2 did not return exactly the focus questions: %',r;
  end if;
end $$;

select 'English Grammar Daily carry-forward + Round 2 contracts passed' result;

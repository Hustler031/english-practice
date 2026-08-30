-- GK V2 reconstructed pre-20260830025704 baseline.
--
-- IMPORTANT: this is NOT an original historical migration and MUST NOT be applied to
-- the existing live project as a normal ledger migration. It is a clean-database
-- recovery/bootstrap artifact reconstructed from the verified live catalog on
-- 2026-08-30. It contains schema, constraints, indexes, RLS and import transport only;
-- it contains no canonical question rows and no user learning evidence.

create schema if not exists gk;
create extension if not exists pgcrypto;

create table if not exists gk.questions (
  question_id text primary key,
  content_type text,
  lecture_no integer,
  source_label text,
  source_date date,
  subject text,
  topic text,
  concept_id text,
  source_page text,
  question text not null,
  option_a text,
  option_b text,
  option_c text,
  option_d text,
  correct_option text,
  explanation text,
  trick text,
  related_fact text,
  exam_trap text,
  difficulty text,
  status text,
  created_at timestamptz,
  active boolean not null default true,
  lecture_key text,
  content_lane text,
  source_row_number integer,
  source_payload jsonb
);

create table if not exists gk.lectures (
  lecture_no integer,
  content_type text,
  title text,
  date_added date,
  source_file_name text,
  total_pages integer,
  facts_count integer,
  questions_count integer,
  status text,
  lecture_key text primary key,
  source_row_number integer
);

create table if not exists gk.attempts (
  attempt_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null,
  question_id text not null references gk.questions(question_id) on delete restrict,
  selected_option text,
  is_correct boolean,
  marked_review boolean,
  mode text,
  session_id text,
  response_ms integer,
  submission_key text unique,
  study_day integer,
  learning_state text,
  guessed boolean,
  guessed_at timestamptz,
  attempt_kind text,
  canonical_selected_option text,
  display_selected_option text,
  is_spaced boolean,
  gap_hours numeric,
  confidence_confirmed boolean,
  study_date date
);

create table if not exists gk.exposures (
  exposure_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  exposed_at timestamptz not null,
  question_id text not null references gk.questions(question_id) on delete restrict,
  session_id text,
  mode text,
  study_day integer,
  exposure_key text unique,
  study_date date
);

create table if not exists gk.question_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete cascade,
  attempts integer not null default 0,
  correct integer not null default 0,
  wrong integer not null default 0,
  streak integer not null default 0,
  accuracy numeric,
  mastery_score numeric,
  last_attempt timestamptz,
  next_review timestamptz,
  marked_review boolean not null default false,
  learning_status text,
  last_selected text,
  last_correct boolean,
  difficult boolean not null default false,
  starred_at timestamptz,
  first_attempt_correct boolean,
  retention_attempts integer not null default 0,
  retention_correct integer not null default 0,
  retention_wrong integer not null default 0,
  last_spaced_attempt timestamptz,
  exposure_count integer not null default 0,
  first_seen timestamptz,
  last_seen timestamptz,
  guessed_attempts integer not null default 0,
  unconfirmed_guess boolean not null default false,
  last_guess_at timestamptz,
  confirmed_unguessed_spaced_recalls integer not null default 0,
  last_meaningful_result text,
  latest_result text,
  flag_active boolean not null default false,
  flag_reason text,
  flag_note text,
  flag_updated_at timestamptz,
  learning_updated_at timestamptz,
  primary key(user_id,question_id)
);

create table if not exists gk.sessions (
  session_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  mode text,
  params jsonb,
  current_index integer not null default 0,
  updated_at timestamptz,
  completed boolean not null default false,
  title text,
  study_day integer,
  composition jsonb,
  option_orders jsonb,
  answers jsonb,
  position_index integer,
  paused_at timestamptz,
  session_version text,
  result jsonb,
  created_at timestamptz not null default now(),
  study_date date
);

create table if not exists gk.session_questions (
  session_id text not null references gk.sessions(session_id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete restrict,
  position integer not null,
  primary key(session_id,question_id),
  unique(session_id,position)
);

create table if not exists gk.user_notes (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete cascade,
  note text,
  updated_at timestamptz not null default now(),
  primary key(user_id,question_id)
);

create table if not exists gk.flags (
  flag_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references gk.questions(question_id) on delete cascade,
  reason text,
  note text,
  created_at timestamptz,
  resolved boolean not null default false,
  resolved_at timestamptz,
  updated_at timestamptz
);

-- Legacy Demand_Sets had no owner column. The forward runtime migration adds user_id
-- without reassigning historical rows.
create table if not exists gk.demand_sets (
  demand_id text primary key,
  title text,
  kind text,
  criteria jsonb,
  question_ids jsonb,
  created_at timestamptz,
  last_used timestamptz,
  active boolean not null default true,
  source_row_number integer,
  source_payload jsonb
);

create table if not exists gk.raw_sheet_rows (
  source_spreadsheet_id text not null,
  source_sheet text not null,
  source_row_number integer not null,
  payload jsonb not null,
  source_digest text,
  captured_at timestamptz not null default now(),
  primary key(source_spreadsheet_id,source_sheet,source_row_number)
);

create table if not exists gk.legacy_settings (
  setting_key text primary key,
  setting_value jsonb,
  source_row_number integer,
  source_payload jsonb,
  captured_at timestamptz not null default now()
);

create table if not exists gk.migration_reconciliation (
  entity text primary key,
  source_rows integer not null default 0,
  migrated_rows integer not null default 0,
  rejected_rows integer not null default 0,
  source_digest text,
  migrated_digest text,
  status text not null default 'PENDING',
  details jsonb not null default '{}'::jsonb,
  checked_at timestamptz not null default now()
);

create index if not exists gk_attempts_user_time_idx on gk.attempts(user_id,attempted_at desc);
create index if not exists gk_state_due_idx on gk.question_state(user_id,next_review);
create index if not exists gk_questions_concept_idx on gk.questions(concept_id);
create index if not exists gk_questions_content_lane_idx on gk.questions(content_lane);
create index if not exists gk_questions_lecture_idx on gk.questions(lecture_no);
create index if not exists gk_questions_lecture_key_idx on gk.questions(lecture_key);
create index if not exists gk_questions_subject_topic_idx on gk.questions(subject,topic);
create index if not exists gk_lectures_lecture_no_idx on gk.lectures(lecture_no);
create index if not exists gk_lectures_source_file_idx on gk.lectures(source_file_name);

alter table gk.questions enable row level security;
alter table gk.lectures enable row level security;
alter table gk.attempts enable row level security;
alter table gk.exposures enable row level security;
alter table gk.question_state enable row level security;
alter table gk.sessions enable row level security;
alter table gk.session_questions enable row level security;
alter table gk.user_notes enable row level security;
alter table gk.flags enable row level security;
alter table gk.demand_sets enable row level security;
alter table gk.raw_sheet_rows enable row level security;
alter table gk.legacy_settings enable row level security;
alter table gk.migration_reconciliation enable row level security;

drop policy if exists gk_questions_authenticated_read on gk.questions;
create policy gk_questions_authenticated_read on gk.questions for select to authenticated using(true);
drop policy if exists gk_lectures_authenticated_read on gk.lectures;
create policy gk_lectures_authenticated_read on gk.lectures for select to authenticated using(true);
drop policy if exists gk_attempts_own on gk.attempts;
create policy gk_attempts_own on gk.attempts for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists gk_exposures_own on gk.exposures;
create policy gk_exposures_own on gk.exposures for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists gk_question_state_own on gk.question_state;
create policy gk_question_state_own on gk.question_state for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists gk_sessions_own on gk.sessions;
create policy gk_sessions_own on gk.sessions for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists gk_session_questions_own on gk.session_questions;
create policy gk_session_questions_own on gk.session_questions for all to authenticated
  using(exists(select 1 from gk.sessions s where s.session_id=session_questions.session_id and s.user_id=auth.uid()))
  with check(exists(select 1 from gk.sessions s where s.session_id=session_questions.session_id and s.user_id=auth.uid()));
drop policy if exists gk_user_notes_own on gk.user_notes;
create policy gk_user_notes_own on gk.user_notes for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists gk_flags_own on gk.flags;
create policy gk_flags_own on gk.flags for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

revoke all on schema gk from anon;
revoke all on all tables in schema gk from anon;
grant usage on schema gk to authenticated;
grant select on gk.questions,gk.lectures to authenticated;
grant select,insert,update,delete on gk.attempts,gk.exposures,gk.question_state,gk.sessions,gk.session_questions,gk.user_notes,gk.flags to authenticated;

-- Canonical transport recovered from the live effective schema. This is an admin-only
-- import mechanism; the baseline itself contains no rows.
create or replace function public.gk_v2_import_canonical(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  v_q int:=0; v_l int:=0; v_s int:=0; v_a int:=0; v_se int:=0; v_sq int:=0;
  v_e int:=0; v_n int:=0; v_f int:=0; v_d int:=0;
begin
  if jsonb_typeof(p_payload)<>'object' then raise exception 'invalid payload'; end if;

  insert into gk.lectures select * from jsonb_populate_recordset(null::gk.lectures,coalesce(p_payload->'lectures','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_l=row_count;
  insert into gk.questions select * from jsonb_populate_recordset(null::gk.questions,coalesce(p_payload->'questions','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_q=row_count;
  insert into gk.question_state select * from jsonb_populate_recordset(null::gk.question_state,coalesce(p_payload->'question_state','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_s=row_count;
  insert into gk.attempts select * from jsonb_populate_recordset(null::gk.attempts,coalesce(p_payload->'attempts','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_a=row_count;
  insert into gk.sessions select * from jsonb_populate_recordset(null::gk.sessions,coalesce(p_payload->'sessions','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_se=row_count;
  insert into gk.session_questions select * from jsonb_populate_recordset(null::gk.session_questions,coalesce(p_payload->'session_questions','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_sq=row_count;
  insert into gk.exposures select * from jsonb_populate_recordset(null::gk.exposures,coalesce(p_payload->'exposures','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_e=row_count;
  insert into gk.user_notes select * from jsonb_populate_recordset(null::gk.user_notes,coalesce(p_payload->'user_notes','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_n=row_count;
  insert into gk.flags select * from jsonb_populate_recordset(null::gk.flags,coalesce(p_payload->'flags','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_f=row_count;
  insert into gk.demand_sets select * from jsonb_populate_recordset(null::gk.demand_sets,coalesce(p_payload->'demand_sets','[]'::jsonb)) on conflict do nothing;
  get diagnostics v_d=row_count;

  return jsonb_build_object('ok',true,'inserted',jsonb_build_object(
    'lectures',v_l,'questions',v_q,'question_state',v_s,'attempts',v_a,'sessions',v_se,
    'session_questions',v_sq,'exposures',v_e,'user_notes',v_n,'flags',v_f,'demand_sets',v_d));
end
$$;
revoke execute on function public.gk_v2_import_canonical(jsonb) from public,anon,authenticated;
grant execute on function public.gk_v2_import_canonical(jsonb) to service_role;

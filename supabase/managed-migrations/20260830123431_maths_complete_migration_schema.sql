alter table maths.question_state add column if not exists source_row jsonb;
alter table maths.question_state add column if not exists migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict;

alter table maths.sessions add column if not exists source_row jsonb;
alter table maths.sessions add column if not exists migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict;

alter table maths.concept_membership add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table maths.concept_membership add column if not exists source_row jsonb;
alter table maths.concept_membership add column if not exists migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict;
alter table maths.concept_membership add column if not exists source_row_number integer;

alter table maths.practice_sets add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table maths.practice_sets add column if not exists source_row jsonb;
alter table maths.practice_sets add column if not exists migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict;
alter table maths.practice_sets add column if not exists source_row_number integer;

alter table maths.practice_set_items add column if not exists source_row jsonb;
alter table maths.practice_set_items add column if not exists migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict;

alter table maths.star_events add column if not exists source_event_key text;
alter table maths.star_events add column if not exists source_row jsonb;
alter table maths.star_events add column if not exists migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict;
alter table maths.star_events add column if not exists source_row_number integer;
create unique index if not exists star_events_source_event_key_uidx on maths.star_events(source_event_key) where source_event_key is not null;

create table if not exists maths.question_state_evidence (
  evidence_key text primary key,
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text,
  source_row_number integer not null,
  source_row jsonb not null
);

create table if not exists maths.concept_events (
  evidence_key text primary key,
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text,
  source_row_number integer not null,
  added_at timestamptz,
  study_day integer,
  chapter text,
  topic text,
  session_id text,
  active boolean,
  source_row jsonb not null
);

create table if not exists maths.demand_set_evidence (
  evidence_key text primary key,
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_row_number integer not null,
  set_id text,
  set_name text,
  description text,
  status text,
  created_at timestamptz,
  question_ids jsonb,
  source_row jsonb not null
);

create table if not exists maths.note_evidence (
  evidence_key text primary key,
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_row_number integer not null,
  question_id text,
  note text,
  updated_at timestamptz,
  pinned boolean,
  source_row jsonb not null
);

create table if not exists maths.star_event_evidence (
  evidence_key text primary key,
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_row_number integer not null,
  question_id text,
  event_at timestamptz,
  study_day integer,
  chapter text,
  type text,
  action text,
  session_id text,
  source_row jsonb not null
);

create table if not exists maths.settings_snapshot (
  migration_run_id text not null references maths.migration_runs(migration_run_id) on delete restrict,
  source_row_number integer not null,
  setting_key text,
  setting_value text,
  source_row jsonb not null,
  primary key (migration_run_id, source_row_number)
);

alter table maths.question_state_evidence enable row level security;
alter table maths.concept_events enable row level security;
alter table maths.demand_set_evidence enable row level security;
alter table maths.note_evidence enable row level security;
alter table maths.star_event_evidence enable row level security;
alter table maths.settings_snapshot enable row level security;

-- Historical evidence tables intentionally have no authenticated policies: service-role/audit only.

drop policy if exists maths_concept_membership_authenticated_read on maths.concept_membership;
create policy maths_concept_membership_own on maths.concept_membership for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists maths_practice_sets_authenticated_read on maths.practice_sets;
create policy maths_practice_sets_own on maths.practice_sets for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists maths_practice_set_items_authenticated_read on maths.practice_set_items;
create policy maths_practice_set_items_own on maths.practice_set_items for all to authenticated using (exists (select 1 from maths.practice_sets s where s.set_id = practice_set_items.set_id and s.user_id = auth.uid())) with check (exists (select 1 from maths.practice_sets s where s.set_id = practice_set_items.set_id and s.user_id = auth.uid()));



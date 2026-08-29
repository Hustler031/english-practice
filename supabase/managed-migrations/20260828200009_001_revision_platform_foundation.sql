create schema if not exists legacy;
create schema if not exists english;
create schema if not exists gk;
create schema if not exists maths;
create schema if not exists api;

create table if not exists legacy.import_batches (
  batch_id uuid primary key default gen_random_uuid(),
  app text not null check (app in ('english','gk','maths')),
  source_spreadsheet_id text not null,
  source_title text not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'started' check (status in ('started','completed','failed','superseded')),
  source_snapshot_sha256 text,
  source_row_count bigint,
  imported_row_count bigint,
  notes text
);

create table if not exists legacy.sheet_rows (
  id bigint generated always as identity primary key,
  batch_id uuid not null references legacy.import_batches(batch_id) on delete restrict,
  app text not null check (app in ('english','gk','maths')),
  sheet_name text not null,
  source_row integer not null check (source_row >= 1),
  row_data jsonb not null,
  row_sha256 text not null,
  imported_at timestamptz not null default now(),
  unique (batch_id, sheet_name, source_row)
);

create index if not exists idx_legacy_sheet_rows_batch on legacy.sheet_rows(batch_id);
create index if not exists idx_legacy_sheet_rows_app_sheet on legacy.sheet_rows(app, sheet_name);
create index if not exists idx_legacy_sheet_rows_hash on legacy.sheet_rows(row_sha256);

create table if not exists legacy.reconciliation_runs (
  reconciliation_id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references legacy.import_batches(batch_id) on delete restrict,
  app text not null check (app in ('english','gk','maths')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'started' check (status in ('started','passed','failed')),
  checks jsonb not null default '{}'::jsonb,
  notes text
);

revoke all on schema legacy from anon, authenticated;
revoke all on all tables in schema legacy from anon, authenticated;

comment on schema legacy is 'Immutable migration evidence copied from the legacy Google Sheets sources.';
comment on schema english is 'English revision application data.';
comment on schema gk is 'GK revision application data.';
comment on schema maths is 'Maths revision application data.';
comment on schema api is 'Explicit application API surface; underlying schemas are not directly exposed by design.';
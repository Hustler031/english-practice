-- Retain every structurally valid, history-safe, backend-approved Hindu proposal even when
-- the current daily display has fewer publication slots. Publication remains capped by
-- english.maintenance_apply_hindu_daily; retention is not publication.
create table if not exists english.hindu_candidate_backlog (
  candidate_id uuid primary key default gen_random_uuid(),
  batch_date date not null,
  run_id uuid,
  submitted_index integer not null,
  word text not null,
  normalized_word text not null,
  status text not null check (status in (
    'submitted','rejected_structure','rejected_duplicate','rejected_quality','accepted_retained','published'
  )),
  payload jsonb not null default '{}'::jsonb,
  quality_score numeric,
  critic_decision text,
  critic_model text,
  rejection_stage text,
  rejection_reason text,
  published_question_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(batch_date, normalized_word)
);

create index if not exists hindu_candidate_backlog_status_idx
  on english.hindu_candidate_backlog(status, batch_date desc);
create index if not exists hindu_candidate_backlog_run_idx
  on english.hindu_candidate_backlog(run_id, submitted_index);

alter table english.hindu_candidate_backlog enable row level security;
revoke all on english.hindu_candidate_backlog from anon, authenticated;
grant all on english.hindu_candidate_backlog to service_role;

comment on table english.hindu_candidate_backlog is
  'Server-side retention ledger for ChatGPT-scheduled Hindu/current-news proposals. PASS overflow is retained, not rejected; daily publication remains separately capped.';

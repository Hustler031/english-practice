-- Retain every submitted Hindu/current-news proposal and preserve every backend decision.
-- Daily publication remains separately capped by english.maintenance_apply_hindu_daily.
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
  unique(batch_date, submitted_index)
);

create index if not exists hindu_candidate_backlog_status_idx
  on english.hindu_candidate_backlog(status, batch_date desc);
create index if not exists hindu_candidate_backlog_run_idx
  on english.hindu_candidate_backlog(run_id, submitted_index);
create index if not exists hindu_candidate_backlog_word_idx
  on english.hindu_candidate_backlog(normalized_word, batch_date desc);

alter table english.hindu_candidate_backlog enable row level security;
revoke all on english.hindu_candidate_backlog from anon, authenticated;
grant all on english.hindu_candidate_backlog to service_role;

create or replace function public.english_hindu_candidate_backlog_upsert(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  x jsonb;
  v_count integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be an array';
  end if;
  if jsonb_array_length(p_rows) > 30 then
    raise exception 'At most 30 Hindu backlog rows are allowed';
  end if;

  for x in select value from jsonb_array_elements(p_rows) loop
    insert into english.hindu_candidate_backlog(
      batch_date,run_id,submitted_index,word,normalized_word,status,payload,
      quality_score,critic_decision,critic_model,rejection_stage,rejection_reason,updated_at
    ) values (
      (x->>'batchDate')::date,
      nullif(x->>'runId','')::uuid,
      (x->>'submittedIndex')::integer,
      coalesce(x->>'word',''),
      coalesce(x->>'normalizedWord',''),
      x->>'status',
      coalesce(x->'payload','{}'::jsonb),
      nullif(x->>'qualityScore','')::numeric,
      nullif(x->>'criticDecision',''),
      nullif(x->>'criticModel',''),
      nullif(x->>'rejectionStage',''),
      nullif(x->>'rejectionReason',''),
      now()
    )
    on conflict(batch_date,submitted_index) do update set
      run_id=excluded.run_id,
      word=excluded.word,
      normalized_word=excluded.normalized_word,
      status=excluded.status,
      payload=excluded.payload,
      quality_score=excluded.quality_score,
      critic_decision=excluded.critic_decision,
      critic_model=excluded.critic_model,
      rejection_stage=excluded.rejection_stage,
      rejection_reason=excluded.rejection_reason,
      updated_at=now();
    v_count:=v_count+1;
  end loop;

  return jsonb_build_object('ok',true,'count',v_count);
end
$function$;

revoke all on function public.english_hindu_candidate_backlog_upsert(jsonb) from public, anon, authenticated;
grant execute on function public.english_hindu_candidate_backlog_upsert(jsonb) to service_role;

comment on table english.hindu_candidate_backlog is
  'Server-side ledger for ChatGPT-scheduled Hindu/current-news proposals. Backend-approved overflow is accepted_retained, never rejected merely because the daily Hindu display is full.';

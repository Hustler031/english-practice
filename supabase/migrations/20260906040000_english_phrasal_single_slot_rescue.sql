-- English V2 Phrasal rescue: persist Central-selected slots one-by-one, preserve
-- exact-20 atomic publication, and protect the Antigravity free-tier request budget.

create table if not exists english.ai_provider_daily_budget (
  budget_date date not null,
  provider text not null,
  max_requests integer not null default 100 check (max_requests >= 0),
  reserve_requests integer not null default 0 check (reserve_requests >= 0),
  observed_used integer not null default 0 check (observed_used >= 0),
  internal_claims integer not null default 0 check (internal_claims >= 0),
  blocked_until timestamptz,
  block_reason text,
  last_claimed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (budget_date, provider),
  check (reserve_requests <= max_requests)
);

alter table english.ai_provider_daily_budget enable row level security;
revoke all on english.ai_provider_daily_budget from anon, authenticated;

-- The user reported 73/100 Antigravity requests already consumed on 2026-09-06.
-- Keep 12 untouched, so this backend can claim at most 15 more today.
insert into english.ai_provider_daily_budget(
  budget_date, provider, max_requests, reserve_requests, observed_used, internal_claims, updated_at
)
values ('2026-09-06'::date, 'antigravity', 100, 12, 73, 0, now())
on conflict (budget_date, provider) do update
set max_requests = excluded.max_requests,
    reserve_requests = greatest(english.ai_provider_daily_budget.reserve_requests, excluded.reserve_requests),
    observed_used = greatest(english.ai_provider_daily_budget.observed_used, excluded.observed_used),
    updated_at = now();

create or replace function public.english_claim_antigravity_request_budget()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  r english.ai_provider_daily_budget%rowtype;
  v_limit integer;
  v_used integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  insert into english.ai_provider_daily_budget(
    budget_date, provider, max_requests, reserve_requests, observed_used, internal_claims
  ) values (v_day, 'antigravity', 100, 0, 0, 0)
  on conflict (budget_date, provider) do nothing;

  select * into r
  from english.ai_provider_daily_budget
  where budget_date = v_day and provider = 'antigravity'
  for update;

  if r.blocked_until is not null and r.blocked_until > now() then
    return jsonb_build_object(
      'allowed', false,
      'route', 'gemini',
      'reason', coalesce(r.block_reason, 'antigravity circuit open'),
      'blockedUntil', r.blocked_until,
      'used', r.observed_used + r.internal_claims,
      'reserve', r.reserve_requests
    );
  end if;

  v_limit := greatest(0, r.max_requests - r.reserve_requests);
  v_used := r.observed_used + r.internal_claims;
  if v_used >= v_limit then
    return jsonb_build_object(
      'allowed', false,
      'route', 'gemini',
      'reason', 'ANTIGRAVITY_BUDGET_RESERVED',
      'used', v_used,
      'limitBeforeReserve', v_limit,
      'reserve', r.reserve_requests
    );
  end if;

  update english.ai_provider_daily_budget
  set internal_claims = internal_claims + 1,
      last_claimed_at = now(),
      updated_at = now()
  where budget_date = v_day and provider = 'antigravity';

  return jsonb_build_object(
    'allowed', true,
    'route', 'antigravity',
    'usedAfterClaim', v_used + 1,
    'limitBeforeReserve', v_limit,
    'remainingBeforeReserve', greatest(0, v_limit - (v_used + 1)),
    'reserve', r.reserve_requests
  );
end
$$;

create or replace function public.english_mark_antigravity_quota_exhausted(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_until timestamptz := ((v_day + 1)::timestamp at time zone 'Asia/Kolkata');
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  insert into english.ai_provider_daily_budget(
    budget_date, provider, max_requests, reserve_requests, observed_used, internal_claims,
    blocked_until, block_reason, updated_at
  ) values (
    v_day, 'antigravity', 100, 0, 0, 0,
    v_until, left(coalesce(p_reason, 'ANTIGRAVITY_429'), 800), now()
  )
  on conflict (budget_date, provider) do update
  set blocked_until = greatest(coalesce(english.ai_provider_daily_budget.blocked_until, '-infinity'::timestamptz), excluded.blocked_until),
      block_reason = excluded.block_reason,
      updated_at = now();

  return jsonb_build_object('ok', true, 'route', 'gemini', 'blockedUntil', v_until);
end
$$;

create or replace function public.english_get_ai_provider_budget_state()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  r english.ai_provider_daily_budget%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  select * into r from english.ai_provider_daily_budget
  where budget_date=v_day and provider='antigravity';
  if not found then return jsonb_build_object('date',v_day,'provider','antigravity','configured',false); end if;
  return jsonb_build_object(
    'date',r.budget_date,'provider',r.provider,'configured',true,
    'maxRequests',r.max_requests,'reserveRequests',r.reserve_requests,
    'observedUsed',r.observed_used,'internalClaims',r.internal_claims,
    'effectiveUsed',r.observed_used+r.internal_claims,
    'remainingBeforeReserve',greatest(0,(r.max_requests-r.reserve_requests)-(r.observed_used+r.internal_claims)),
    'blockedUntil',r.blocked_until,'blockReason',r.block_reason,'lastClaimedAt',r.last_claimed_at
  );
end
$$;

revoke all on function public.english_claim_antigravity_request_budget() from public, anon, authenticated;
revoke all on function public.english_mark_antigravity_quota_exhausted(text) from public, anon, authenticated;
revoke all on function public.english_get_ai_provider_budget_state() from public, anon, authenticated;
grant execute on function public.english_claim_antigravity_request_budget() to service_role;
grant execute on function public.english_mark_antigravity_quota_exhausted(text) to service_role;
grant execute on function public.english_get_ai_provider_budget_state() to service_role;

create table if not exists english.phrasal_generation_batches (
  batch_date date primary key,
  run_id uuid not null unique,
  source_id text not null,
  status text not null default 'building' check (status in ('building','ready','applied','abandoned')),
  selection jsonb not null,
  expected_count integer not null default 20 check (expected_count = 20),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  applied_at timestamptz
);

create table if not exists english.phrasal_generation_slots (
  batch_date date not null references english.phrasal_generation_batches(batch_date) on delete cascade,
  slot_no integer not null check (slot_no between 1 and 20),
  concept_id text not null,
  requested_family text not null,
  assignment jsonb not null,
  status text not null default 'pending' check (status in ('pending','processing','ready','failed')),
  finalized jsonb,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  lease_expires_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ready_at timestamptz,
  primary key (batch_date, slot_no),
  unique (batch_date, concept_id)
);

create index if not exists phrasal_generation_slots_work_idx
  on english.phrasal_generation_slots(batch_date,status,slot_no);

alter table english.phrasal_generation_batches enable row level security;
alter table english.phrasal_generation_slots enable row level security;
revoke all on english.phrasal_generation_batches from anon, authenticated;
revoke all on english.phrasal_generation_slots from anon, authenticated;

create or replace function public.english_phrasal_single_slot_claim()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_verify jsonb;
  v_batch jsonb;
  v_items jsonb;
  v_run uuid;
  v_source_id text := 'PHRASAL_DAILY_' || to_char(v_day,'YYYYMMDD');
  v_count integer;
  v_distinct integer;
  s english.phrasal_generation_slots%rowtype;
  v_ready integer;
  v_failed integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  perform pg_advisory_xact_lock(hashtext('english.phrasal_single_slot_'||v_day::text));

  v_verify := english.maintenance_verify_phrasal_daily();
  if coalesce((v_verify->>'ok')::boolean,false) then
    return jsonb_build_object('ok',true,'count',0,'complete',true,'verification',v_verify);
  end if;

  select run_id into v_run
  from english.phrasal_generation_batches
  where batch_date=v_day and status in ('building','ready');

  if v_run is null then
    v_batch := english.maintenance_phrasal_batch(20);
    v_items := coalesce(v_batch->'items','[]'::jsonb);
    v_count := jsonb_array_length(v_items);
    select count(distinct coalesce(nullif(value->>'phrasalConceptId',''),nullif(value->>'conceptId','')))
      into v_distinct
    from jsonb_array_elements(v_items);
    if v_count <> 20 or v_distinct <> 20 then
      raise exception 'Central Phrasal selection must contain exactly 20 distinct concepts; got %, %', v_count, v_distinct;
    end if;

    v_run := gen_random_uuid();
    insert into english.chatgpt_content_task_runs(run_id,lane,batch_date,status)
      values(v_run,'phrasal',v_day,'claimed');
    insert into english.phrasal_generation_batches(batch_date,run_id,source_id,status,selection,expected_count)
      values(v_day,v_run,v_source_id,'building',v_items,20);

    insert into english.phrasal_generation_slots(batch_date,slot_no,concept_id,requested_family,assignment)
    select v_day,
           ordinality::integer,
           coalesce(nullif(value->>'phrasalConceptId',''),nullif(value->>'conceptId','')),
           lower(coalesce(nullif(value->>'requestedQuestionFamily',''),nullif(value->>'missingFamily',''),nullif(value->>'phrasalQuestionFamily',''),'recognition')),
           value
    from jsonb_array_elements(v_items) with ordinality;
  end if;

  update english.phrasal_generation_slots
  set status='pending', lease_expires_at=null, updated_at=now(),
      last_error=coalesce(last_error,'processing lease expired')
  where batch_date=v_day and status='processing' and lease_expires_at < now();

  select * into s
  from english.phrasal_generation_slots
  where batch_date=v_day
    and status in ('pending','failed')
    and attempt_count < 3
  order by case status when 'pending' then 0 else 1 end, slot_no
  for update skip locked
  limit 1;

  select count(*) filter(where status='ready'), count(*) filter(where status='failed')
    into v_ready,v_failed
  from english.phrasal_generation_slots where batch_date=v_day;

  if not found then
    if v_ready=20 then
      update english.phrasal_generation_batches set status='ready',updated_at=now() where batch_date=v_day;
      return jsonb_build_object('ok',true,'count',0,'runId',v_run,'readyCount',v_ready,'publishReady',true);
    end if;
    return jsonb_build_object('ok',false,'count',0,'runId',v_run,'readyCount',v_ready,'failedCount',v_failed,'blocked',true,'reason','No retryable Phrasal slot remains');
  end if;

  update english.phrasal_generation_slots
  set status='processing',attempt_count=attempt_count+1,lease_expires_at=now()+interval '5 minutes',updated_at=now()
  where batch_date=v_day and slot_no=s.slot_no;

  return jsonb_build_object(
    'ok',true,'count',1,'runId',v_run,'batchDate',v_day,'sourceId',v_source_id,
    'slotNo',s.slot_no,'conceptId',s.concept_id,'requestedFamily',s.requested_family,
    'item',s.assignment,'readyCount',v_ready,'failedCount',v_failed,'remaining',20-v_ready
  );
end
$$;

create or replace function public.english_phrasal_single_slot_store(
  p_run_id uuid,
  p_slot_no integer,
  p_item jsonb default null,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  b english.phrasal_generation_batches%rowtype;
  s english.phrasal_generation_slots%rowtype;
  v_ready integer;
  v_failed integer;
  v_items jsonb;
  v_concept text;
  v_family text;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  select * into b from english.phrasal_generation_batches where run_id=p_run_id for update;
  if not found then raise exception 'Unknown Phrasal generation run'; end if;
  select * into s from english.phrasal_generation_slots where batch_date=b.batch_date and slot_no=p_slot_no for update;
  if not found then raise exception 'Unknown Phrasal generation slot'; end if;

  if nullif(btrim(coalesce(p_error,'')),'') is not null then
    update english.phrasal_generation_slots
    set status='failed',lease_expires_at=null,last_error=left(p_error,1200),updated_at=now()
    where batch_date=b.batch_date and slot_no=p_slot_no;
    update english.phrasal_generation_batches set last_error=left(p_error,1200),updated_at=now() where run_id=p_run_id;
  else
    if p_item is null or jsonb_typeof(p_item) <> 'object' then raise exception 'Finalized Phrasal item is required'; end if;
    v_concept := coalesce(nullif(p_item->>'conceptId',''),nullif(p_item->>'phrasalConceptId',''));
    v_family := lower(coalesce(nullif(p_item->>'requestedQuestionFamily',''),nullif(p_item->>'questionFamily',''),'recognition'));
    if v_concept <> s.concept_id then raise exception 'Phrasal slot concept drift: expected %, got %',s.concept_id,v_concept; end if;
    if v_family <> s.requested_family then raise exception 'Phrasal slot family drift: expected %, got %',s.requested_family,v_family; end if;
    update english.phrasal_generation_slots
    set status='ready',finalized=p_item,lease_expires_at=null,last_error=null,ready_at=now(),updated_at=now()
    where batch_date=b.batch_date and slot_no=p_slot_no;
  end if;

  select count(*) filter(where status='ready'), count(*) filter(where status='failed')
    into v_ready,v_failed
  from english.phrasal_generation_slots where batch_date=b.batch_date;

  if v_ready=20 then
    select jsonb_agg(finalized order by slot_no) into v_items
    from english.phrasal_generation_slots where batch_date=b.batch_date;
    update english.phrasal_generation_batches set status='ready',updated_at=now() where run_id=p_run_id;
  end if;

  return jsonb_build_object(
    'ok',p_error is null,'runId',p_run_id,'slotNo',p_slot_no,
    'readyCount',v_ready,'failedCount',v_failed,'remaining',20-v_ready,
    'publishReady',v_ready=20,
    'items',case when v_ready=20 then v_items else null end
  );
end
$$;

create or replace function public.english_phrasal_single_slot_mark_applied(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare v_changed integer;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  update english.phrasal_generation_batches
  set status='applied',applied_at=now(),updated_at=now(),last_error=null
  where run_id=p_run_id and status in ('ready','building');
  get diagnostics v_changed=row_count;
  return jsonb_build_object('ok',v_changed=1,'runId',p_run_id);
end
$$;

create or replace function public.english_phrasal_single_slot_reset_today(p_reason text default 'test cleanup')
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_run uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  select run_id into v_run from english.phrasal_generation_batches where batch_date=v_day for update;
  if v_run is null then return jsonb_build_object('ok',true,'reset',false,'reason','no staging batch'); end if;
  update english.chatgpt_content_task_runs
  set status='superseded',result=jsonb_build_object('released',true,'reason',left(coalesce(p_reason,'test cleanup'),800),'releasedAt',now()),updated_at=now()
  where run_id=v_run and lane='phrasal' and status='claimed';
  delete from english.phrasal_generation_batches where batch_date=v_day;
  return jsonb_build_object('ok',true,'reset',true,'runId',v_run);
end
$$;

revoke all on function public.english_phrasal_single_slot_claim() from public, anon, authenticated;
revoke all on function public.english_phrasal_single_slot_store(uuid,integer,jsonb,text) from public, anon, authenticated;
revoke all on function public.english_phrasal_single_slot_mark_applied(uuid) from public, anon, authenticated;
revoke all on function public.english_phrasal_single_slot_reset_today(text) from public, anon, authenticated;
grant execute on function public.english_phrasal_single_slot_claim() to service_role;
grant execute on function public.english_phrasal_single_slot_store(uuid,integer,jsonb,text) to service_role;
grant execute on function public.english_phrasal_single_slot_mark_applied(uuid) to service_role;
grant execute on function public.english_phrasal_single_slot_reset_today(text) to service_role;

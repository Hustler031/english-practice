-- Keep the exact-20 Phrasal lane moving after the daily scheduler creates the batch.
-- A successful checkpoint queues exactly one follow-up worker invocation after commit.
-- Failures do not self-loop; an hourly recovery kick retries incomplete work safely.

create or replace function public.english_phrasal_single_slot_store(
  p_run_id uuid,
  p_slot_no integer,
  p_item jsonb default null::jsonb,
  p_error text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $function$
declare
  b english.phrasal_generation_batches%rowtype;
  s english.phrasal_generation_slots%rowtype;
  v_ready integer;
  v_failed integer;
  v_items jsonb;
  v_concept text;
  v_family text;
  v_followup_request bigint;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select * into b
  from english.phrasal_generation_batches
  where run_id=p_run_id
  for update;
  if not found then raise exception 'Unknown Phrasal generation run'; end if;

  select * into s
  from english.phrasal_generation_slots
  where batch_date=b.batch_date and slot_no=p_slot_no
  for update;
  if not found then raise exception 'Unknown Phrasal generation slot'; end if;

  if nullif(btrim(coalesce(p_error,'')),'') is not null then
    update english.phrasal_generation_slots
      set status='failed', lease_expires_at=null, last_error=left(p_error,1200), updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
    update english.phrasal_generation_batches
      set last_error=left(p_error,1200), updated_at=now()
      where run_id=p_run_id;
  else
    if p_item is null or jsonb_typeof(p_item)<>'object' then
      raise exception 'Finalized Phrasal item is required';
    end if;

    v_concept:=coalesce(nullif(p_item->>'conceptId',''),nullif(p_item->>'phrasalConceptId',''));
    v_family:=lower(coalesce(nullif(p_item->>'requestedQuestionFamily',''),nullif(p_item->>'questionFamily',''),'recognition'));
    if v_concept<>s.concept_id then
      raise exception 'Phrasal slot concept drift: expected %, got %',s.concept_id,v_concept;
    end if;
    if v_family<>s.requested_family then
      raise exception 'Phrasal slot family drift: expected %, got %',s.requested_family,v_family;
    end if;

    update english.phrasal_generation_slots
      set status='ready', finalized=p_item, lease_expires_at=null, last_error=null, ready_at=now(), updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
  end if;

  select count(*) filter(where status='ready'), count(*) filter(where status='failed')
    into v_ready,v_failed
  from english.phrasal_generation_slots
  where batch_date=b.batch_date;

  if v_ready=20 then
    select jsonb_agg(finalized order by slot_no)
      into v_items
    from english.phrasal_generation_slots
    where batch_date=b.batch_date;
    update english.phrasal_generation_batches
      set status='ready', updated_at=now()
      where run_id=p_run_id;
  elsif nullif(btrim(coalesce(p_error,'')),'') is null then
    -- pg_net dispatch happens after this transaction commits, so the current
    -- lease is released before the next single-slot worker claims work.
    v_followup_request := english.kick_phrasal_worker();
  end if;

  return jsonb_build_object(
    'ok',p_error is null,
    'runId',p_run_id,
    'slotNo',p_slot_no,
    'readyCount',v_ready,
    'failedCount',v_failed,
    'remaining',20-v_ready,
    'publishReady',v_ready=20,
    'followupRequestId',v_followup_request,
    'items',case when v_ready=20 then v_items else null end
  );
end
$function$;

create or replace function english.kick_phrasal_recovery_if_needed()
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog', 'english'
as $function$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_status text;
  v_request bigint;
begin
  select status into v_status
  from english.phrasal_generation_batches
  where batch_date=v_day
  order by created_at desc
  limit 1;

  if v_status is distinct from 'applied' then
    v_request := english.kick_phrasal_worker();
    return v_request;
  end if;

  return null;
end
$function$;

revoke all on function english.kick_phrasal_recovery_if_needed() from public;
revoke all on function english.kick_phrasal_recovery_if_needed() from anon;
revoke all on function english.kick_phrasal_recovery_if_needed() from authenticated;
grant execute on function english.kick_phrasal_recovery_if_needed() to service_role;

-- :07 Asia/Kolkata every hour (minute 37 UTC). Normal successful batches
-- self-drain, so this is only a bounded recovery safety net.
do $do$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid from cron.job where jobname='english-phrasal-hourly-recovery';
  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
  perform cron.schedule(
    'english-phrasal-hourly-recovery',
    '37 * * * *',
    'select english.kick_phrasal_recovery_if_needed();'
  );
end
$do$;

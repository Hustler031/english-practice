alter table english.phrasal_generation_slots
  add column if not exists retry_after timestamptz,
  add column if not exists transient_failure_count integer not null default 0,
  add column if not exists last_error_class text;

create index if not exists idx_phrasal_generation_slots_retry_due
  on english.phrasal_generation_slots(batch_date,status,retry_after,slot_no);

create or replace function public.english_phrasal_single_slot_claim()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_verify jsonb; v_batch jsonb; v_items jsonb; v_run uuid;
  v_source_id text := 'PHRASAL_DAILY_' || to_char(v_day,'YYYYMMDD');
  v_count integer; v_distinct integer; v_ready integer; v_failed integer;
  v_next_retry timestamptz;
  v_has_slot boolean := false;
  s english.phrasal_generation_slots%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  perform pg_advisory_xact_lock(hashtext('english.phrasal_single_slot_'||v_day::text));

  v_verify := english.maintenance_verify_phrasal_daily();
  if coalesce((v_verify->>'ok')::boolean,false) then
    return jsonb_build_object('ok',true,'count',0,'complete',true,'verification',v_verify);
  end if;

  select run_id into v_run from english.phrasal_generation_batches
  where batch_date=v_day and status in ('building','ready');

  if v_run is null then
    if exists(select 1 from english.phrasal_generation_batches where batch_date=v_day and status='applied') then
      raise exception 'Applied Phrasal staging batch exists but daily verification is not complete';
    end if;
    v_batch := english.maintenance_phrasal_batch(20);
    v_items := coalesce(v_batch->'items','[]'::jsonb);
    v_count := jsonb_array_length(v_items);
    select count(distinct coalesce(nullif(value->>'phrasalConceptId',''),nullif(value->>'conceptId','')))
      into v_distinct from jsonb_array_elements(v_items);
    if v_count <> 20 or v_distinct <> 20 then
      raise exception 'Central Phrasal selection must contain exactly 20 distinct concepts; got %, %',v_count,v_distinct;
    end if;
    v_run := gen_random_uuid();
    insert into english.chatgpt_content_task_runs(run_id,lane,batch_date,status) values(v_run,'phrasal',v_day,'claimed');
    insert into english.phrasal_generation_batches(batch_date,run_id,source_id,status,selection,expected_count)
      values(v_day,v_run,v_source_id,'building',v_items,20);
    insert into english.phrasal_generation_slots(batch_date,slot_no,concept_id,requested_family,assignment)
    select v_day,ordinality::integer,
      coalesce(nullif(value->>'phrasalConceptId',''),nullif(value->>'conceptId','')),
      lower(coalesce(nullif(value->>'requestedQuestionFamily',''),nullif(value->>'missingFamily',''),nullif(value->>'phrasalQuestionFamily',''),'recognition')),
      value
    from jsonb_array_elements(v_items) with ordinality;
  end if;

  update english.phrasal_generation_slots
  set status='pending',
      attempt_count=greatest(attempt_count-1,0),
      transient_failure_count=transient_failure_count+1,
      lease_expires_at=null,
      retry_after=now()+interval '15 minutes',
      last_error_class='lease_timeout',
      last_error=coalesce(last_error,'processing lease expired'),
      updated_at=now()
  where batch_date=v_day and status='processing' and lease_expires_at<now();

  select * into s from english.phrasal_generation_slots
  where batch_date=v_day
    and (
      (status='pending' and (retry_after is null or retry_after<=now()))
      or (status='failed' and attempt_count<3 and (retry_after is null or retry_after<=now()))
    )
  order by case status when 'pending' then 0 else 1 end,slot_no
  for update skip locked limit 1;
  v_has_slot := found;

  select count(*) filter(where status='ready'),count(*) filter(where status='failed'),min(retry_after) filter(where status in ('pending','failed') and retry_after>now())
    into v_ready,v_failed,v_next_retry from english.phrasal_generation_slots where batch_date=v_day;

  if not v_has_slot then
    if v_ready=20 then
      select jsonb_agg(finalized order by slot_no) into v_items
      from english.phrasal_generation_slots where batch_date=v_day;
      update english.phrasal_generation_batches set status='ready',updated_at=now() where batch_date=v_day;
      return jsonb_build_object('ok',true,'count',0,'runId',v_run,'readyCount',v_ready,'publishReady',true,'items',v_items);
    end if;
    return jsonb_build_object(
      'ok',false,'count',0,'runId',v_run,'readyCount',v_ready,'failedCount',v_failed,
      'waiting',v_next_retry is not null,'nextRetryAt',v_next_retry,
      'blocked',v_next_retry is null,
      'reason',case when v_next_retry is not null then 'Phrasal generation waiting for retry window' else 'No retryable Phrasal slot remains' end
    );
  end if;

  update english.phrasal_generation_slots
  set status='processing',attempt_count=attempt_count+1,lease_expires_at=now()+interval '5 minutes',retry_after=null,updated_at=now()
  where batch_date=v_day and slot_no=s.slot_no;

  return jsonb_build_object('ok',true,'count',1,'runId',v_run,'batchDate',v_day,'sourceId',v_source_id,
    'slotNo',s.slot_no,'conceptId',s.concept_id,'requestedFamily',s.requested_family,'item',s.assignment,
    'readyCount',v_ready,'failedCount',v_failed,'remaining',20-v_ready);
end
$$;

create or replace function public.english_phrasal_single_slot_store(
  p_run_id uuid,p_slot_no integer,p_item jsonb default null::jsonb,p_error text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  b english.phrasal_generation_batches%rowtype;
  s english.phrasal_generation_slots%rowtype;
  v_ready integer;
  v_failed integer;
  v_items jsonb;
  v_concept text;
  v_family text;
  v_followup_request bigint;
  v_error text;
  v_transient boolean:=false;
  v_delay_minutes integer:=15;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;

  select * into b from english.phrasal_generation_batches where run_id=p_run_id for update;
  if not found then raise exception 'Unknown Phrasal generation run'; end if;

  select * into s from english.phrasal_generation_slots
  where batch_date=b.batch_date and slot_no=p_slot_no for update;
  if not found then raise exception 'Unknown Phrasal generation slot'; end if;

  if nullif(btrim(coalesce(p_error,'')),'') is not null then
    v_error:=lower(btrim(p_error));
    v_transient :=
      v_error like '%429%'
      or v_error like '%quota%'
      or v_error like '%rate limit%'
      or v_error like '%resource exhausted%'
      or v_error like '%timed out%'
      or v_error like '%timeout%'
      or v_error like '%temporarily unavailable%'
      or v_error like '%overloaded%'
      or v_error like '%502%'
      or v_error like '%503%';

    if v_transient then
      v_delay_minutes:=case
        when s.transient_failure_count<=0 then 15
        when s.transient_failure_count=1 then 30
        else 60
      end;
      update english.phrasal_generation_slots
      set status='pending',
          attempt_count=greatest(attempt_count-1,0),
          transient_failure_count=transient_failure_count+1,
          lease_expires_at=null,
          retry_after=now()+make_interval(mins=>v_delay_minutes),
          last_error=left(p_error,1200),
          last_error_class='transient',
          updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
    else
      update english.phrasal_generation_slots
      set status='failed',
          lease_expires_at=null,
          retry_after=now()+interval '1 hour',
          last_error=left(p_error,1200),
          last_error_class='hard',
          updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
    end if;

    update english.phrasal_generation_batches
    set status='building',last_error=left(p_error,1200),updated_at=now()
    where run_id=p_run_id;
  else
    if p_item is null or jsonb_typeof(p_item)<>'object' then raise exception 'Finalized Phrasal item is required'; end if;
    if coalesce((p_item->>'availabilityFallback')::boolean,false) then
      raise exception 'Availability fallback items are not publishable Phrasal content';
    end if;

    v_concept:=coalesce(nullif(p_item->>'conceptId',''),nullif(p_item->>'phrasalConceptId',''));
    v_family:=lower(coalesce(nullif(p_item->>'requestedQuestionFamily',''),nullif(p_item->>'questionFamily',''),'recognition'));

    if v_concept<>s.concept_id then raise exception 'Phrasal slot concept drift: expected %, got %',s.concept_id,v_concept; end if;
    if v_family<>s.requested_family then raise exception 'Phrasal slot family drift: expected %, got %',s.requested_family,v_family; end if;

    update english.phrasal_generation_slots
    set status='ready',finalized=p_item,lease_expires_at=null,retry_after=null,last_error=null,last_error_class=null,ready_at=now(),updated_at=now()
    where batch_date=b.batch_date and slot_no=p_slot_no;
  end if;

  select count(*) filter(where status='ready'),count(*) filter(where status='failed')
    into v_ready,v_failed from english.phrasal_generation_slots where batch_date=b.batch_date;

  if v_ready=20 then
    select jsonb_agg(finalized order by slot_no) into v_items
    from english.phrasal_generation_slots where batch_date=b.batch_date;
    update english.phrasal_generation_batches set status='ready',last_error=null,updated_at=now() where run_id=p_run_id;
  elsif nullif(btrim(coalesce(p_error,'')),'') is null then
    v_followup_request:=english.kick_phrasal_worker();
  end if;

  return jsonb_build_object(
    'ok',p_error is null,'runId',p_run_id,'slotNo',p_slot_no,'readyCount',v_ready,'failedCount',v_failed,
    'remaining',20-v_ready,'publishReady',v_ready=20,'followupRequestId',v_followup_request,
    'transientFailure',v_transient,
    'items',case when v_ready=20 then v_items else null end
  );
end
$$;

create or replace function english.kick_phrasal_recovery_if_needed()
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_status text;
  v_request bigint;
  v_due boolean:=false;
begin
  select status into v_status
  from english.phrasal_generation_batches
  where batch_date=v_day
  order by created_at desc
  limit 1;

  if v_status='applied' then return null; end if;
  if v_status is null or v_status='ready' then
    return english.kick_phrasal_worker();
  end if;

  select exists(
    select 1 from english.phrasal_generation_slots s
    where s.batch_date=v_day and (
      (s.status='pending' and (s.retry_after is null or s.retry_after<=now()))
      or (s.status='failed' and s.attempt_count<3 and (s.retry_after is null or s.retry_after<=now()))
      or (s.status='processing' and s.lease_expires_at<now())
    )
  ) into v_due;

  if v_due then
    v_request:=english.kick_phrasal_worker();
    return v_request;
  end if;
  return null;
end
$$;

create or replace function public.english_phrasal_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  b english.phrasal_generation_batches%rowtype;
  v_apply jsonb; v_verify jsonb; v_day date;
  v_total integer; v_mapped integer; v_antigravity integer; v_legacy integer; v_deterministic integer;
  v_ready integer; v_invalid integer; v_staged_items jsonb;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='phrasal' for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  select * into b from english.phrasal_generation_batches where run_id=p_run_id for update;
  if not found then raise exception 'Phrasal generation batch not found'; end if;
  v_day:=b.batch_date;
  if b.status<>'ready' then raise exception 'Phrasal batch is not production-ready: %',b.status; end if;

  select count(*) filter(where s.status='ready'),
         count(*) filter(where s.status<>'ready' or s.finalized is null
           or coalesce((s.finalized->>'availabilityFallback')::boolean,false)
           or lower(coalesce(nullif(s.finalized->>'requestedQuestionFamily',''),nullif(s.finalized->>'questionFamily',''),'recognition'))<>s.requested_family)
    into v_ready,v_invalid
  from english.phrasal_generation_slots s where s.batch_date=v_day;

  if v_ready<>20 or v_invalid<>0 then
    raise exception 'Phrasal production gate failed: ready %, invalid %',v_ready,v_invalid;
  end if;

  select jsonb_agg(finalized order by slot_no) into v_staged_items
  from english.phrasal_generation_slots where batch_date=v_day;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))<>20 or p_items is distinct from v_staged_items then
    raise exception 'Phrasal apply payload does not exactly match the 20 production-ready staged slots';
  end if;

  v_apply:=english.maintenance_apply_phrasal_hybrid(p_items);
  insert into english.question_concept_mappings(question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type)
  select distinct q.question_id,d.concept_id,1,'deterministic_metadata','mapped','primary'
  from english.phrasal_daily_items d join english.questions q on q.question_id=d.question_id and q.active join english.concepts c on c.concept_id=d.concept_id and c.active
  where d.batch_date=v_day
  on conflict(question_id) do update set concept_id=excluded.concept_id,mapping_confidence=1,mapping_method='deterministic_metadata',review_status='mapped',relation_type='primary',updated_at=now();

  v_verify:=english.maintenance_verify_phrasal_daily();
  select count(*) into v_total from english.phrasal_daily_items where batch_date=v_day;
  select count(*) into v_mapped from english.phrasal_daily_items d join english.question_concept_mappings m on m.question_id=d.question_id and m.concept_id=d.concept_id where d.batch_date=v_day;
  select count(*) filter(where lower(coalesce(generator_provider,''))='antigravity'),
         count(*) filter(where lower(coalesce(generator_provider,''))='legacy_bank'),
         count(*) filter(where lower(coalesce(generator_provider,''))='deterministic_recall')
    into v_antigravity,v_legacy,v_deterministic from english.phrasal_daily_items where batch_date=v_day;
  update english.sources
  set notes='Central-selected adaptive Phrasal batch. Permanent identity reuse: '||v_legacy||' legacy-bank slots reused existing Question_IDs; '||v_antigravity||' Antigravity variants; '||v_deterministic||' deterministic recall fillers.'
  where source_id='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');

  if not coalesce((v_verify->>'ok')::boolean,false) or v_total<>20 or v_mapped<>20 then
    raise exception 'Phrasal verification/Central Intelligence mapping failed: memberships %, mapped %',v_total,v_mapped;
  end if;

  update english.chatgpt_content_task_runs
  set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify,'centralMapped',v_mapped,'productionReady',20),applied_at=now(),updated_at=now()
  where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify,'centralMapped',v_mapped,'productionReady',20);
end
$$;

create or replace function public.english_phrasal_single_slot_mark_applied(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_changed integer;
  v_day date;
  v_ready integer;
  v_invalid integer;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  select batch_date into v_day from english.phrasal_generation_batches where run_id=p_run_id and status='ready' for update;
  if not found then raise exception 'Phrasal generation batch is not ready'; end if;

  select count(*) filter(where status='ready'),
         count(*) filter(where status<>'ready' or finalized is null
           or coalesce((finalized->>'availabilityFallback')::boolean,false)
           or lower(coalesce(nullif(finalized->>'requestedQuestionFamily',''),nullif(finalized->>'questionFamily',''),'recognition'))<>requested_family)
    into v_ready,v_invalid
  from english.phrasal_generation_slots where batch_date=v_day;
  if v_ready<>20 or v_invalid<>0 then raise exception 'Cannot mark Phrasal applied before 20 production-ready slots'; end if;
  if not exists(select 1 from english.chatgpt_content_task_runs where run_id=p_run_id and lane='phrasal' and status='applied') then
    raise exception 'Phrasal content task is not verified/applied';
  end if;

  update english.phrasal_generation_batches
  set status='applied',applied_at=now(),updated_at=now(),last_error=null
  where run_id=p_run_id and status='ready';
  get diagnostics v_changed=row_count;
  return jsonb_build_object('ok',v_changed=1,'runId',p_run_id,'productionReady',20);
end
$$;

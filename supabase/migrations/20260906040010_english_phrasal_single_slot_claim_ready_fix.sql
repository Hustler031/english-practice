create or replace function public.english_phrasal_single_slot_claim()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_verify jsonb; v_batch jsonb; v_items jsonb; v_run uuid;
  v_source_id text := 'PHRASAL_DAILY_' || to_char(v_day,'YYYYMMDD');
  v_count integer; v_distinct integer; v_ready integer; v_failed integer;
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
  set status='pending',lease_expires_at=null,updated_at=now(),last_error=coalesce(last_error,'processing lease expired')
  where batch_date=v_day and status='processing' and lease_expires_at<now();

  select * into s from english.phrasal_generation_slots
  where batch_date=v_day and status in ('pending','failed') and attempt_count<3
  order by case status when 'pending' then 0 else 1 end,slot_no
  for update skip locked limit 1;
  v_has_slot := found;

  select count(*) filter(where status='ready'),count(*) filter(where status='failed')
    into v_ready,v_failed from english.phrasal_generation_slots where batch_date=v_day;

  if not v_has_slot then
    if v_ready=20 then
      select jsonb_agg(finalized order by slot_no) into v_items
      from english.phrasal_generation_slots where batch_date=v_day;
      update english.phrasal_generation_batches set status='ready',updated_at=now() where batch_date=v_day;
      return jsonb_build_object('ok',true,'count',0,'runId',v_run,'readyCount',v_ready,'publishReady',true,'items',v_items);
    end if;
    return jsonb_build_object('ok',false,'count',0,'runId',v_run,'readyCount',v_ready,'failedCount',v_failed,'blocked',true,'reason','No retryable Phrasal slot remains');
  end if;

  update english.phrasal_generation_slots
  set status='processing',attempt_count=attempt_count+1,lease_expires_at=now()+interval '5 minutes',updated_at=now()
  where batch_date=v_day and slot_no=s.slot_no;

  return jsonb_build_object('ok',true,'count',1,'runId',v_run,'batchDate',v_day,'sourceId',v_source_id,
    'slotNo',s.slot_no,'conceptId',s.concept_id,'requestedFamily',s.requested_family,'item',s.assignment,
    'readyCount',v_ready,'failedCount',v_failed,'remaining',20-v_ready);
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
  v_run uuid; v_status text;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  select run_id,status into v_run,v_status from english.phrasal_generation_batches where batch_date=v_day for update;
  if v_run is null then return jsonb_build_object('ok',true,'reset',false,'reason','no staging batch'); end if;
  if v_status='applied' then raise exception 'Applied Phrasal batch cannot be reset by test cleanup'; end if;
  update english.chatgpt_content_task_runs
  set status='superseded',result=jsonb_build_object('released',true,'reason',left(coalesce(p_reason,'test cleanup'),800),'releasedAt',now()),updated_at=now()
  where run_id=v_run and lane='phrasal' and status='claimed';
  delete from english.phrasal_generation_batches where batch_date=v_day;
  return jsonb_build_object('ok',true,'reset',true,'runId',v_run);
end
$$;

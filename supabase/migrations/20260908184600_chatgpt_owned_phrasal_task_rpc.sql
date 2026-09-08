create or replace function public.english_phrasal_task_claim()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
set statement_timeout to '120s'
as $function$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_verify jsonb;
  v_batch jsonb;
  v_run uuid;
  v_active uuid;
  v_selection jsonb;
  v_source_id text;
  v_existing_daily integer;
begin
  perform pg_advisory_xact_lock(hashtext('english.phrasal_chatgpt_task'));

  v_verify := english.maintenance_verify_phrasal_daily();
  if coalesce((v_verify->>'ok')::boolean,false) then
    return jsonb_build_object('ok',true,'count',0,'complete',true,'verification',v_verify);
  end if;

  select count(*) into v_existing_daily
  from english.phrasal_daily_items
  where batch_date=v_day;
  if v_existing_daily>0 then
    raise exception 'Partial Phrasal daily membership exists for %; refusing a second materialization',v_day;
  end if;

  update english.chatgpt_content_task_runs
  set status='superseded',updated_at=now()
  where lane='phrasal' and batch_date=v_day and status='claimed'
    and created_at<now()-interval '2 hours';

  select run_id into v_active
  from english.chatgpt_content_task_runs
  where lane='phrasal' and batch_date=v_day and status='claimed'
  order by created_at desc
  limit 1;

  if v_active is not null then
    select selection,source_id into v_selection,v_source_id
    from english.phrasal_generation_batches
    where run_id=v_active and batch_date=v_day
    limit 1;

    if jsonb_typeof(coalesce(v_selection,'null'::jsonb))='array'
       and jsonb_array_length(v_selection)=20 then
      return jsonb_build_object(
        'ok',true,'date',v_day,'sourceId',v_source_id,'sourceFile','Phrasal Daily '||to_char(v_day,'YYYY-MM-DD'),
        'count',20,'existingToday',0,'items',v_selection,'runId',v_active,'busy',false,'resumed',true
      );
    end if;
    v_run:=v_active;
  else
    v_run:=gen_random_uuid();
    insert into english.chatgpt_content_task_runs(run_id,lane,batch_date,status)
    values(v_run,'phrasal',v_day,'claimed');
  end if;

  v_batch:=english.maintenance_phrasal_batch(20);
  v_selection:=coalesce(v_batch->'items','[]'::jsonb);
  v_source_id:=coalesce(nullif(v_batch->>'sourceId',''),'PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD'));
  if jsonb_array_length(v_selection)<>20 then
    raise exception 'Central Phrasal selector did not return exactly 20 slots';
  end if;

  insert into english.phrasal_generation_batches(
    batch_date,run_id,source_id,status,selection,expected_count,last_error,created_at,updated_at,applied_at
  ) values(
    v_day,v_run,v_source_id,'building',v_selection,20,null,now(),now(),null
  )
  on conflict(batch_date) do update set
    run_id=excluded.run_id,source_id=excluded.source_id,status='building',selection=excluded.selection,
    expected_count=20,last_error=null,updated_at=now(),applied_at=null
  where english.phrasal_generation_batches.status<>'applied';

  insert into english.phrasal_generation_slots(
    batch_date,slot_no,concept_id,requested_family,assignment,status,finalized,attempt_count,
    lease_expires_at,last_error,created_at,updated_at,ready_at,retry_after,transient_failure_count,last_error_class
  )
  select
    v_day,e.ordinality::integer,
    btrim(coalesce(nullif(e.value->>'phrasalConceptId',''),nullif(e.value->>'conceptId',''))),
    lower(coalesce(nullif(e.value->>'requestedQuestionFamily',''),nullif(e.value->>'missingFamily',''),nullif(e.value->>'phrasalQuestionFamily',''),'recognition')),
    e.value,'pending',null,0,null,null,now(),now(),null,null,0,null
  from jsonb_array_elements(v_selection) with ordinality e(value,ordinality)
  on conflict(batch_date,slot_no) do update set
    concept_id=excluded.concept_id,requested_family=excluded.requested_family,assignment=excluded.assignment,
    status='pending',finalized=null,attempt_count=0,lease_expires_at=null,last_error=null,
    updated_at=now(),ready_at=null,retry_after=null,transient_failure_count=0,last_error_class=null;

  if exists(
    select 1 from english.phrasal_generation_slots
    where batch_date=v_day and btrim(coalesce(concept_id,''))=''
  ) then
    raise exception 'Central Phrasal selection contains a slot without concept identity';
  end if;

  return v_batch||jsonb_build_object('runId',v_run,'busy',false,'mode','chatgpt_owned');
end
$function$;

create or replace function public.english_phrasal_task_ingest(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
set statement_timeout to '120s'
as $function$
declare
  r english.chatgpt_content_task_runs%rowtype;
  b english.phrasal_generation_batches%rowtype;
  v_item jsonb;
  v_selection_item jsonb;
  v_ord bigint;
  v_expected_concept text;
  v_given_concept text;
  v_expected_family text;
  v_given_family text;
  v_provider text;
  v_updated integer;
  v_applied jsonb;
  v_legacy integer:=0;
  v_chatgpt integer:=0;
  v_source_id text;
begin
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)<>20 then
    raise exception 'Phrasal ingest requires exactly 20 finalized items';
  end if;

  select * into r
  from english.chatgpt_content_task_runs
  where run_id=p_run_id and lane='phrasal'
  for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then
    return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true))
      ||jsonb_build_object('runId',p_run_id,'mode','chatgpt_owned');
  end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  select * into b
  from english.phrasal_generation_batches
  where run_id=p_run_id and batch_date=r.batch_date
  for update;
  if not found or jsonb_array_length(coalesce(b.selection,'[]'::jsonb))<>20 then
    raise exception 'Phrasal staged Central selection is missing or incomplete';
  end if;

  for v_item,v_ord in
    select e.value,e.ordinality from jsonb_array_elements(p_items) with ordinality e(value,ordinality)
  loop
    select e.value into v_selection_item
    from jsonb_array_elements(b.selection) with ordinality e(value,ordinality)
    where e.ordinality=v_ord;

    v_expected_concept:=btrim(coalesce(nullif(v_selection_item->>'phrasalConceptId',''),nullif(v_selection_item->>'conceptId','')));
    v_given_concept:=btrim(coalesce(v_item->>'conceptId',''));
    if v_expected_concept='' or v_given_concept<>v_expected_concept then
      raise exception 'Phrasal slot % Central concept mismatch',v_ord;
    end if;

    v_expected_family:=lower(coalesce(nullif(v_selection_item->>'requestedQuestionFamily',''),nullif(v_selection_item->>'missingFamily',''),nullif(v_selection_item->>'phrasalQuestionFamily',''),'recognition'));
    v_given_family:=lower(coalesce(nullif(v_item->>'requestedQuestionFamily',''),nullif(v_item->>'questionFamily',''),nullif(v_item->>'family',''),'recognition'));
    if v_given_family<>v_expected_family then
      raise exception 'Phrasal slot % requested family mismatch: expected %, got %',v_ord,v_expected_family,v_given_family;
    end if;

    v_provider:=lower(btrim(coalesce(v_item->>'generatorProvider','')));
    if v_provider not in ('legacy_bank','chatgpt') then
      raise exception 'Phrasal slot % provider must be legacy_bank or chatgpt',v_ord;
    end if;
    if v_provider='legacy_bank' then
      v_legacy:=v_legacy+1;
      if btrim(coalesce(v_item->>'baseQuestionId',''))='' then
        raise exception 'Phrasal slot % legacy item missing baseQuestionId',v_ord;
      end if;
    else
      v_chatgpt:=v_chatgpt+1;
      if lower(btrim(coalesce(v_item->>'criticProvider',''))) <> 'chatgpt_self_critic' then
        raise exception 'Phrasal slot % ChatGPT item missing self-critic provenance',v_ord;
      end if;
      if not english.generated_item_hard_gates_pass(v_item) then
        raise exception 'Phrasal slot % ChatGPT self-critic hard gates failed',v_ord;
      end if;
    end if;
  end loop;

  update english.phrasal_generation_slots s
  set finalized=e.value,status='ready',attempt_count=greatest(s.attempt_count,1),lease_expires_at=null,
      last_error=null,updated_at=now(),ready_at=now(),retry_after=null,transient_failure_count=0,last_error_class=null
  from jsonb_array_elements(p_items) with ordinality e(value,ordinality)
  where s.batch_date=b.batch_date and s.slot_no=e.ordinality;
  get diagnostics v_updated=row_count;
  if v_updated<>20 then raise exception 'Phrasal ingest staged % of 20 slots',v_updated; end if;

  update english.phrasal_generation_batches
  set status='ready',last_error=null,updated_at=now()
  where run_id=p_run_id;

  v_applied:=public.english_phrasal_task_apply(p_run_id,p_items);

  update english.phrasal_generation_batches
  set status='applied',applied_at=coalesce(applied_at,now()),last_error=null,updated_at=now()
  where run_id=p_run_id;

  v_source_id:='PHRASAL_DAILY_'||to_char(b.batch_date,'YYYYMMDD');
  update english.sources
  set notes='Central-selected adaptive Phrasal batch. '||v_legacy||' existing canonical questions reused with permanent Question_IDs; '
      ||v_chatgpt||' ChatGPT-owned variants generated after final-payload self-critic. Server-side Phrasal AI generation was not used.'
  where source_id=v_source_id;

  return coalesce(v_applied,jsonb_build_object('ok',true))
    ||jsonb_build_object('ok',true,'runId',p_run_id,'mode','chatgpt_owned','reused',v_legacy,'generatedByChatGPT',v_chatgpt);
end
$function$;

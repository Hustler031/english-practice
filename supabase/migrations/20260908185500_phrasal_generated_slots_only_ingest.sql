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
  v_selection_item jsonb;
  v_item jsonb;
  v_rv jsonb;
  v_final_items jsonb:='[]'::jsonb;
  v_ord integer;
  v_count integer;
  v_distinct integer;
  v_expected_concept text;
  v_expected_family text;
  v_legacy_family text;
  v_required boolean;
  v_option_a text;
  v_option_b text;
  v_option_c text;
  v_option_d text;
  v_correct text;
  v_updated integer;
  v_applied jsonb;
  v_legacy integer:=0;
  v_chatgpt integer:=0;
  v_source_id text;
begin
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)>20 then
    raise exception 'Phrasal ingest requires an array of 0-20 ChatGPT-generated slot overrides';
  end if;

  select count(*),count(distinct (e.value->>'slotNo')::integer)
  into v_count,v_distinct
  from jsonb_array_elements(p_items) e(value);
  if v_count<>v_distinct then raise exception 'Phrasal submitted slotNo values must be unique'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e(value) where (e.value->>'slotNo')::integer not between 1 and 20) then
    raise exception 'Phrasal submitted slotNo must be between 1 and 20';
  end if;

  select * into r from english.chatgpt_content_task_runs
  where run_id=p_run_id and lane='phrasal' for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then
    return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true))
      ||jsonb_build_object('runId',p_run_id,'mode','chatgpt_owned');
  end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  select * into b from english.phrasal_generation_batches
  where run_id=p_run_id and batch_date=r.batch_date for update;
  if not found or jsonb_array_length(coalesce(b.selection,'[]'::jsonb))<>20 then
    raise exception 'Phrasal staged Central selection is missing or incomplete';
  end if;

  for v_ord in 1..20 loop
    v_selection_item:=b.selection->(v_ord-1);
    v_expected_concept:=btrim(coalesce(nullif(v_selection_item->>'phrasalConceptId',''),nullif(v_selection_item->>'conceptId','')));
    v_expected_family:=lower(coalesce(nullif(v_selection_item->>'requestedQuestionFamily',''),nullif(v_selection_item->>'missingFamily',''),nullif(v_selection_item->>'phrasalQuestionFamily',''),'recognition'));
    v_legacy_family:=lower(coalesce(nullif(v_selection_item->>'legacyFamily',''),nullif(v_selection_item->>'phrasalQuestionFamily',''),v_expected_family));
    v_required:=coalesce((v_selection_item->>'contentGap')::boolean,false)
      or lower(coalesce(v_selection_item->>'slotStatus',''))='content_gap'
      or v_expected_family<>v_legacy_family;

    select e.value into v_item
    from jsonb_array_elements(p_items) e(value)
    where (e.value->>'slotNo')::integer=v_ord
    limit 1;

    if v_item is null then
      if v_required then raise exception 'Phrasal slot % requires a ChatGPT-generated % variant',v_ord,v_expected_family; end if;
      v_rv:=v_selection_item->'referenceVariant';
      if jsonb_typeof(coalesce(v_rv,'null'::jsonb))<>'object' or btrim(coalesce(v_rv->>'id',''))='' then
        raise exception 'Phrasal slot % has no exact legacy referenceVariant to reuse',v_ord;
      end if;
      select value->>'text' into v_option_a from jsonb_array_elements(coalesce(v_rv->'options','[]'::jsonb)) where value->>'key'='A' limit 1;
      select value->>'text' into v_option_b from jsonb_array_elements(coalesce(v_rv->'options','[]'::jsonb)) where value->>'key'='B' limit 1;
      select value->>'text' into v_option_c from jsonb_array_elements(coalesce(v_rv->'options','[]'::jsonb)) where value->>'key'='C' limit 1;
      select value->>'text' into v_option_d from jsonb_array_elements(coalesce(v_rv->'options','[]'::jsonb)) where value->>'key'='D' limit 1;
      v_item:=jsonb_build_object(
        'slotNo',v_ord,
        'word',coalesce(v_rv->>'word',''),
        'senseKey',coalesce(nullif(v_selection_item->>'senseKey',''),'legacy_default'),
        'senseGloss',coalesce(v_selection_item->>'senseGloss',''),
        'question',coalesce(v_rv->>'question',''),
        'questionType',coalesce(v_rv->>'questionType','Meaning'),
        'optionA',coalesce(v_option_a,''),'optionB',coalesce(v_option_b,''),'optionC',coalesce(v_option_c,''),'optionD',coalesce(v_option_d,''),
        'correctKey',coalesce(v_rv->>'correctKey',''),
        'explanation',coalesce(v_rv->>'explanation',''),
        'tip',coalesce(v_rv->>'tip',''),'usageNote',coalesce(v_rv->>'usageNote',''),'example',coalesce(v_rv->>'example',''),
        'memoryAid',coalesce(v_rv->>'memoryAid',''),'related',coalesce(v_rv->>'related',''),'difficulty',coalesce(v_rv->>'difficulty','Medium'),
        'sourcePage',coalesce(v_rv->>'sourcePage',''),'sourceUrl',coalesce(v_rv->>'sourceUrl',''),
        'conceptId',v_expected_concept,'legacyFamily',v_legacy_family,'family',v_legacy_family,
        'requestedQuestionFamily',v_expected_family,'questionFamily',v_expected_family,
        'baseQuestionId',v_rv->>'id','contentGap',false,
        'generatorProvider','legacy_bank','generatorModel','canonical_bank','repairCount',0,'codeRepairCount',0,'rareRescue',false
      );
      v_legacy:=v_legacy+1;
    else
      if lower(btrim(coalesce(v_item->>'generatorProvider',''))) <> 'chatgpt' then
        raise exception 'Phrasal slot % submitted override must be generatorProvider=chatgpt',v_ord;
      end if;
      if btrim(coalesce(v_item->>'conceptId',''))<>v_expected_concept then raise exception 'Phrasal slot % Central concept mismatch',v_ord; end if;
      if lower(coalesce(nullif(v_item->>'requestedQuestionFamily',''),nullif(v_item->>'questionFamily',''),''))<>v_expected_family then
        raise exception 'Phrasal slot % requested family mismatch',v_ord;
      end if;
      if btrim(coalesce(v_item->>'word',''))='' or btrim(coalesce(v_item->>'senseKey',''))='' or btrim(coalesce(v_item->>'senseGloss',''))='' then
        raise exception 'Phrasal slot % ChatGPT target word and sense metadata are required',v_ord;
      end if;
      if btrim(coalesce(v_item->>'question',''))='' or btrim(coalesce(v_item->>'explanation',''))='' then
        raise exception 'Phrasal slot % ChatGPT question/explanation required',v_ord;
      end if;
      if lower(btrim(coalesce(v_item->>'criticProvider',''))) <> 'chatgpt_self_critic' then raise exception 'Phrasal slot % missing ChatGPT self-critic provenance',v_ord; end if;
      if not english.generated_item_hard_gates_pass(v_item) then raise exception 'Phrasal slot % ChatGPT self-critic hard gates failed',v_ord; end if;

      v_correct:=upper(btrim(coalesce(v_item->>'correctKey','')));
      if v_expected_family='recall' then
        if coalesce(v_item->>'questionType','')<>'Reverse Recall Card' or v_correct<>'A'
          or coalesce(v_item->>'optionA','')<>'Yaad tha' or coalesce(v_item->>'optionB','')<>'Confused'
          or coalesce(v_item->>'optionC','')<>'Bhool gaya' or coalesce(v_item->>'optionD','')<>'' then
          raise exception 'Phrasal slot % recall control contract mismatch',v_ord;
        end if;
        if position(lower(v_item->>'word') in lower(v_item->>'question'))>0 then raise exception 'Phrasal slot % recall cue leaks target phrase',v_ord; end if;
      else
        if v_correct not in ('A','B','C','D') then raise exception 'Phrasal slot % invalid correctKey',v_ord; end if;
        v_option_a:=btrim(coalesce(v_item->>'optionA',''));v_option_b:=btrim(coalesce(v_item->>'optionB',''));
        v_option_c:=btrim(coalesce(v_item->>'optionC',''));v_option_d:=btrim(coalesce(v_item->>'optionD',''));
        if v_option_a='' or v_option_b='' or v_option_c='' or v_option_d='' then raise exception 'Phrasal slot % requires four nonblank options',v_ord; end if;
        if (select count(distinct lower(btrim(x))) from unnest(array[v_option_a,v_option_b,v_option_c,v_option_d]) x)<>4 then raise exception 'Phrasal slot % options must be distinct',v_ord; end if;
      end if;
      v_item:=v_item||jsonb_build_object('slotNo',v_ord,'contentGap',false);
      v_chatgpt:=v_chatgpt+1;
    end if;

    v_final_items:=v_final_items||jsonb_build_array(v_item);
  end loop;

  update english.phrasal_generation_slots s
  set finalized=e.value,status='ready',attempt_count=greatest(s.attempt_count,1),lease_expires_at=null,last_error=null,
      updated_at=now(),ready_at=now(),retry_after=null,transient_failure_count=0,last_error_class=null
  from jsonb_array_elements(v_final_items) with ordinality e(value,ordinality)
  where s.batch_date=b.batch_date and s.slot_no=e.ordinality;
  get diagnostics v_updated=row_count;
  if v_updated<>20 then raise exception 'Phrasal ingest staged % of 20 slots',v_updated; end if;

  update english.phrasal_generation_batches set status='ready',last_error=null,updated_at=now() where run_id=p_run_id;
  v_applied:=public.english_phrasal_task_apply(p_run_id,v_final_items);
  update english.phrasal_generation_batches set status='applied',applied_at=coalesce(applied_at,now()),last_error=null,updated_at=now() where run_id=p_run_id;

  v_source_id:='PHRASAL_DAILY_'||to_char(b.batch_date,'YYYYMMDD');
  update english.sources
  set notes='Central-selected adaptive Phrasal batch. '||v_legacy||' existing canonical questions reused with permanent Question_IDs; '
    ||v_chatgpt||' ChatGPT-owned variants generated after final-payload self-critic. Server-side Phrasal AI generation was not used.'
  where source_id=v_source_id;

  return coalesce(v_applied,jsonb_build_object('ok',true))
    ||jsonb_build_object('ok',true,'runId',p_run_id,'mode','chatgpt_owned','reused',v_legacy,'generatedByChatGPT',v_chatgpt);
end
$function$;

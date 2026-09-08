-- Phrasal atomic publication must honor the frozen daily selection while resolving
-- exact-duplicate legacy Question_ID aliases created after the batch was staged.
-- Resolution is deliberately strict: canonical target must be active, same concept,
-- and byte-equivalent across the staged question/options/key/explanation payload.

create or replace function public.english_phrasal_task_apply(p_run_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english
as $function$
declare
  r english.chatgpt_content_task_runs%rowtype;
  b english.phrasal_generation_batches%rowtype;
  v_apply jsonb; v_verify jsonb; v_day date;
  v_total integer; v_mapped integer; v_antigravity integer; v_legacy integer; v_deterministic integer;
  v_ready integer; v_invalid integer; v_staged_items jsonb; v_resolved_items jsonb;
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

  -- Exact-duplicate reconciliation may deactivate a legacy base Question_ID after
  -- this batch was frozen. Resolve only aliases whose active canonical payload is
  -- still exactly the staged payload and belongs to the same concept.
  select coalesce(jsonb_agg(
    case
      when lower(coalesce(e.value->>'generatorProvider',''))='legacy_bank'
       and nullif(btrim(e.value->>'baseQuestionId'),'') is not null
      then jsonb_set(
        e.value,
        '{baseQuestionId}',
        to_jsonb(coalesce((
          select a.canonical_question_id
          from english.phrasal_question_aliases a
          join english.questions q
            on q.question_id=a.canonical_question_id
           and q.active
          where a.alias_question_id=e.value->>'baseQuestionId'
            and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=btrim(e.value->>'conceptId')
            and btrim(coalesce(q.question,''))=btrim(coalesce(e.value->>'question',''))
            and btrim(coalesce(q.option_a,''))=btrim(coalesce(e.value->>'optionA',''))
            and btrim(coalesce(q.option_b,''))=btrim(coalesce(e.value->>'optionB',''))
            and btrim(coalesce(q.option_c,''))=btrim(coalesce(e.value->>'optionC',''))
            and btrim(coalesce(q.option_d,''))=btrim(coalesce(e.value->>'optionD',''))
            and upper(btrim(coalesce(q.correct,'')))=upper(btrim(coalesce(e.value->>'correctKey','')))
            and btrim(coalesce(q.explanation,''))=btrim(coalesce(e.value->>'explanation',''))
          limit 1
        ), e.value->>'baseQuestionId')),
        true
      )
      else e.value
    end
    order by e.ordinality
  ),'[]'::jsonb)
  into v_resolved_items
  from jsonb_array_elements(p_items) with ordinality e(value,ordinality);

  v_apply:=english.maintenance_apply_phrasal_hybrid(v_resolved_items);
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
$function$;

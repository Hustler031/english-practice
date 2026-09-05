-- Publish new contextual variants through the existing exact-20 materializer.
-- Central Intelligence identity/mapping remains authoritative.

create or replace function english.maintenance_apply_phrasal_hybrid(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  base_items jsonb;
  generated_items jsonb;
  applied jsonb;
  meta_count integer:=0;
begin
  select coalesce(jsonb_agg(e.value),'[]'::jsonb) into generated_items
  from jsonb_array_elements(p_items) e(value)
  where lower(coalesce(e.value->>'generatorProvider','gemini'))<>'legacy_bank';
  if english.ai_feature_enabled('groq_critic_v1') and jsonb_array_length(generated_items)>0 then
    perform english.assert_generated_items_quality(generated_items,false);
  end if;

  -- The legacy materializer still owns IDs, exact 20 atomicity and history safety.
  -- Context-fill is recognition-compatible at that boundary; the richer family is
  -- stored separately after the same transaction succeeds.
  select jsonb_agg(
    case when lower(coalesce(e.value->>'questionFamily',e.value->>'requestedQuestionFamily',''))='context_fill'
      then jsonb_set(e.value,'{family}',to_jsonb('recognition'::text))
      else jsonb_set(e.value,'{family}',to_jsonb(coalesce(nullif(e.value->>'family',''),nullif(e.value->>'legacyFamily',''),'recognition')))
    end order by e.ordinality)
  into base_items
  from jsonb_array_elements(p_items) with ordinality e(value,ordinality);

  applied:=english.maintenance_apply_phrasal_daily(base_items);

  with items as (
    select value,ordinality from jsonb_array_elements(p_items) with ordinality
  ), qids as (
    select value #>> '{}' as qid,ordinality
    from jsonb_array_elements(coalesce(applied->'questionIds','[]'::jsonb)) with ordinality
  )
  insert into english.phrasal_question_variants(
    question_id,concept_id,sense_key,question_family,variant_key,variant_fingerprint,
    generator_provider,critic_provider,quality_score,critic_decision,repair_count,metadata
  )
  select
    q.qid,
    i.value->>'conceptId',
    coalesce(nullif(i.value->>'senseKey',''),'legacy_default'),
    coalesce(nullif(i.value->>'questionFamily',''),nullif(i.value->>'requestedQuestionFamily',''),nullif(i.value->>'family',''),'recognition'),
    coalesce(nullif(i.value->>'variantKey',''),'variant_'||left(md5(lower(regexp_replace(coalesce(i.value->>'question',''),'\s+',' ','g'))),12)),
    coalesce(nullif(i.value->>'variantFingerprint',''),md5(lower(regexp_replace(coalesce(i.value->>'question',''),'\s+',' ','g')))),
    coalesce(nullif(i.value->>'generatorProvider',''),'gemini'),
    nullif(i.value->>'criticProvider',''),
    nullif(i.value->'quality'->>'score','')::numeric,
    nullif(i.value->'quality'->>'decision',''),
    coalesce((i.value->>'repairCount')::int,0),
    jsonb_build_object('legacyFamily',i.value->>'legacyFamily','source','daily_phrasal')
  from items i join qids q using(ordinality)
  on conflict(question_id) do nothing;
  get diagnostics meta_count=row_count;

  return applied||jsonb_build_object('variantMetadataCount',meta_count);
end $$;

create or replace function public.english_phrasal_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
  v_source_id text:='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD');
  v_total integer;
  v_mapped integer;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='phrasal' for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  v_apply:=case when english.ai_feature_enabled('phrasal_sense_v1')
    then english.maintenance_apply_phrasal_hybrid(p_items)
    else english.maintenance_apply_phrasal_daily(p_items) end;

  insert into english.question_concept_mappings(question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type)
  select q.question_id,q.concept_id,1,'deterministic_metadata','mapped','primary'
  from english.questions q
  join english.concepts c on c.concept_id=q.concept_id and c.active
  where q.active and q.source_id=v_source_id and q.concept_id is not null
  on conflict(question_id) do update set
    concept_id=excluded.concept_id,mapping_confidence=1,mapping_method='deterministic_metadata',
    review_status='mapped',relation_type='primary',updated_at=now();

  if english.ai_feature_enabled('gemini_content_v1') then
    update english.sources set
      notes='Central-selected adaptive Phrasal batch. New variants use Gemini generation plus independent Groq quality gates; validated legacy recall cards may pass through unchanged.'
    where source_id=v_source_id;
  end if;

  v_verify:=english.maintenance_verify_phrasal_daily();
  select count(*) into v_total from english.questions q where q.active and q.source_id=v_source_id;
  select count(*) into v_mapped
  from english.questions q
  join english.question_concept_mappings m on m.question_id=q.question_id and m.concept_id=q.concept_id
  join english.concepts c on c.concept_id=q.concept_id and c.active
  where q.active and q.source_id=v_source_id;

  if not coalesce((v_verify->>'ok')::boolean,false) or v_total<>20 or v_mapped<>20 then
    raise exception 'Phrasal verification/Central Intelligence mapping failed: questions %, mapped %',v_total,v_mapped;
  end if;

  update english.chatgpt_content_task_runs
  set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify,'centralMapped',v_mapped),applied_at=now(),updated_at=now()
  where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify,'centralMapped',v_mapped);
end $$;

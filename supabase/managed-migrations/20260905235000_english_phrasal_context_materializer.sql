-- Hybrid-only Phrasal materializer. The legacy exact-20 function remains untouched.
-- Central Intelligence still selects the same 20 concept IDs; this function only
-- allows an eligible selected concept to be materialized as a contextual variant.

create or replace function english.maintenance_apply_phrasal_hybrid_core(p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid;
  v_owner_count integer;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
  v_source_file text;
  v_expected jsonb;
  v_expected_ids text[];
  v_given_ids text[];
  v_existing integer;
  v_existing_attempts integer;
  v_start integer;
  v_ord integer:=0;
  v_item jsonb;
  v_concept text;
  v_expected_requested_family text;
  v_expected_legacy_family text;
  v_requested_family text;
  v_family text;
  v_qid text;
  v_question_type text;
  v_correct text;
  v_created text[]:='{}'::text[];
  v_new_count integer:=0;
  v_recall_count integer:=0;
  v_bad integer;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception 'p_items must be a JSON array';
  end if;
  if jsonb_array_length(p_items)<>20 then
    raise exception 'Phrasal hybrid materialization requires exactly 20 finalized items';
  end if;

  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then
    raise exception 'Phrasal maintenance requires exactly one active auth owner';
  end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  v_source_file:='Phrasal Daily '||to_char(v_day,'YYYY-MM-DD');
  perform pg_advisory_xact_lock(hashtext('english.maintenance_phrasal_daily'));

  select count(*) into v_existing
  from english.questions q where q.active and q.source_id=v_source_id;

  if v_existing=20
     and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete')
     and (select count(*) from english.question_origins o join english.questions q on q.question_id=o.question_id where q.source_id=v_source_id and o.origin_kind='core' and o.origin_ref=v_source_id)=20 then
    return jsonb_build_object('ok',true,'alreadyComplete',true,'sourceId',v_source_id,'count',20,
      'questionIds',(select coalesce(jsonb_agg(q.question_id order by q.question_id),'[]'::jsonb) from english.questions q where q.active and q.source_id=v_source_id));
  end if;

  if v_existing>0 then
    select count(*) into v_existing_attempts
    from english.attempts a join english.questions q on q.question_id=a.question_id
    where q.source_id=v_source_id and a.user_id=v_owner;
    if v_existing_attempts>0 then
      raise exception 'Partial Phrasal daily batch already has learner attempts; refusing destructive rebuild';
    end if;
    delete from english.questions q where q.source_id=v_source_id;
    delete from english.sources s where s.source_id=v_source_id;
  end if;

  v_expected:=public.english_get_phrasal_hybrid_maintenance_batch('smart',20);
  if jsonb_array_length(coalesce(v_expected,'[]'::jsonb))<>20 then
    raise exception 'Central Phrasal hybrid selector did not return 20 slots';
  end if;

  select array_agg(x order by x) into v_expected_ids
  from (
    select distinct coalesce(nullif(e.value->>'phrasalConceptId',''),nullif(e.value->>'conceptId','')) x
    from jsonb_array_elements(v_expected) e(value)
  ) s where x is not null;
  select array_agg(x order by x) into v_given_ids
  from (
    select distinct nullif(btrim(e.value->>'conceptId'),'') x
    from jsonb_array_elements(p_items) e(value)
  ) s where x is not null;

  if cardinality(coalesce(v_given_ids,'{}'::text[]))<>20
     or v_expected_ids is distinct from v_given_ids then
    raise exception 'Finalized Phrasal payload does not match the exact current 20 Central-selected concepts';
  end if;

  select coalesce(max((substring(q.question_id from '^PV([0-9]+)$'))::int),0)
  into v_start from english.questions q where q.question_id ~ '^PV[0-9]+$';

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_ord:=v_ord+1;
    v_concept:=btrim(coalesce(v_item->>'conceptId',''));
    v_requested_family:=lower(btrim(coalesce(v_item->>'requestedQuestionFamily',v_item->>'questionFamily',v_item->>'family','')));
    v_family:=case when v_requested_family='context_fill' then 'recognition'
      else lower(btrim(coalesce(v_item->>'family',v_item->>'legacyFamily',v_requested_family,''))) end;
    v_question_type:=btrim(coalesce(v_item->>'questionType',''));
    v_correct:=upper(btrim(coalesce(v_item->>'correctKey','')));

    select
      lower(coalesce(nullif(e.value->>'requestedQuestionFamily',''),nullif(e.value->>'missingFamily',''),nullif(e.value->>'phrasalQuestionFamily',''),'recognition')),
      lower(coalesce(nullif(e.value->>'legacyFamily',''),nullif(e.value->>'missingFamily',''),nullif(e.value->>'phrasalQuestionFamily',''),'recognition'))
    into v_expected_requested_family,v_expected_legacy_family
    from jsonb_array_elements(v_expected) e(value)
    where coalesce(nullif(e.value->>'phrasalConceptId',''),nullif(e.value->>'conceptId',''))=v_concept
    limit 1;

    if v_requested_family not in ('recognition','recall','confusion','context_fill') then
      raise exception 'Invalid requested Phrasal family for concept %',v_concept;
    end if;
    if v_family not in ('recognition','recall','confusion') then
      raise exception 'Invalid legacy Phrasal family for concept %',v_concept;
    end if;

    if v_expected_requested_family='context_fill' then
      if v_requested_family<>'context_fill' or v_family<>'recognition' then
        raise exception 'Context-fill family mismatch for concept %',v_concept;
      end if;
    elsif v_requested_family<>v_expected_requested_family or v_family<>v_expected_legacy_family then
      raise exception 'Phrasal family mismatch for concept %: expected requested % / legacy %, got % / %',
        v_concept,v_expected_requested_family,v_expected_legacy_family,v_requested_family,v_family;
    end if;

    if btrim(coalesce(v_item->>'question',''))='' or btrim(coalesce(v_item->>'explanation',''))='' then
      raise exception 'Question and explanation are required for concept %',v_concept;
    end if;
    if btrim(coalesce(v_item->>'optionA',''))='' or btrim(coalesce(v_item->>'optionB',''))='' or btrim(coalesce(v_item->>'optionC',''))='' then
      raise exception 'Options A-C are required for concept %',v_concept;
    end if;
    if v_family='recall' then
      if v_correct<>'A'
         or coalesce(v_item->>'optionA','')<>'I knew this'
         or coalesce(v_item->>'optionB','')<>'Unsure'
         or coalesce(v_item->>'optionC','')<>'Forgot' then
        raise exception 'Recall card must preserve A/B/C self-assessment semantics for concept %',v_concept;
      end if;
    else
      if btrim(coalesce(v_item->>'optionD',''))='' or v_correct not in ('A','B','C','D') then
        raise exception 'Recognition/confusion/context card requires four options and one A-D key for concept %',v_concept;
      end if;
    end if;

    v_qid:='PV'||lpad((v_start+v_ord)::text,4,'0');
    insert into english.questions(
      question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,
      subtopic,question_type,source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,
      exam_relevance,tip,usage_note,example_sentence,memory_aid,related_words,source_url,review_notes,active,created_at,updated_at
    ) values (
      v_qid,'Phrasal Verb',nullif(v_item->>'word',''),v_item->>'question',v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',coalesce(v_item->>'optionD',''),v_correct,v_item->>'explanation',
      'Phrasal Verbs',v_question_type,v_source_file,coalesce(v_item->>'sourcePage',''),v_concept,coalesce(nullif(v_item->>'difficulty',''),'Hard'),v_source_id,'New','Active',
      'SSC CGL',coalesce(v_item->>'tip',''),coalesce(v_item->>'usageNote',''),coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),coalesce(v_item->>'related',''),coalesce(v_item->>'sourceUrl',''),
      'Daily Phrasal hybrid snapshot; base='||coalesce(v_item->>'baseQuestionId','none')||'; requested_family='||v_requested_family||'; legacy_family='||v_family,true,now(),now()
    );

    if english.phrasal_question_family((select q from english.questions q where q.question_id=v_qid))<>v_family then
      raise exception 'Inserted legacy question family does not match finalized family for concept %',v_concept;
    end if;

    insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id)
    values(v_qid,'core',v_source_id,null);
    v_created:=array_append(v_created,v_qid);
    if coalesce((v_item->>'contentGap')::boolean,false) or btrim(coalesce(v_item->>'baseQuestionId',''))='' or v_requested_family='context_fill' then
      v_new_count:=v_new_count+1;
    end if;
    if v_family='recall' then v_recall_count:=v_recall_count+1; end if;
  end loop;

  insert into english.sources(source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,source_ref,notes,import_status,new_count,recall_count,duplicate_count,category_summary,processed_on)
  values(v_source_id,'Generated Practice',v_source_file,v_source_file,v_day,true,now(),20,'Supabase Central Phrasal Intelligence',
    'Central-selected 20-slot adaptive Phrasal batch. Context-fill variants preserve the selected concept identity and use separate variant metadata.',
    'Complete',v_new_count,v_recall_count,0,'Phrasal Verb: 20',now())
  on conflict(source_id) do update set
    source_type=excluded.source_type,source_name=excluded.source_name,source_file=excluded.source_file,source_date=excluded.source_date,
    active=true,question_count=20,source_ref=excluded.source_ref,notes=excluded.notes,import_status='Complete',new_count=excluded.new_count,
    recall_count=excluded.recall_count,duplicate_count=0,category_summary=excluded.category_summary,processed_on=now();

  select count(*) into v_bad from english.questions q
  where q.source_id=v_source_id and (
    not q.active or q.concept_id is null or btrim(q.question)='' or upper(coalesce(q.correct,'')) not in ('A','B','C','D')
    or btrim(coalesce(q.explanation,''))=''
  );
  if (select count(*) from english.questions q where q.active and q.source_id=v_source_id)<>20
     or (select count(*) from english.question_origins o join english.questions q on q.question_id=o.question_id where q.source_id=v_source_id and o.origin_kind='core' and o.origin_ref=v_source_id)<>20
     or v_bad<>0 then
    raise exception 'Phrasal hybrid post-materialization integrity validation failed';
  end if;

  return jsonb_build_object('ok',true,'alreadyComplete',false,'sourceId',v_source_id,'count',20,'newCount',v_new_count,'recallCount',v_recall_count,'questionIds',to_jsonb(v_created));
end
$$;

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

  select jsonb_agg(
    case when lower(coalesce(e.value->>'questionFamily',e.value->>'requestedQuestionFamily',''))='context_fill'
      then jsonb_set(e.value,'{family}',to_jsonb('recognition'::text))
      else jsonb_set(e.value,'{family}',to_jsonb(coalesce(nullif(e.value->>'family',''),nullif(e.value->>'legacyFamily',''),'recognition')))
    end order by e.ordinality)
  into base_items
  from jsonb_array_elements(p_items) with ordinality e(value,ordinality);

  applied:=english.maintenance_apply_phrasal_hybrid_core(base_items);
  if coalesce((applied->>'alreadyComplete')::boolean,false) then
    return applied||jsonb_build_object('variantMetadataCount',0);
  end if;

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
    q.qid,i.value->>'conceptId',coalesce(nullif(i.value->>'senseKey',''),'legacy_default'),
    coalesce(nullif(i.value->>'questionFamily',''),nullif(i.value->>'requestedQuestionFamily',''),nullif(i.value->>'family',''),'recognition'),
    coalesce(nullif(i.value->>'variantKey',''),'variant_'||left(md5(lower(regexp_replace(coalesce(i.value->>'question',''),'\s+',' ','g'))),12)),
    coalesce(nullif(i.value->>'variantFingerprint',''),md5(lower(regexp_replace(coalesce(i.value->>'question',''),'\s+',' ','g')))),
    coalesce(nullif(i.value->>'generatorProvider',''),'gemini'),nullif(i.value->>'criticProvider',''),
    nullif(i.value->'quality'->>'score','')::numeric,nullif(i.value->'quality'->>'decision',''),
    coalesce((i.value->>'repairCount')::int,0),
    jsonb_build_object('legacyFamily',i.value->>'legacyFamily','source','daily_phrasal')
  from items i join qids q using(ordinality)
  on conflict(question_id) do nothing;
  get diagnostics meta_count=row_count;

  return applied||jsonb_build_object('variantMetadataCount',meta_count);
end
$$;

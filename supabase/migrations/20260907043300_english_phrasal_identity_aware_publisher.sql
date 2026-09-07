-- Publish Phrasal daily membership without cloning existing bank questions.
-- Existing legacy-bank payloads retain their permanent Question_ID; only genuinely new
-- generated variants receive a new permanent Question_ID.

create or replace function english.maintenance_verify_phrasal_daily()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
  v_hub jsonb;
  v_count integer;
  v_mapped integer;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');

  select count(*) into v_count
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  where d.batch_date=v_day;

  select count(*) into v_mapped
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  join english.question_concept_mappings m
    on m.question_id=q.question_id and m.concept_id=d.concept_id
  where d.batch_date=v_day;

  v_hub:=public.english_get_phrasal_hub();
  return jsonb_build_object(
    'ok',v_count=20 and v_mapped=20
      and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete'),
    'sourceId',v_source_id,
    'questionCount',v_count,
    'membershipCount',v_count,
    'mappedCount',v_mapped,
    'sourceComplete',exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete'),
    'today',v_hub->'today',
    'questionIds',(select coalesce(jsonb_agg(d.question_id order by d.slot_no),'[]'::jsonb) from english.phrasal_daily_items d where d.batch_date=v_day)
  );
end;
$function$;

create or replace function english.maintenance_phrasal_batch(p_count integer default 20)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_count integer:=greatest(1,least(20,coalesce(p_count,20)));
  v_items jsonb;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  v_items:=case when english.ai_feature_enabled('phrasal_context_fill_v1')
    then public.english_get_phrasal_hybrid_maintenance_batch('smart',v_count)
    else public.english_get_phrasal_maintenance_batch('smart',v_count) end;
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');

  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'sourceId',v_source_id,
    'sourceFile','Phrasal Daily '||to_char(v_day,'YYYY-MM-DD'),
    'count',jsonb_array_length(coalesce(v_items,'[]'::jsonb)),
    'existingToday',(select count(*) from english.phrasal_daily_items where batch_date=v_day),
    'items',coalesce(v_items,'[]'::jsonb)
  );
end;
$function$;

create or replace function english.maintenance_apply_phrasal_hybrid_core(p_items jsonb)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
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
  v_start integer;
  v_ord integer:=0;
  v_item jsonb;
  v_concept text;
  v_expected_requested_family text;
  v_expected_legacy_family text;
  v_requested_family text;
  v_family text;
  v_provider text;
  v_base_id text;
  v_qid text;
  v_question_type text;
  v_correct text;
  v_created text[]:='{}'::text[];
  v_new_count integer:=0;
  v_recall_count integer:=0;
  v_bad integer;
  v_is_new boolean;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception 'p_items must be a JSON array';
  end if;
  if jsonb_array_length(p_items)<>20 then
    raise exception 'Phrasal hybrid materialization requires exactly 20 finalized items';
  end if;

  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  v_source_file:='Phrasal Daily '||to_char(v_day,'YYYY-MM-DD');
  perform pg_advisory_xact_lock(hashtext('english.maintenance_phrasal_daily'));

  select count(*) into v_existing
  from english.phrasal_daily_items
  where batch_date=v_day;

  if v_existing=20
     and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete') then
    return jsonb_build_object(
      'ok',true,'alreadyComplete',true,'sourceId',v_source_id,'count',20,
      'questionIds',(select coalesce(jsonb_agg(d.question_id order by d.slot_no),'[]'::jsonb) from english.phrasal_daily_items d where d.batch_date=v_day)
    );
  end if;
  if v_existing>0 then
    raise exception 'Partial Phrasal daily membership exists; refusing destructive rebuild';
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
  into v_start
  from english.questions q
  where q.question_id ~ '^PV[0-9]+$';

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_ord:=v_ord+1;
    v_concept:=btrim(coalesce(v_item->>'conceptId',''));
    v_requested_family:=lower(btrim(coalesce(v_item->>'requestedQuestionFamily',v_item->>'questionFamily',v_item->>'family','')));
    v_family:=case when v_requested_family='context_fill' then 'recognition'
      else lower(btrim(coalesce(v_item->>'family',v_item->>'legacyFamily',v_requested_family,''))) end;
    v_provider:=lower(btrim(coalesce(v_item->>'generatorProvider','legacy_bank')));
    v_base_id:=nullif(btrim(coalesce(v_item->>'baseQuestionId','')),'');
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

    if btrim(coalesce(v_item->>'question',''))=''
       or btrim(coalesce(v_item->>'explanation',''))='' then
      raise exception 'Question and explanation are required for concept %',v_concept;
    end if;
    if btrim(coalesce(v_item->>'optionA',''))=''
       or btrim(coalesce(v_item->>'optionB',''))=''
       or btrim(coalesce(v_item->>'optionC',''))='' then
      raise exception 'Options A-C are required for concept %',v_concept;
    end if;

    if v_family='recall' then
      if v_correct<>'A'
         or v_question_type<>'Reverse Recall Card'
         or coalesce(v_item->>'optionA','')<>'Yaad tha'
         or coalesce(v_item->>'optionB','')<>'Confused'
         or coalesce(v_item->>'optionC','')<>'Bhool gaya'
         or coalesce(v_item->>'optionD','')<>'' then
        raise exception 'Reverse Recall Card must preserve Yaad tha / Confused / Bhool gaya self-assessment semantics for concept %',v_concept;
      end if;
    else
      if btrim(coalesce(v_item->>'optionD',''))=''
         or v_correct not in ('A','B','C','D') then
        raise exception 'Recognition/confusion/context card requires four options and one A-D key for concept %',v_concept;
      end if;
    end if;

    v_is_new:=false;

    if v_provider='legacy_bank' then
      if v_base_id is null then
        raise exception 'Legacy-bank slot is missing baseQuestionId for concept %',v_concept;
      end if;

      select q.question_id into v_qid
      from english.questions q
      where q.question_id=v_base_id
        and q.active
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=v_concept
        and btrim(coalesce(q.question,''))=btrim(coalesce(v_item->>'question',''))
        and btrim(coalesce(q.option_a,''))=btrim(coalesce(v_item->>'optionA',''))
        and btrim(coalesce(q.option_b,''))=btrim(coalesce(v_item->>'optionB',''))
        and btrim(coalesce(q.option_c,''))=btrim(coalesce(v_item->>'optionC',''))
        and btrim(coalesce(q.option_d,''))=btrim(coalesce(v_item->>'optionD',''))
        and upper(btrim(coalesce(q.correct,'')))=v_correct
        and btrim(coalesce(q.explanation,''))=btrim(coalesce(v_item->>'explanation',''));

      if v_qid is null then
        raise exception 'Legacy-bank base payload mismatch for concept % / base %',v_concept,v_base_id;
      end if;
    else
      -- Reuse a truly identical generated variant if it already exists for the same concept.
      select q.question_id into v_qid
      from english.questions q
      where q.active
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=v_concept
        and btrim(coalesce(q.question,''))=btrim(coalesce(v_item->>'question',''))
        and btrim(coalesce(q.option_a,''))=btrim(coalesce(v_item->>'optionA',''))
        and btrim(coalesce(q.option_b,''))=btrim(coalesce(v_item->>'optionB',''))
        and btrim(coalesce(q.option_c,''))=btrim(coalesce(v_item->>'optionC',''))
        and btrim(coalesce(q.option_d,''))=btrim(coalesce(v_item->>'optionD',''))
        and upper(btrim(coalesce(q.correct,'')))=v_correct
        and btrim(coalesce(q.explanation,''))=btrim(coalesce(v_item->>'explanation',''))
      order by q.created_at,q.question_id
      limit 1;

      if v_qid is null then
        v_start:=v_start+1;
        v_qid:='PV'||lpad(v_start::text,4,'0');
        v_is_new:=true;

        insert into english.questions(
          question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,
          subtopic,question_type,source_file,source_page,concept_id,difficulty,source_id,
          learning_status,content_status,exam_relevance,tip,usage_note,example_sentence,
          memory_aid,related_words,source_url,review_notes,active,created_at,updated_at
        ) values (
          v_qid,'Phrasal Verb',nullif(v_item->>'word',''),v_item->>'question',
          v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',coalesce(v_item->>'optionD',''),
          v_correct,v_item->>'explanation','Phrasal Verbs',v_question_type,
          v_source_file,coalesce(v_item->>'sourcePage',''),v_concept,
          coalesce(nullif(v_item->>'difficulty',''),'Hard'),'PHRASAL_GENERATED_VARIANT',
          'New','Active','SSC CGL',coalesce(v_item->>'tip',''),coalesce(v_item->>'usageNote',''),
          coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),coalesce(v_item->>'related',''),
          coalesce(v_item->>'sourceUrl',''),
          'Permanent Phrasal variant; first daily membership='||v_source_id||
            '; base='||coalesce(v_base_id,'none')
            ||'; requested_family='||v_requested_family
            ||'; legacy_family='||v_family,
          true,now(),now()
        );

        insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id)
        values(v_qid,'core','PHRASAL_GENERATED_VARIANT',null)
        on conflict(question_id) do nothing;
      end if;
    end if;

    insert into english.phrasal_daily_items(
      batch_date,slot_no,source_id,question_id,original_question_id,concept_id,
      requested_family,question_family,generator_provider,is_new_variant,metadata
    ) values (
      v_day,v_ord,v_source_id,v_qid,v_qid,v_concept,
      v_requested_family,
      coalesce(nullif(v_item->>'questionFamily',''),v_requested_family),
      v_provider,v_is_new,
      jsonb_build_object('baseQuestionId',v_base_id,'variantKey',coalesce(v_item->>'variantKey',''))
    );

    v_created:=array_append(v_created,v_qid);
    if v_is_new then v_new_count:=v_new_count+1; end if;
    if v_family='recall' then v_recall_count:=v_recall_count+1; end if;
  end loop;

  insert into english.sources(
    source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,
    source_ref,notes,import_status,new_count,recall_count,duplicate_count,category_summary,processed_on
  ) values (
    v_source_id,'Generated Practice',v_source_file,v_source_file,v_day,true,now(),20,
    'Supabase Central Phrasal Intelligence',
    'Central-selected 20-slot adaptive Phrasal membership. Existing bank variants retain permanent Question_IDs; only genuinely new generated variants receive new IDs.',
    'Complete',v_new_count,v_recall_count,0,'Phrasal Verb: 20',now()
  )
  on conflict(source_id) do update set
    source_type=excluded.source_type,
    source_name=excluded.source_name,
    source_file=excluded.source_file,
    source_date=excluded.source_date,
    active=true,
    question_count=20,
    source_ref=excluded.source_ref,
    notes=excluded.notes,
    import_status='Complete',
    new_count=excluded.new_count,
    recall_count=excluded.recall_count,
    duplicate_count=0,
    category_summary=excluded.category_summary,
    processed_on=now();

  select count(*) into v_bad
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id
  where d.batch_date=v_day
    and (not q.active
         or q.concept_id is null
         or btrim(q.question)=''
         or upper(coalesce(q.correct,'')) not in ('A','B','C','D')
         or btrim(coalesce(q.explanation,''))='');

  if (select count(*) from english.phrasal_daily_items where batch_date=v_day)<>20
     or v_bad<>0 then
    raise exception 'Phrasal hybrid post-materialization integrity validation failed';
  end if;

  return jsonb_build_object(
    'ok',true,
    'alreadyComplete',false,
    'sourceId',v_source_id,
    'count',20,
    'newCount',v_new_count,
    'recallCount',v_recall_count,
    'questionIds',to_jsonb(v_created)
  );
end;
$function$;

create or replace function public.english_phrasal_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_total integer;
  v_mapped integer;
  v_antigravity integer;
  v_legacy integer;
  v_deterministic integer;
begin
  select * into r
  from english.chatgpt_content_task_runs
  where run_id=p_run_id and lane='phrasal'
  for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;

  v_apply:=english.maintenance_apply_phrasal_hybrid(p_items);

  insert into english.question_concept_mappings(
    question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type
  )
  select distinct q.question_id,d.concept_id,1,'deterministic_metadata','mapped','primary'
  from english.phrasal_daily_items d
  join english.questions q on q.question_id=d.question_id and q.active
  join english.concepts c on c.concept_id=d.concept_id and c.active
  where d.batch_date=v_day
  on conflict(question_id) do update set
    concept_id=excluded.concept_id,
    mapping_confidence=1,
    mapping_method='deterministic_metadata',
    review_status='mapped',
    relation_type='primary',
    updated_at=now();

  v_verify:=english.maintenance_verify_phrasal_daily();

  select count(*) into v_total
  from english.phrasal_daily_items
  where batch_date=v_day;

  select count(*) into v_mapped
  from english.phrasal_daily_items d
  join english.question_concept_mappings m
    on m.question_id=d.question_id and m.concept_id=d.concept_id
  where d.batch_date=v_day;

  select
    count(*) filter(where lower(coalesce(generator_provider,''))='antigravity'),
    count(*) filter(where lower(coalesce(generator_provider,''))='legacy_bank'),
    count(*) filter(where lower(coalesce(generator_provider,''))='deterministic_recall')
  into v_antigravity,v_legacy,v_deterministic
  from english.phrasal_daily_items
  where batch_date=v_day;

  update english.sources
  set notes='Central-selected adaptive Phrasal batch. Permanent identity reuse: '
            ||v_legacy||' legacy-bank slots reused existing Question_IDs; '
            ||v_antigravity||' Antigravity variants; '
            ||v_deterministic||' deterministic recall fillers.'
  where source_id='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');

  if not coalesce((v_verify->>'ok')::boolean,false)
     or v_total<>20
     or v_mapped<>20 then
    raise exception 'Phrasal verification/Central Intelligence mapping failed: memberships %, mapped %',v_total,v_mapped;
  end if;

  update english.chatgpt_content_task_runs
  set status='applied',
      result=jsonb_build_object('apply',v_apply,'verify',v_verify,'centralMapped',v_mapped),
      applied_at=now(),
      updated_at=now()
  where run_id=p_run_id;

  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify,'centralMapped',v_mapped);
end;
$function$;

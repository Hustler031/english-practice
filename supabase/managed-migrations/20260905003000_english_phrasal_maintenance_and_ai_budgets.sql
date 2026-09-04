-- Stabilize scheduled Phrasal maintenance behind bounded private helpers and align
-- the context-worker HTTP caller budget with the heavier two-step AI lanes.

create or replace function english.maintenance_phrasal_batch(p_count integer default 20)
returns jsonb
language plpgsql
security definer
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
  select count(*),max(u.id::text)::uuid
  into v_owner_count,v_owner
  from auth.users u
  where u.deleted_at is null;
  if v_owner_count<>1 then
    raise exception 'Phrasal maintenance requires exactly one active auth owner';
  end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_items:=public.english_get_phrasal_maintenance_batch('smart',v_count);
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  return jsonb_build_object(
    'ok',true,
    'date',v_day,
    'sourceId',v_source_id,
    'sourceFile','Phrasal Daily '||to_char(v_day,'YYYY-MM-DD'),
    'count',jsonb_array_length(coalesce(v_items,'[]'::jsonb)),
    'existingToday',(select count(*) from english.questions q where q.active and q.source_id=v_source_id),
    'items',coalesce(v_items,'[]'::jsonb)
  );
end
$function$;

create or replace function english.maintenance_apply_phrasal_daily(p_items jsonb)
returns jsonb
language plpgsql
security definer
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
  v_existing_attempts integer;
  v_start integer;
  v_ord integer:=0;
  v_item jsonb;
  v_concept text;
  v_expected_family text;
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
    raise exception 'Phrasal daily materialization requires exactly 20 finalized items';
  end if;

  select count(*),max(u.id::text)::uuid
  into v_owner_count,v_owner
  from auth.users u
  where u.deleted_at is null;
  if v_owner_count<>1 then
    raise exception 'Phrasal maintenance requires exactly one active auth owner';
  end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  v_source_file:='Phrasal Daily '||to_char(v_day,'YYYY-MM-DD');
  perform pg_advisory_xact_lock(hashtext('english.maintenance_phrasal_daily'));

  select count(*) into v_existing
  from english.questions q
  where q.active and q.source_id=v_source_id;

  if v_existing=20
     and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete')
     and (select count(*) from english.question_origins o join english.questions q on q.question_id=o.question_id where q.source_id=v_source_id and o.origin_kind='core' and o.origin_ref=v_source_id)=20 then
    return jsonb_build_object('ok',true,'alreadyComplete',true,'sourceId',v_source_id,'count',20,
      'questionIds',(select coalesce(jsonb_agg(q.question_id order by q.question_id),'[]'::jsonb) from english.questions q where q.active and q.source_id=v_source_id));
  end if;

  if v_existing>0 then
    select count(*) into v_existing_attempts
    from english.attempts a
    join english.questions q on q.question_id=a.question_id
    where q.source_id=v_source_id and a.user_id=v_owner;
    if v_existing_attempts>0 then
      raise exception 'Partial Phrasal daily batch already has learner attempts; refusing destructive rebuild';
    end if;
    delete from english.questions q where q.source_id=v_source_id;
    delete from english.sources s where s.source_id=v_source_id;
  end if;

  v_expected:=public.english_get_phrasal_maintenance_batch('smart',20);
  if jsonb_array_length(coalesce(v_expected,'[]'::jsonb))<>20 then
    raise exception 'Central Phrasal maintenance selector did not return 20 slots';
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
    v_family:=lower(btrim(coalesce(v_item->>'family','')));
    v_question_type:=btrim(coalesce(v_item->>'questionType',''));
    v_correct:=upper(btrim(coalesce(v_item->>'correctKey','')));

    select lower(coalesce(nullif(e.value->>'missingFamily',''),nullif(e.value->>'phrasalQuestionFamily','')))
    into v_expected_family
    from jsonb_array_elements(v_expected) e(value)
    where coalesce(nullif(e.value->>'phrasalConceptId',''),nullif(e.value->>'conceptId',''))=v_concept
    limit 1;

    if v_family not in ('recognition','recall','confusion') then
      raise exception 'Invalid Phrasal family for concept %',v_concept;
    end if;
    if v_expected_family is not null and v_expected_family<>'' and v_family<>v_expected_family then
      raise exception 'Phrasal family mismatch for concept %: expected %, got %',v_concept,v_expected_family,v_family;
    end if;
    if btrim(coalesce(v_item->>'question',''))='' or btrim(coalesce(v_item->>'explanation',''))='' then
      raise exception 'Question and explanation are required for concept %',v_concept;
    end if;
    if btrim(coalesce(v_item->>'optionA',''))='' or btrim(coalesce(v_item->>'optionB',''))='' or btrim(coalesce(v_item->>'optionC',''))='' then
      raise exception 'Options A-C are required for concept %',v_concept;
    end if;
    if v_family='recall' then
      if v_correct<>'A' then raise exception 'Recall card must preserve A/B/C self-assessment semantics for concept %',v_concept; end if;
    else
      if btrim(coalesce(v_item->>'optionD',''))='' or v_correct not in ('A','B','C','D') then
        raise exception 'Recognition/confusion card requires four options and one A-D key for concept %',v_concept;
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
      'Daily Phrasal maintenance snapshot; base='||coalesce(v_item->>'baseQuestionId','none')||'; family='||v_family,true,now(),now()
    );

    if english.phrasal_question_family((select q from english.questions q where q.question_id=v_qid))<>v_family then
      raise exception 'Inserted question family does not match finalized family for concept %',v_concept;
    end if;

    insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id)
    values(v_qid,'core',v_source_id,null);
    v_created:=array_append(v_created,v_qid);
    if coalesce((v_item->>'contentGap')::boolean,false) or btrim(coalesce(v_item->>'baseQuestionId',''))='' then v_new_count:=v_new_count+1; end if;
    if v_family='recall' then v_recall_count:=v_recall_count+1; end if;
  end loop;

  insert into english.sources(source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,source_ref,notes,import_status,new_count,recall_count,duplicate_count,category_summary,processed_on)
  values(v_source_id,'Generated Practice',v_source_file,v_source_file,v_day,true,now(),20,'Supabase Central Phrasal Intelligence',
    'Central-selected 20-slot adaptive Phrasal batch. GPT refinement/materialization applied through bounded maintenance helpers; raw scheduled DML is not used.',
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
    raise exception 'Phrasal daily post-materialization integrity validation failed';
  end if;

  return jsonb_build_object('ok',true,'alreadyComplete',false,'sourceId',v_source_id,'count',20,'newCount',v_new_count,'recallCount',v_recall_count,'questionIds',to_jsonb(v_created));
end
$function$;

create or replace function english.maintenance_verify_phrasal_daily()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
  v_hub jsonb;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  v_hub:=public.english_get_phrasal_hub();
  return jsonb_build_object(
    'ok',
      (select count(*)=20 from english.questions q where q.active and q.source_id=v_source_id)
      and (select count(*)=20 from english.question_origins o join english.questions q on q.question_id=o.question_id where q.source_id=v_source_id and o.origin_kind='core' and o.origin_ref=v_source_id)
      and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete'),
    'sourceId',v_source_id,
    'questionCount',(select count(*) from english.questions q where q.active and q.source_id=v_source_id),
    'originCount',(select count(*) from english.question_origins o join english.questions q on q.question_id=o.question_id where q.source_id=v_source_id and o.origin_kind='core' and o.origin_ref=v_source_id),
    'sourceComplete',exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=20 and lower(coalesce(s.import_status,''))='complete'),
    'today',v_hub->'today',
    'questionIds',(select coalesce(jsonb_agg(q.question_id order by q.question_id),'[]'::jsonb) from english.questions q where q.active and q.source_id=v_source_id)
  );
end
$function$;

revoke all on function english.maintenance_phrasal_batch(integer) from public,anon,authenticated;
revoke all on function english.maintenance_apply_phrasal_daily(jsonb) from public,anon,authenticated;
revoke all on function english.maintenance_verify_phrasal_daily() from public,anon,authenticated;
grant execute on function english.maintenance_phrasal_batch(integer) to service_role;
grant execute on function english.maintenance_apply_phrasal_daily(jsonb) to service_role;
grant execute on function english.maintenance_verify_phrasal_daily() to service_role;

-- The worker now gets a larger per-call budget for two-step AI lanes. Keep the
-- scheduler HTTP request bounded but long enough to avoid caller-side false timeouts.
do $budget$
declare vdef text;
begin
  select pg_get_functiondef(p.oid) into vdef
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english' and p.proname='kick_context_worker'
  order by p.oid desc limit 1;
  if vdef is null then raise exception 'english.kick_context_worker is missing'; end if;
  if position('timeout_milliseconds:=75000' in vdef)>0 then return; end if;
  if position('timeout_milliseconds:=55000' in vdef)=0 then
    raise exception 'Unexpected context-worker HTTP budget; refusing blind replacement';
  end if;
  execute replace(vdef,'timeout_milliseconds:=55000','timeout_milliseconds:=75000');
end
$budget$;

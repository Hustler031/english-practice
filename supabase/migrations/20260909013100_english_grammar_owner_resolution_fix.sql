-- ENGLISH V2 — Grammar Stage 1 PostgreSQL-safe single-learner resolution
-- PostgreSQL has no built-in min(uuid). Resolve the sole active learner by count + ordered LIMIT 1.

create or replace function english.maintenance_grammar_batch(p_count integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
set statement_timeout to '60s'
as $function$
declare
  uid uuid; v_users integer; v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_introduced integer:=0; v_review_cap integer:=0; v_new_cap integer:=0; v_selected integer:=0;
  r record; v_allowed text[]; v_preferred text; v_ref jsonb; v_items jsonb:='[]'::jsonb; v_slot integer:=0; v_gaps integer:=0;
begin
  if p_count<>20 then raise exception 'Grammar Daily invariant requires exactly 20 slots'; end if;
  select count(*) into v_users from auth.users where deleted_at is null;
  select id into uid from auth.users where deleted_at is null order by id limit 1;
  if v_users<>1 or uid is null then raise exception 'Grammar selector requires exactly one active learner'; end if;
  select count(*) into v_introduced from english.grammar_rule_evidence where user_id=uid and introduced_at is not null;
  if v_introduced<20 then v_review_cap:=0;
  elsif v_introduced<140 then v_review_cap:=3;
  elsif v_introduced<220 then v_review_cap:=6;
  else v_review_cap:=12; end if;
  v_new_cap:=20-v_review_cap;

  create temp table grammar_pick(
    ord bigserial,rule_key text primary key,selection_type text,rank_score numeric
  ) on commit drop;

  insert into grammar_pick(rule_key,selection_type,rank_score)
  select e.rule_key,'review',
    (case e.coverage_state when 'weak' then 1000 when 'learning' then 600 when 'strong' then 300 else 100 end)
    +e.recent_failures*100+r.priority
  from english.grammar_rule_evidence e join english.grammar_rules r using(rule_key)
  where e.user_id=uid and e.introduced_at is not null and r.active
    and (e.coverage_state='weak' or e.recent_failures>0 or e.next_review is null or e.next_review<=now())
  order by 3 desc,e.next_review nulls first,e.last_attempt_at nulls first
  limit v_review_cap;

  with raw as(
    select r.rule_key,r.chapter,r.priority,coalesce(e.recent_failures,0) diagnostic_failures,
      row_number() over(partition by r.chapter order by coalesce(e.recent_failures,0) desc,r.priority desc,r.rule_key) chapter_rn
    from english.grammar_rules r
    left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=r.rule_key
    where r.active and e.introduced_at is null
  ), ranked as(
    select *,row_number() over(order by chapter_rn,diagnostic_failures desc,priority desc,md5(rule_key||v_day::text)) global_rn from raw
  )
  insert into grammar_pick(rule_key,selection_type,rank_score)
  select rule_key,'new',10000-global_rn from ranked order by global_rn limit v_new_cap
  on conflict(rule_key) do nothing;

  select count(*) into v_selected from grammar_pick;
  if v_selected<20 then
    insert into grammar_pick(rule_key,selection_type,rank_score)
    select r.rule_key,'rotation',r.priority+coalesce(e.recent_failures,0)*100
    from english.grammar_rules r
    join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=r.rule_key and e.introduced_at is not null
    where r.active and not exists(select 1 from grammar_pick p where p.rule_key=r.rule_key)
    order by (e.coverage_state='weak') desc,e.next_review nulls first,e.last_selected_at nulls first,r.priority desc
    limit 20-v_selected
    on conflict(rule_key) do nothing;
  end if;

  select count(*) into v_selected from grammar_pick;
  if v_selected<>20 then raise exception 'Grammar selector could form only % of 20 distinct rule slots; curriculum is incomplete',v_selected; end if;

  for r in
    select p.selection_type,r.*,coalesce(e.selection_count,0) selection_count,coalesce(e.attempts,0) attempts,
      coalesce(e.correct,0) correct,coalesce(e.wrong,0) wrong,coalesce(e.recent_failures,0) recent_failures,
      coalesce(e.distinct_families,0) distinct_families,coalesce(e.transfer_successes,0) transfer_successes,
      coalesce(e.coverage_state,'introduced') learner_state,e.next_review,e.last_attempt_at
    from grammar_pick p join english.grammar_rules r using(rule_key)
    left join english.grammar_rule_evidence e on e.user_id=uid and e.rule_key=r.rule_key
    order by md5(p.rule_key||v_day::text)
  loop
    v_slot:=v_slot+1;
    v_allowed:=english.grammar_allowed_families(r.supported_families,r.selection_count,r.learner_state);
    v_preferred:=english.grammar_preferred_family(r.supported_families,r.selection_count,r.learner_state);
    v_ref:=english.grammar_reference_variant(uid,r.rule_key,array[v_preferred]);
    if v_ref is null then v_gaps:=v_gaps+1; end if;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'slotNo',v_slot,'ruleKey',r.rule_key,'chapter',r.chapter,'ruleFamily',r.rule_family,'ruleTitle',r.rule_title,
      'canonicalRule',r.canonical_rule,'commonTrap',coalesce(r.common_trap,''),'contrastWith',coalesce(r.contrast_with,''),
      'priority',r.priority,'difficulty',r.difficulty,'selectionType',r.selection_type,
      'selectionCount',r.selection_count,'attempts',r.attempts,'correct',r.correct,'wrong',r.wrong,
      'recentFailures',r.recent_failures,'distinctFamilies',r.distinct_families,'transferSuccesses',r.transfer_successes,
      'learnerState',r.learner_state,'nextReview',r.next_review,'lastAttemptAt',r.last_attempt_at,
      'preferredQuestionFamily',v_preferred,'allowedQuestionFamilies',to_jsonb(v_allowed),
      'referenceVariant',v_ref,'contentGap',(v_ref is null),
      'sourceName',r.source_name,'sourceUrl',r.source_url,'verificationNote',coalesce(r.verification_note,''),
      'aiPlanner',jsonb_build_object(
        'required',v_ref is null,
        'role','Choose the most pedagogically useful family only from allowedQuestionFamilies, preserve the verified rule, and keep difficulty SSC-realistic.',
        'coldStartGuard',r.selection_count<=1,
        'doNotEscalateIfWeak',r.learner_state='weak'
      )
    ));
  end loop;
  return jsonb_build_object('ok',true,'date',v_day,'count',20,'introducedRules',v_introduced,
    'reviewCap',v_review_cap,'newTarget',v_new_cap,'generatedNeeded',v_gaps,
    'sourceId','GRAMMAR_DAILY_'||to_char(v_day,'YYYYMMDD'),'sourceFile','Grammar Daily '||to_char(v_day,'YYYY-MM-DD'),'items',v_items,
    'contract',jsonb_build_object('exactCount',20,'planner','chatgpt','critic','chatgpt_self_critic','canonicalReuse',true));
end
$function$;

create or replace function public.english_grammar_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
set statement_timeout to '120s'
as $function$
declare
  r english.chatgpt_content_task_runs%rowtype; b english.grammar_generation_batches%rowtype;
  uid uuid; v_users integer; v_item jsonb; v_assignment jsonb; v_rule english.grammar_rules%rowtype;
  v_qid text; v_concept text; v_family text; v_source_id text; v_source_file text; v_new integer:=0; v_reused integer:=0; v_count integer;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='grammar' for update;
  if not found then raise exception 'Unknown Grammar run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  select * into b from english.grammar_generation_batches where run_id=p_run_id and batch_date=r.batch_date for update;
  if not found then raise exception 'Grammar generation batch missing'; end if;
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)<>20 then raise exception 'Grammar apply requires exactly 20 finalized items'; end if;
  select count(*) into v_users from auth.users where deleted_at is null;
  select id into uid from auth.users where deleted_at is null order by id limit 1;
  if v_users<>1 or uid is null then raise exception 'Grammar apply requires exactly one active learner'; end if;
  v_source_id:='GRAMMAR_DAILY_'||to_char(r.batch_date,'YYYYMMDD'); v_source_file:='Grammar Daily '||to_char(r.batch_date,'YYYY-MM-DD');

  if (select count(distinct (x.value->>'slotNo')::integer) from jsonb_array_elements(p_items) x(value))<>20 then raise exception 'Grammar finalized slot numbers must be unique'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    select assignment into v_assignment from english.grammar_generation_slots where batch_date=r.batch_date and slot_no=(v_item->>'slotNo')::integer;
    if v_assignment is null then raise exception 'Grammar slot % not staged',v_item->>'slotNo'; end if;
    select * into v_rule from english.grammar_rules where rule_key=v_assignment->>'ruleKey' and active;
    if not found then raise exception 'Grammar rule missing for slot %',v_item->>'slotNo'; end if;
    v_family:=english.grammar_normalize_family(coalesce(nullif(v_item->>'questionFamily',''),nullif(v_item->>'requestedQuestionFamily',''),v_assignment->>'preferredQuestionFamily'));
    if not (v_family=any(array(select jsonb_array_elements_text(v_assignment->'allowedQuestionFamilies')))) then raise exception 'Grammar slot % final family is outside CI allowance',v_item->>'slotNo'; end if;
    v_concept:=english.grammar_concept_id(v_rule.rule_key);
    insert into english.concepts(concept_id,domain,skill_family,name,description,confidence,exam_relevance,priority_score,coverage_state,is_atomic,active,metadata,created_at,updated_at)
    values(v_concept,'English','Grammar',v_rule.rule_title,v_rule.canonical_rule,'high',case when v_rule.priority>=85 then 'high' when v_rule.priority>=60 then 'medium' else 'low' end,
      v_rule.priority,'unseen',true,true,jsonb_build_object('grammarRuleKey',v_rule.rule_key,'chapter',v_rule.chapter,'ruleFamily',v_rule.rule_family,'sourceUrl',v_rule.source_url),now(),now())
    on conflict(concept_id) do update set name=excluded.name,description=excluded.description,priority_score=excluded.priority_score,metadata=excluded.metadata,updated_at=now();

    if lower(coalesce(v_item->>'generatorProvider',''))='canonical_bank' then
      v_qid=btrim(coalesce(v_item->>'baseQuestionId',''));
      if v_qid='' or not exists(select 1 from english.grammar_question_variants where question_id=v_qid and rule_key=v_rule.rule_key) then
        raise exception 'Grammar slot % canonical reuse identity mismatch',v_item->>'slotNo';
      end if;
      v_reused:=v_reused+1;
    else
      v_qid:='GRM'||lpad(nextval('english.grammar_question_seq')::text,6,'0');
      insert into english.questions(question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,tip,usage_note,example_sentence,memory_aid,related_words,source_url,review_notes,active,created_at,updated_at)
      values(v_qid,'Grammar',v_rule.rule_title,v_item->>'question',v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',v_item->>'optionD',upper(v_item->>'correctKey'),v_item->>'explanation',
        v_rule.chapter,english.grammar_question_type_label(v_family),v_source_file,'Rule: '||v_rule.rule_key,v_concept,coalesce(nullif(v_item->>'difficulty',''),v_rule.difficulty),v_source_id,'New','Ready','High',
        coalesce(v_item->>'tip',''),coalesce(v_item->>'usageNote',v_rule.canonical_rule),coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),coalesce(v_rule.contrast_with,''),v_rule.source_url,
        'Grammar Intelligence · ChatGPT planner/generator · final-payload self-critic',true,now(),now());
      insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id,created_at)
      values(v_qid,'other_generated','grammar_daily',null,now()) on conflict(question_id) do nothing;
      insert into english.question_concept_mappings(question_id,concept_id,family_id,mapping_confidence,mapping_method,review_status,relation_type,created_at,updated_at)
      values(v_qid,v_concept,v_rule.rule_family,1,'grammar_rule_registry','verified','primary',now(),now())
      on conflict(question_id) do update set concept_id=excluded.concept_id,family_id=excluded.family_id,mapping_confidence=1,mapping_method='grammar_rule_registry',review_status='verified',updated_at=now();
      insert into english.grammar_question_variants(question_id,rule_key,question_family,variant_key,variant_fingerprint,generator_provider,critic_provider,quality_score,critic_decision,difficulty,metadata)
      values(v_qid,v_rule.rule_key,v_family,coalesce(nullif(v_item->>'variantKey',''),v_rule.rule_key||':'||v_family||':'||v_qid),
        md5(lower(regexp_replace(v_item->>'question','\s+',' ','g'))),coalesce(v_item->>'generatorProvider','chatgpt'),coalesce(v_item->>'criticProvider','chatgpt_self_critic'),
        nullif(v_item->'quality'->>'score','')::numeric,v_item->'quality'->>'decision',coalesce(nullif(v_item->>'difficulty',''),v_rule.difficulty),
        jsonb_build_object('plannerDecision',coalesce(v_item->'plannerDecision','{}'::jsonb),'sourceUrl',v_rule.source_url));
      insert into english.question_generation_provenance(question_id,owner_user_id,source_question_id,concept_id,intent,generation_source,critic,related_terms,model,usage,created_at)
      values(v_qid,null,null,v_concept,'grammar_daily_variant','chatgpt_daily_grammar',coalesce(v_item->'quality','{}'::jsonb),
        case when coalesce(v_rule.contrast_with,'')='' then '[]'::jsonb else jsonb_build_array(v_rule.contrast_with) end,
        coalesce(nullif(v_item->>'generatorModel',''),'GPT-5.6 Sol'),coalesce(v_item->'usage','{}'::jsonb),now()) on conflict(question_id) do nothing;
      insert into english.content_generation_audits(lane,entity_key,generator_provider,generator_model,critic_provider,critic_model,quality_score,critic_decision,repair_count,question_family,variant_key,variant_fingerprint,publication_result,metadata,created_at)
      values('grammar',v_qid,'chatgpt',coalesce(nullif(v_item->>'generatorModel',''),'GPT-5.6 Sol'),'chatgpt_self_critic',coalesce(nullif(v_item->>'criticModel',''),'GPT-5.6 Sol'),
        nullif(v_item->'quality'->>'score','')::numeric,v_item->'quality'->>'decision',coalesce((v_item->>'repairCount')::integer,0),v_family,v_item->>'variantKey',
        md5(lower(regexp_replace(v_item->>'question','\s+',' ','g'))),'published',jsonb_build_object('ruleKey',v_rule.rule_key,'batchDate',r.batch_date),now());
      v_new:=v_new+1;
    end if;

    insert into english.grammar_daily_items(batch_date,slot_no,source_id,question_id,rule_key,requested_family,question_family,generator_provider,is_new_variant,metadata)
    values(r.batch_date,(v_item->>'slotNo')::integer,v_source_id,v_qid,v_rule.rule_key,v_assignment->>'preferredQuestionFamily',v_family,
      coalesce(v_item->>'generatorProvider','chatgpt'),lower(coalesce(v_item->>'generatorProvider',''))<>'canonical_bank',
      jsonb_build_object('selectionType',v_assignment->>'selectionType','plannerDecision',coalesce(v_item->'plannerDecision','{}'::jsonb)))
    on conflict(batch_date,slot_no) do update set question_id=excluded.question_id,rule_key=excluded.rule_key,requested_family=excluded.requested_family,
      question_family=excluded.question_family,generator_provider=excluded.generator_provider,is_new_variant=excluded.is_new_variant,metadata=excluded.metadata;
    insert into english.grammar_rule_evidence(user_id,rule_key,introduced_at,last_selected_at,selection_count,updated_at)
    values(uid,v_rule.rule_key,now(),now(),1,now())
    on conflict(user_id,rule_key) do update set introduced_at=coalesce(english.grammar_rule_evidence.introduced_at,excluded.introduced_at),
      last_selected_at=excluded.last_selected_at,selection_count=english.grammar_rule_evidence.selection_count+1,updated_at=now();
  end loop;

  select count(*) into v_count from english.grammar_daily_items where batch_date=r.batch_date;
  if v_count<>20 then raise exception 'Grammar publication invariant failed: % of 20 daily rows',v_count; end if;
  insert into english.sources(source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,source_ref,notes,import_status,new_count,recall_count,duplicate_count,category_summary,processed_on)
  values(v_source_id,'Grammar Daily','SSC Grammar Daily',v_source_file,r.batch_date,true,now(),20,'Grammar Intelligence + ChatGPT planner/generator',
    v_new||' ChatGPT-generated canonical variants; '||v_reused||' existing permanent Question_IDs reused. Exact-20 atomic publication.',
    'Complete',v_new,v_reused,0,'Grammar',now())
  on conflict(source_id) do update set question_count=20,notes=excluded.notes,import_status='Complete',new_count=v_new,recall_count=v_reused,processed_on=now();
  update english.grammar_generation_batches set status='applied',applied_at=now(),updated_at=now(),last_error=null where run_id=p_run_id;
  update english.chatgpt_content_task_runs set status='applied',applied_at=now(),updated_at=now(),result=jsonb_build_object('ok',true,'count',20,'generatedByChatGPT',v_new,'reused',v_reused,'sourceId',v_source_id) where run_id=p_run_id;
  return jsonb_build_object('ok',true,'count',20,'date',r.batch_date,'sourceId',v_source_id,'generatedByChatGPT',v_new,'reused',v_reused);
end
$function$;

revoke all on function english.maintenance_grammar_batch(integer) from public;
revoke all on function public.english_grammar_task_apply(uuid,jsonb) from public;
grant execute on function english.maintenance_grammar_batch(integer) to service_role;
grant execute on function public.english_grammar_task_apply(uuid,jsonb) to service_role;

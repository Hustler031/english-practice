-- Controlled review-only path for external SSC mock questions that cannot be safely matched to an existing canonical Question_ID.
-- The staging row remains the provenance/audit record. No existing Question_ID is repurposed.
create or replace function public.maths_create_canonical_from_external_stage(p_stage_id uuid,p_canonical jsonb)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','maths' as $$
declare
  uid uuid:=maths._require_uid(); st maths.external_mock_staging%rowtype; qid text; prompt_ text; chapter_ text; topic_ text; subtopic_ text; card_ text; answer_ text; explanation_ text; cue_ text; correct_ text; template_ text; concept_ text; evidence_ uuid; result_ text; response_ numeric; inferred_ text; confirmed_ text; baseline_ numeric; timing_ text;
begin
  select * into st from maths.external_mock_staging where stage_id=p_stage_id and user_id=uid for update;
  if not found then raise exception 'External mock stage not found'; end if;
  if st.review_status not in('needs_review','pending') or st.matched_question_id is not null then raise exception 'External stage is already resolved/matched'; end if;
  prompt_:=coalesce(nullif(btrim(p_canonical->>'prompt'),''),nullif(btrim(st.extracted_payload->>'prompt'),''),nullif(btrim(st.extracted_payload->>'question'),''));
  chapter_:=nullif(btrim(p_canonical->>'chapter'),''); topic_:=nullif(btrim(p_canonical->>'topic'),''); subtopic_:=nullif(btrim(p_canonical->>'subtopic'),''); card_:=coalesce(nullif(btrim(p_canonical->>'cardType'),''),'PYQ');
  answer_:=coalesce(nullif(btrim(p_canonical->>'answer'),''),nullif(btrim(st.extracted_payload->>'answer'),'')); explanation_:=nullif(btrim(p_canonical->>'explanation'),''); cue_:=nullif(btrim(p_canonical->>'memoryCue'),''); correct_:=upper(nullif(btrim(p_canonical->>'correctOption'),'')); template_:=nullif(btrim(p_canonical->>'templateGroup'),'');
  if prompt_ is null or chapter_ is null or topic_ is null then raise exception 'Reviewed canonical question requires prompt, chapter and topic'; end if;
  if correct_ is not null and correct_ not in('A','B','C','D') then raise exception 'correctOption must be A/B/C/D when supplied'; end if;
  qid:='EXT_'||replace(substr(p_stage_id::text,1,18),'-','');
  if exists(select 1 from maths.questions where question_id=qid) then raise exception 'Generated external Question_ID collision'; end if;
  insert into maths.questions(question_id,chapter,topic,subtopic,card_type,prompt,answer,explanation,memory_cue,difficulty,marked_default,mastered_default,source_file,source_url,status,answer_mode,option_a,option_b,option_c,option_d,correct_option,template_group,variant_types,rotation_tier,practice_bank,added_at,generated)
  values(qid,chapter_,topic_,subtopic_,card_,prompt_,answer_,explanation_,cue_,null,false,false,coalesce(st.source_label,'External Mock'),st.source_ref,'active',case when correct_ is not null then 'MCQ' else 'REVEAL' end,
    nullif(btrim(coalesce(p_canonical->>'optionA',st.extracted_payload->>'optionA')),''),nullif(btrim(coalesce(p_canonical->>'optionB',st.extracted_payload->>'optionB')),''),nullif(btrim(coalesce(p_canonical->>'optionC',st.extracted_payload->>'optionC')),''),nullif(btrim(coalesce(p_canonical->>'optionD',st.extracted_payload->>'optionD')),''),correct_,template_,coalesce(nullif(btrim(p_canonical->>'variantTypes'),''),'STATIC'),'normal','ACADEMIC',now(),false);
  insert into maths.question_bank_memberships(question_id,bank_key,source_bank_value,source_rule,source_order,migration_run_id)
  values(qid,'ACADEMIC','EXTERNAL_MOCK','external_review_confirmed',null,'external:'||p_stage_id::text);
  concept_:=maths._concept_key(chapter_,topic_,subtopic_);
  insert into maths.concept_catalog(concept_id,concept_name,chapter,topic,subtopic,source)
  values(concept_,coalesce(subtopic_,topic_,chapter_),chapter_,topic_,subtopic_,'external_review') on conflict(concept_id) do nothing;
  insert into maths.question_concepts(question_id,concept_id,source,confidence,active) values(qid,concept_,'external_review',1,true) on conflict do nothing;
  if template_ is not null then
    insert into maths.family_catalog(family_id,family_name,chapter,topic,subtopic,recognition_trigger,source)
    values(template_,template_,chapter_,topic_,subtopic_,cue_,'external_review') on conflict(family_id) do nothing;
    insert into maths.question_families(question_id,family_id,source,confidence,active) values(qid,template_,'external_review',1,true) on conflict(question_id) do nothing;
  end if;
  update maths.external_mock_staging set matched_question_id=qid,match_confidence=1,match_method='review_created_canonical',review_status='resolved',resolved_at=now() where stage_id=p_stage_id and user_id=uid;
  result_:=lower(coalesce(st.extracted_payload->>'result',''));
  if result_ in('correct','wrong','seen') then
    response_:=greatest(0,least(coalesce(nullif(st.extracted_payload->>'responseSec','')::numeric,0),86400)); inferred_:=upper(nullif(st.extracted_payload->>'inferredReason','')); confirmed_:=upper(nullif(st.extracted_payload->>'userReason',''));
    if inferred_ not in('CAL','APP','CON','FOR','SILLY','TIME') then inferred_:=null; end if; if confirmed_ not in('CAL','APP','CON','FOR','SILLY','TIME') then confirmed_:=null; end if;
    baseline_:=maths._baseline_sec(uid,qid,now()); timing_:=maths._timing_class(result_,response_,baseline_);
    insert into maths.performance_evidence(user_id,question_id,evidence_source,inferred_reason,user_confirmed_reason,inference_confidence,correctness,response_sec,baseline_sec,timing_class,slow_correct,confidence_response,metadata)
    values(uid,qid,'external_mock',inferred_,confirmed_,case when inferred_ is null then null else .65 end,result_,response_,baseline_,timing_,timing_='correct_slow',case when lower(coalesce(st.extracted_payload->>'confidence','')) in('sure','50_50','guess') then lower(st.extracted_payload->>'confidence') end,jsonb_build_object('stageId',p_stage_id,'createdCanonical',true,'sourceLabel',st.source_label,'sourceRef',st.source_ref)) returning evidence_id into evidence_;
    perform maths._refresh_concept_state(uid,concept_); if template_ is not null then perform maths._refresh_family_state(uid,template_); end if; perform maths._sync_repair_from_evidence(evidence_);
  end if;
  return jsonb_build_object('ok',true,'stageId',p_stage_id,'questionId',qid,'status','resolved','createdCanonical',true);
end $$;
revoke all on function public.maths_create_canonical_from_external_stage(uuid,jsonb) from public,anon;
grant execute on function public.maths_create_canonical_from_external_stage(uuid,jsonb) to authenticated;

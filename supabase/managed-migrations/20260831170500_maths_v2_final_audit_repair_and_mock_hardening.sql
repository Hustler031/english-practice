-- Maths V2 final audit hardening.
-- Forward-only: preserve canonical questions, attempts, sessions and historical evidence.

create or replace function public.maths_start_repair(p_count integer default 5, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  ids text[];
  out_ jsonb;
  sid_ text;
begin
  ids:=maths._repair_candidate_ids(uid,greatest(1,least(coalesce(p_count,5),20)),nullif(upper(p_reason),''));
  out_:=maths._start_session(
    uid,
    ids,
    'repair',
    'Targeted Repair'||case when p_reason is null then '' else ' · '||upper(p_reason) end,
    jsonb_build_object('reason',upper(p_reason),'repair',true,'transferFirst',true,'selectedQuestionIds',to_jsonb(coalesce(ids,array[]::text[]))),
    false
  );
  sid_:=nullif(out_->>'sessionId','');

  if sid_ is not null then
    with target_repairs as (
      select distinct rq.repair_id
      from maths.repair_queue rq
      where rq.user_id=uid
        and rq.status in('open','waiting_confirmation')
        and (rq.due_at<=now() or rq.priority='P0')
        and (p_reason is null or rq.reason=upper(p_reason))
        and (
          (rq.scope_type='question' and rq.scope_id=any(ids))
          or (rq.scope_type='family' and exists(
                select 1
                from maths.question_families qf
                where qf.family_id=rq.scope_id and qf.active and qf.question_id=any(ids)
              ))
          or (rq.scope_type='concept' and exists(
                select 1
                from maths.question_concepts qc
                where qc.concept_id=rq.scope_id and qc.active and qc.question_id=any(ids)
              ))
        )
    ), updated as (
      update maths.repair_queue rq
      set status='in_progress',
          repair_attempts=repair_attempts+1,
          last_repair_at=now(),
          updated_at=now()
      where rq.repair_id in(select repair_id from target_repairs)
      returning rq.repair_id
    )
    update maths.sessions s
    set params=coalesce(s.params,'{}'::jsonb)||jsonb_build_object(
      'repairQueueIds',coalesce((select jsonb_agg(repair_id::text) from updated),'[]'::jsonb)
    ),updated_at=now()
    where s.session_id=sid_ and s.user_id=uid;

    return maths._get_session(uid,sid_);
  end if;

  return out_;
end
$$;

create or replace function public.maths_resolve_external_mock_stage(p_stage_id uuid,p_question_id text,p_match_confidence numeric default 1)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  st maths.external_mock_staging%rowtype;
  result_ text;
  response_ numeric;
  inferred_ text;
  confirmed_ text;
  confidence_ text;
  baseline_ numeric;
  timing_ text;
  evidence_ uuid;
  concept_ text;
  family_ text;
  decision_ text;
begin
  if not exists(select 1 from maths.runtime_questions where question_id=p_question_id and runtime_active) then
    raise exception 'Canonical question not found';
  end if;

  select * into st
  from maths.external_mock_staging
  where stage_id=p_stage_id and user_id=uid
  for update;
  if not found then raise exception 'External mock stage not found'; end if;

  if st.review_status='resolved' and st.matched_question_id is not null and st.matched_question_id<>p_question_id then
    raise exception 'External mock stage is already resolved to another question';
  end if;

  update maths.external_mock_staging
  set matched_question_id=p_question_id,
      match_confidence=greatest(0,least(coalesce(p_match_confidence,1),1)),
      match_method=case when review_status='resolved' then coalesce(match_method,'review_confirmed') else 'review_confirmed' end,
      review_status='resolved',
      resolved_at=coalesce(resolved_at,now())
  where stage_id=p_stage_id and user_id=uid;

  result_:=lower(coalesce(st.extracted_payload->>'result',''));
  if result_ in('correct','wrong','seen','unattempted')
     and not exists(
       select 1 from maths.performance_evidence pe
       where pe.user_id=uid
         and pe.evidence_source='external_mock'
         and pe.metadata->>'stageId'=p_stage_id::text
     ) then
    response_:=greatest(0,least(coalesce(nullif(st.extracted_payload->>'responseSec','')::numeric,0),86400));
    inferred_:=upper(nullif(st.extracted_payload->>'inferredReason',''));
    confirmed_:=upper(nullif(st.extracted_payload->>'userReason',''));
    confidence_:=lower(nullif(st.extracted_payload->>'confidence',''));
    decision_:=upper(nullif(st.extracted_payload->>'decision',''));
    if inferred_ not in('CAL','APP','CON','FOR','SILLY','TIME') then inferred_:=null; end if;
    if confirmed_ not in('CAL','APP','CON','FOR','SILLY','TIME') then confirmed_:=null; end if;
    if confidence_ not in('sure','50_50','guess') then confidence_:=null; end if;
    if decision_ not in('SOLVE','LATER','SKIP') then decision_:=null; end if;

    baseline_:=maths._baseline_sec(uid,p_question_id,now());
    timing_:=maths._timing_class(result_,response_,baseline_);

    insert into maths.performance_evidence(
      user_id,question_id,evidence_source,inferred_reason,user_confirmed_reason,inference_confidence,
      correctness,response_sec,baseline_sec,timing_class,slow_correct,confidence_response,selection_decision,metadata
    ) values(
      uid,p_question_id,'external_mock',inferred_,confirmed_,case when inferred_ is null then null else .65 end,
      result_,response_,baseline_,timing_,timing_='correct_slow',confidence_,decision_,
      jsonb_build_object('stageId',p_stage_id,'sourceLabel',st.source_label,'sourceRef',st.source_ref,'reviewMatched',true)
    ) returning evidence_id into evidence_;

    select concept_id into concept_
    from maths.question_concepts
    where question_id=p_question_id and active
    order by confidence desc limit 1;
    if concept_ is not null then perform maths._refresh_concept_state(uid,concept_); end if;

    select family_id into family_
    from maths.question_families
    where question_id=p_question_id and active limit 1;
    if family_ is not null then perform maths._refresh_family_state(uid,family_); end if;

    perform maths._sync_repair_from_evidence(evidence_);
  end if;

  return jsonb_build_object(
    'ok',true,
    'stageId',p_stage_id,
    'matchedQuestionId',p_question_id,
    'status','resolved',
    'evidencePromoted',evidence_ is not null
  );
end
$$;

grant execute on function public.maths_start_repair(integer,text) to authenticated;
grant execute on function public.maths_resolve_external_mock_stage(uuid,text,numeric) to authenticated;

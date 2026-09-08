create or replace function public.english_phrasal_single_slot_store(p_run_id uuid,p_slot_no integer,p_item jsonb default null::jsonb,p_error text default null::text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,english,auth
as $$
declare
  b english.phrasal_generation_batches%rowtype;
  s english.phrasal_generation_slots%rowtype;
  v_ready integer;
  v_failed integer;
  v_items jsonb;
  v_concept text;
  v_family text;
  v_legacy_family text;
  v_original_family text;
  v_availability_fallback boolean:=false;
  v_followup_request bigint;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;

  select * into b from english.phrasal_generation_batches where run_id=p_run_id for update;
  if not found then raise exception 'Unknown Phrasal generation run'; end if;

  select * into s from english.phrasal_generation_slots
  where batch_date=b.batch_date and slot_no=p_slot_no for update;
  if not found then raise exception 'Unknown Phrasal generation slot'; end if;

  if nullif(btrim(coalesce(p_error,'')),'') is not null then
    update english.phrasal_generation_slots
      set status='failed',lease_expires_at=null,last_error=left(p_error,1200),updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
    update english.phrasal_generation_batches
      set last_error=left(p_error,1200),updated_at=now()
      where run_id=p_run_id;
  else
    if p_item is null or jsonb_typeof(p_item)<>'object' then raise exception 'Finalized Phrasal item is required'; end if;

    v_concept:=coalesce(nullif(p_item->>'conceptId',''),nullif(p_item->>'phrasalConceptId',''));
    v_family:=lower(coalesce(nullif(p_item->>'requestedQuestionFamily',''),nullif(p_item->>'questionFamily',''),'recognition'));
    v_availability_fallback:=coalesce((p_item->>'availabilityFallback')::boolean,false);
    v_original_family:=lower(coalesce(nullif(p_item->>'originalRequestedQuestionFamily',''),s.requested_family));
    v_legacy_family:=lower(coalesce(nullif(s.assignment->>'legacyFamily',''),nullif(s.assignment->>'phrasalQuestionFamily',''),s.requested_family));

    if v_concept<>s.concept_id then raise exception 'Phrasal slot concept drift: expected %, got %',s.concept_id,v_concept; end if;

    if v_family<>s.requested_family then
      if not (v_availability_fallback and v_original_family=s.requested_family and v_family=v_legacy_family) then
        raise exception 'Phrasal slot family drift: expected %, got %',s.requested_family,v_family;
      end if;
      update english.phrasal_generation_slots
      set requested_family=v_family,
          assignment=assignment||jsonb_build_object(
            'availabilityFallback',true,
            'availabilityFallbackFromFamily',s.requested_family,
            'availabilityFallbackToFamily',v_family,
            'availabilityFallbackAt',now()
          ),
          updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
    end if;

    update english.phrasal_generation_slots
      set status='ready',finalized=p_item,lease_expires_at=null,last_error=null,ready_at=now(),updated_at=now()
      where batch_date=b.batch_date and slot_no=p_slot_no;
  end if;

  select count(*) filter(where status='ready'),count(*) filter(where status='failed')
    into v_ready,v_failed from english.phrasal_generation_slots where batch_date=b.batch_date;

  if v_ready=20 then
    select jsonb_agg(finalized order by slot_no) into v_items
    from english.phrasal_generation_slots where batch_date=b.batch_date;
    update english.phrasal_generation_batches set status='ready',updated_at=now() where run_id=p_run_id;
  elsif nullif(btrim(coalesce(p_error,'')),'') is null then
    v_followup_request:=english.kick_phrasal_worker();
  end if;

  return jsonb_build_object(
    'ok',p_error is null,'runId',p_run_id,'slotNo',p_slot_no,'readyCount',v_ready,'failedCount',v_failed,
    'remaining',20-v_ready,'publishReady',v_ready=20,'followupRequestId',v_followup_request,
    'items',case when v_ready=20 then v_items else null end
  );
end;
$$;

create or replace function english.enqueue_missing_targeted_transfers(p_limit integer default 8)
returns integer
language plpgsql security definer
set search_path=pg_catalog,english
as $$
declare
  r record;
  n integer:=0;
  j uuid;
begin
  update english.targeted_transfer_jobs
  set status='queued',next_attempt_at=now(),last_error='stale generation recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts<3;

  update english.targeted_transfer_jobs
  set status='failed',next_attempt_at=null,
      last_error=coalesce(last_error,'transfer generation retries exhausted'),updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts>=3;

  update english.targeted_transfer_jobs j
  set status='queued',attempts=0,next_attempt_at=now(),
      metadata=coalesce(j.metadata,'{}'::jsonb)||jsonb_build_object(
        'terminalRecoveryCycles',coalesce((j.metadata->>'terminalRecoveryCycles')::int,0)+1,
        'terminalRecoveredAt',now()
      ),
      last_error='bounded terminal recovery after transient worker failure',updated_at=now()
  where j.status='failed' and j.attempts>=3
    and coalesce((j.metadata->>'terminalRecoveryCycles')::int,0)<1
    and j.updated_at<now()-interval '30 minutes'
    and (lower(coalesce(j.last_error,'')) like '%timed out%'
         or lower(coalesce(j.last_error,'')) like '%timeout%'
         or lower(coalesce(j.last_error,'')) like '%429%'
         or lower(coalesce(j.last_error,'')) like '%rate limit%')
    and exists(
      select 1 from english.learning_route_state lr
      where lr.user_id=j.user_id and lr.question_id=j.source_question_id and lr.route='targeted'
    )
    and not exists(
      select 1 from english.questions q2
      join english.question_concept_mappings m2 on m2.question_id=q2.question_id
      where q2.active and m2.concept_id=j.concept_id and q2.question_id<>j.source_question_id
        and english.question_visible_to_user(j.user_id,q2.question_id)
    );

  for r in
    select lr.user_id,lr.question_id,m.concept_id,
      case when coalesce(lr.metadata->>'targeted_kind','')='confusion'
        then nullif(lr.metadata->>'source_note_id','')::uuid else null end source_note_id,
      case when coalesce(lr.metadata->>'targeted_kind','')='confusion'
        then 'Explicit confusion lacks an alternate transfer item'
        else 'I Guessed transfer validation lacks an alternate item' end reason
    from english.learning_route_state lr
    join english.question_concept_mappings m on m.question_id=lr.question_id
    where lr.route='targeted'
      and coalesce(lr.metadata->>'targeted_kind','') in ('confusion','transfer_check')
      and not exists(
        select 1 from english.questions q2
        join english.question_concept_mappings m2 on m2.question_id=q2.question_id
        where q2.active and m2.concept_id=m.concept_id and q2.question_id<>lr.question_id
          and english.question_visible_to_user(lr.user_id,q2.question_id)
      )
    order by case coalesce(lr.metadata->>'targeted_kind','') when 'confusion' then 1 else 2 end,lr.updated_at desc
    limit greatest(1,least(12,coalesce(p_limit,8)))
  loop
    j:=english.ensure_transfer_generation_job(r.user_id,r.concept_id,r.question_id,r.source_note_id,null,r.reason);
    if j is not null then n:=n+1; end if;
  end loop;

  return n;
end;
$$;

create or replace function english.route_sprint_bank_to_targeted(
  p_uid uuid,
  p_question_id text,
  p_session_id uuid,
  p_position integer
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
begin
  if p_uid is null or nullif(btrim(coalesce(p_question_id,'')),'') is null then
    return;
  end if;

  perform english.route_to_targeted(
    p_uid,
    p_question_id,
    'Sprint Bank',
    'User Curated · Saved from Sprint'
  );

  update english.learning_route_state
  set metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'targeted_kind','need_learning',
        'userCurated',true,
        'userCuratedSource','sprint_bank',
        'sourceSessionId',p_session_id,
        'sourcePosition',p_position,
        'userCuratedAt',now()
      ),
      last_route_reason='User Curated · Saved from Sprint',
      updated_at=now()
  where user_id=p_uid and question_id=p_question_id;
end
$function$;

create or replace function english.promote_sprint_bank_item(p_uid uuid, p_session_id uuid, p_position integer)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  i english.sprint_items%rowtype;
  qid text;
  oa text; ob text; oc text; od text;
  subj text;
  v_concept text;
  v_source_question text;
begin
  if p_uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=p_uid and s.status='completed') then return null; end if;
  if not exists(select 1 from english.sprint_bank_items b where b.user_id=p_uid and b.source_session_id=p_session_id and b.source_position=p_position) then return null; end if;

  select * into i from english.sprint_items where session_id=p_session_id and position=p_position;
  if not found then raise exception 'Sprint item not found'; end if;

  subj:=english.sprint_bank_subject(i.category,i.question_type);
  oa:=english.sprint_option_text(i.options,'A');
  ob:=english.sprint_option_text(i.options,'B');
  oc:=english.sprint_option_text(i.options,'C');
  od:=english.sprint_option_text(i.options,'D');
  if oa='' or ob='' or oc='' or od='' then raise exception 'Sprint option mapping incomplete at %',p_position; end if;

  select q.question_id into qid
  from english.questions q
  where q.active
    and regexp_replace(lower(btrim(q.question)),'\s+',' ','g')=regexp_replace(lower(btrim(i.question)),'\s+',' ','g')
    and lower(btrim(coalesce(q.option_a,'')))=lower(btrim(oa))
    and lower(btrim(coalesce(q.option_b,'')))=lower(btrim(ob))
    and lower(btrim(coalesce(q.option_c,'')))=lower(btrim(oc))
    and lower(btrim(coalesce(q.option_d,'')))=lower(btrim(od))
    and upper(coalesce(q.correct,''))=upper(coalesce(i.correct_key,''))
  order by q.created_at asc,q.question_id asc
  limit 1;

  v_concept:=nullif(btrim(coalesce(i.metadata->>'conceptKey','')),'');

  if qid is null then
    qid:='SPBANK_'||replace(substr(p_session_id::text,1,8),'-','')||'_'||lpad(p_position::text,2,'0');
    if not exists(select 1 from english.questions q where q.question_id=qid) then
      insert into english.questions(
        question_id,topic,question,option_a,option_b,option_c,option_d,correct,explanation,
        question_type,source_file,concept_id,difficulty,source_id,learning_status,content_status,
        exam_relevance,active,created_at,updated_at
      ) values(
        qid,i.category,i.question,oa,ob,oc,od,i.correct_key,i.explanation,
        i.question_type,'GPT SSC Sprint Bank',coalesce(v_concept,qid),
        coalesce(nullif(i.metadata->>'difficultyTier',''),'Medium'),
        'SprintBank:'||p_session_id::text||':'||p_position::text,
        'New','Active','SSC CGL User-selected Sprint Bank',true,now(),now()
      );
    end if;
  end if;

  if v_concept is not null then
    insert into english.concepts(
      concept_id,domain,skill_family,name,description,confidence,exam_relevance,
      priority_score,coverage_state,is_atomic,active,metadata,created_at,updated_at
    ) values(
      v_concept,'English',coalesce(nullif(i.category,''),'Unclassified'),v_concept,
      'Canonical concept carried from a user-curated SSC Sprint question.',
      'medium','medium',0,'unseen',true,true,
      jsonb_build_object('source','user_curated_sprint_bank','sourceSessionId',p_session_id,'sourcePosition',p_position),
      now(),now()
    ) on conflict(concept_id) do nothing;

    insert into english.question_concept_mappings(
      question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type,created_at,updated_at
    ) values(qid,v_concept,0.95,'sprint_metadata','mapped','primary',now(),now())
    on conflict(question_id) do nothing;
  end if;

  v_source_question:=case
    when i.canonical_question_id is not null and exists(select 1 from english.questions q where q.question_id=i.canonical_question_id)
      then i.canonical_question_id
    else null
  end;

  insert into english.question_generation_provenance(
    question_id,owner_user_id,source_question_id,concept_id,intent,generation_source,
    critic,related_terms,model,usage,created_at
  ) values(
    qid,p_uid,v_source_question,v_concept,'user_curated_from_mock','sprint_bank',
    jsonb_build_object(
      'qualityScore',i.metadata->'qualityScore',
      'trapStrength',i.metadata->'trapStrength',
      'selfCriticPassed',i.metadata->'chatgptSelfCriticPassed'
    ),
    '[]'::jsonb,
    null,
    jsonb_build_object(
      'sourceSessionId',p_session_id,
      'sourcePosition',p_position,
      'sourceItemKey',i.item_key,
      'sourceType',i.source_type,
      'category',i.category,
      'questionType',i.question_type,
      'savedByUser',true,
      'savedAt',now(),
      'metadata',coalesce(i.metadata,'{}'::jsonb)
    ),
    now()
  ) on conflict(question_id) do nothing;

  perform english.route_sprint_bank_to_targeted(p_uid,qid,p_session_id,p_position);

  if exists(
    select 1 from english.sprint_bank_items b
    where b.user_id=p_uid and b.question_id=qid
      and not (b.source_session_id=p_session_id and b.source_position=p_position)
  ) then
    delete from english.sprint_bank_items
    where user_id=p_uid and source_session_id=p_session_id and source_position=p_position;
    return qid;
  end if;

  update english.sprint_bank_items
  set question_id=qid,subject=subj,promoted_at=coalesce(promoted_at,now())
  where user_id=p_uid and source_session_id=p_session_id and source_position=p_position;

  return qid;
end
$function$;

do $backfill$
declare r record;
begin
  for r in
    select user_id,question_id,source_session_id,source_position
    from english.sprint_bank_items
    where question_id is not null
  loop
    perform english.route_sprint_bank_to_targeted(r.user_id,r.question_id,r.source_session_id,r.source_position);
  end loop;
end
$backfill$;

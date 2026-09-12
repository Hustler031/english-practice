-- Natural-language Add Context routing + simple Learning Insights audit payload.
-- Production was applied first; this file keeps the repository contract in sync.

create or replace function english.context_content_action_from_note(p_note text)
returns text
language plpgsql
immutable
set search_path to 'pg_catalog','english'
as $function$
declare
  s text:=lower(regexp_replace(trim(coalesce(p_note,'')),'[[:space:]]+',' ','g'));
begin
  if s='' then return 'none'; end if;

  if s ~ '(change|improv|replace|rewrite|make|karo|kar do|krdo|badal|badlo).*(option|choice|distractor)'
     or s ~ '(option|choice|distractor).*(change|improv|replace|rewrite|make|karo|kar do|krdo|badal|badlo)' then
    return 'improve_options';
  end if;

  if s ~ '(add|give|include|write|explain|provide).*(explanation|meaning).*(all|every).*(option|choice|word)'
     or s ~ '(all|every).*(option|choice|word).*(explain|explanation|meaning)'
     or s ~ 'explain.*(all|every).*(option|choice|word)'
     or s ~ 'add explanation.*(option|choice|word)' then
    return 'explain_all_options';
  end if;

  if s ~ '(enrich|improve|expand|enhance|rewrite|strengthen|detail|detailed|better|add|change|simplif|simple|clear).*(the )?explanation'
     or s ~ '(the )?explanation.*(weak|poor|short|brief|incomplete|vague|better|detail|detailed|improve|expand|enrich|simple|clear)'
     or s ~ '(give|provide|need|want).*(better|detailed|richer|more detailed|simple|clear).*(explanation)'
     or s ~ '(meaning|difference|usage|rule|preposition).*(add|include|explain).*(explanation)'
     or s ~ '(add|include|explain).*(meaning|difference|usage|rule|preposition).*(explanation)' then
    return 'enrich_explanation';
  end if;

  return 'none';
end
$function$;

create or replace function english.queue_context_content_action_internal(p_note_id uuid,p_content_action text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  n english.learner_context_notes%rowtype;
  q english.questions%rowtype;
  v_action text:=lower(trim(coalesce(p_content_action,'')));
  v_reason text;
  v_existing uuid;
  v_existing_status text;
  v_version integer;
  v_base_version integer:=0;
  v_base jsonb;
  v_id uuid;
  v_key text;
begin
  select * into n from english.learner_context_notes where note_id=p_note_id for update;
  if not found then raise exception 'context note not found'; end if;

  if v_action not in ('enrich_explanation','explain_all_options','improve_options') then
    return jsonb_build_object('ok',true,'queued',false,'contentAction','none');
  end if;
  v_reason:=case when v_action='improve_options' then 'options_too_obvious' else 'explanation_weak' end;

  if nullif(n.diagnosis->>'content_proposal_id','') is not null then
    begin
      v_existing:=(n.diagnosis->>'content_proposal_id')::uuid;
      select status into v_existing_status from english.question_revision_proposals where proposal_id=v_existing and user_id=n.user_id;
      if found then
        return jsonb_build_object('ok',true,'queued',false,'alreadyQueued',true,'contentAction',v_action,'proposalId',v_existing,'status',v_existing_status);
      end if;
    exception when invalid_text_representation then
      v_existing:=null;
    end;
  end if;

  v_key:='context:'||n.note_id::text;
  select proposal_id,status into v_existing,v_existing_status
  from english.question_revision_proposals
  where user_id=n.user_id and idempotency_key=v_key
  order by created_at desc limit 1;
  if found then
    update english.learner_context_notes
    set diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object(
      'content_action',v_action,'content_proposal_id',v_existing::text,'content_requested_at',now())
    where note_id=n.note_id;
    return jsonb_build_object('ok',true,'queued',false,'alreadyQueued',true,'contentAction',v_action,'proposalId',v_existing,'status',v_existing_status);
  end if;

  if exists(
    select 1 from english.question_revision_proposals p
    where p.user_id=n.user_id and p.question_id=n.question_id
      and p.created_at>n.created_at and p.status<>'superseded'
  ) then
    update english.learner_context_notes
    set diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object(
      'content_action',v_action,'content_status','skipped_newer_revision')
    where note_id=n.note_id;
    return jsonb_build_object('ok',true,'queued',false,'skipped','newer_revision_exists','contentAction',v_action);
  end if;

  select * into q from english.questions where question_id=n.question_id and active;
  if not found or not english.question_visible_to_user(n.user_id,n.question_id) then
    raise exception 'question not found for context content action';
  end if;
  if upper(coalesce(q.correct,'')) not in ('A','B','C','D') then
    raise exception 'question is not eligible for revision';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(n.user_id::text||'|'||n.question_id,0));
  select r.proposal_version,p.proposed_payload into v_base_version,v_base
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=n.user_id and r.question_id=n.question_id;

  if v_base is null then
    v_base:=jsonb_build_object(
      'question',q.question,'optionA',q.option_a,'optionB',q.option_b,'optionC',q.option_c,'optionD',q.option_d,
      'correctKey',upper(q.correct),'explanation',coalesce(q.explanation,''),
      'questionType',coalesce(q.question_type,''),'difficulty',coalesce(q.difficulty,''),'word',coalesce(q.word,''));
    v_base_version:=0;
  end if;

  update english.question_revision_proposals
  set status='superseded',superseded_at=now(),updated_at=now()
  where user_id=n.user_id and question_id=n.question_id and status in ('queued','processing','ready');

  select coalesce(max(proposal_version),0)+1 into v_version
  from english.question_revision_proposals where user_id=n.user_id and question_id=n.question_id;

  insert into english.question_revision_proposals(
    user_id,question_id,proposal_version,base_version,feedback_reason,feedback_note,status,base_payload,next_attempt_at,idempotency_key
  ) values(
    n.user_id,n.question_id,v_version,v_base_version,v_reason,left(n.note,600),'queued',v_base,now(),v_key
  ) returning proposal_id into v_id;

  update english.learner_context_notes
  set diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object(
    'content_action',v_action,'content_proposal_id',v_id::text,'content_requested_at',now())
  where note_id=n.note_id;

  begin perform english.kick_revision_worker(1); exception when others then null; end;
  return jsonb_build_object('ok',true,'queued',true,'contentAction',v_action,'proposalId',v_id,'status','queued');
end
$function$;

create or replace function english.process_context_note_rule_based(p_user_id uuid,p_note_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  n english.learner_context_notes%rowtype; cid text; rcid text;
  is_confusion boolean:=false; is_retention boolean:=false; is_rule boolean:=false; needs_ai boolean:=false;
  related_ids text[]:='{}'::text[]; related_words text[]:='{}'::text[]; rid text; rword text;
  action_taken text:='none'; diagnosis_type text:='context_signal'; targeted_kind text:='need_learning';
  content_action text:='none'; content_result jsonb:='{}'::jsonb;
begin
  select * into n from english.learner_context_notes where note_id=p_note_id and user_id=p_user_id for update;
  if not found then raise exception 'Context note not found'; end if;
  if n.processing_status='done' then return coalesce(n.diagnosis,'{}'::jsonb)||jsonb_build_object('ok',true,'already_processed',true); end if;
  update english.learner_context_notes set processing_status='processing' where note_id=p_note_id;
  select concept_id into cid from english.question_concept_mappings where question_id=n.question_id;

  is_confusion:=lower(n.note) ~ '(confus|difference|same meaning|mix( |-|_)up|versus|(^|[^a-z])vs([^a-z]|$)|similar|cannot distinguish|can.t distinguish|problem (in|with))';
  is_retention:=lower(n.note) ~ '(forget|forgot|remember|recall|keep forgetting|not retain|retention|baar baar|bar bar)';
  is_rule:=lower(n.note) ~ '(rule|grammar|passive|active voice|narration|preposition|usage rule|structure)';
  content_action:=english.context_content_action_from_note(n.note);

  if is_confusion then
    select coalesce(array_agg(x.question_id),'{}'::text[]),coalesce(array_agg(x.word),'{}'::text[])
    into related_ids,related_words from(
      select q.question_id,trim(q.word) word
      from english.questions q left join english.question_concept_mappings qm on qm.question_id=q.question_id
      where q.active and q.question_id<>n.question_id and english.question_visible_to_user(p_user_id,q.question_id)
        and nullif(trim(coalesce(q.word,'')),'') is not null and char_length(trim(q.word))>=4
        and position(' '||regexp_replace(lower(trim(q.word)),'[^[:alnum:]]+',' ','g')||' '
          in ' '||regexp_replace(lower(n.note),'[^[:alnum:]]+',' ','g')||' ')>0
        and (cid is null or qm.concept_id is distinct from cid)
      order by char_length(trim(q.word)) desc,q.question_id limit 4
    ) x;
  end if;

  if is_confusion then diagnosis_type:='confusion_pair'; targeted_kind:='confusion';
  elsif is_retention then diagnosis_type:='retention_problem'; targeted_kind:='retention_check';
  elsif is_rule then diagnosis_type:='rule_gap'; targeted_kind:='need_learning';
  else diagnosis_type:='context_signal'; targeted_kind:='need_learning'; end if;

  needs_ai:=(is_confusion and cardinality(related_ids)=0)
            or (not is_confusion and not is_retention and not is_rule and content_action='none');

  if cid is not null and (is_confusion or is_retention or is_rule) then
    perform english.route_to_targeted(p_user_id,n.question_id,'Learner Context',
      case diagnosis_type when 'confusion_pair' then 'Learner supplied a confusion/context signal'
      when 'retention_problem' then 'Learner reported a retention problem'
      when 'rule_gap' then 'Learner reported a rule/usage gap' else 'Learner context needs repair' end);
    update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'targeted_kind',targeted_kind,'source_note_id',p_note_id,'concept_id',cid),updated_at=now()
    where user_id=p_user_id and question_id=n.question_id;
    action_taken:='targeted_mastery';
  end if;

  if is_confusion then
    for rid,rword in select * from unnest(related_ids,related_words) loop
      select concept_id into rcid from english.question_concept_mappings where question_id=rid;
      perform english.route_to_targeted(p_user_id,rid,'Learner Context Related','Related item named in learner context note');
      update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'targeted_kind','confusion','source_note_id',p_note_id,'related_to_question',n.question_id),updated_at=now()
      where user_id=p_user_id and question_id=rid;
      if cid is not null then perform english.upsert_learner_confusion(p_user_id,cid,n.question_id,rword,rid,rcid,p_note_id,
        jsonb_build_object('source','context','processor','deterministic_v3')); end if;
    end loop;
  end if;

  update english.question_state set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours')
  where user_id=p_user_id and question_id=n.question_id and not coalesce(mastered,false);

  update english.learner_context_notes set processing_status='done',
    ai_status=case when needs_ai then 'queued' else 'not_needed' end,ai_error=null,
    diagnosis=jsonb_strip_nulls(jsonb_build_object(
      'type',diagnosis_type,'action',action_taken,'concept_id',cid,
      'related_question_ids',to_jsonb(related_ids),'related_terms',to_jsonb(related_words),
      'needs_ai',needs_ai,'processor','deterministic_v3',
      'content_action',case when content_action<>'none' then content_action else null end)),processed_at=now()
  where note_id=p_note_id;

  if content_action<>'none' then
    content_result:=english.queue_context_content_action_internal(p_note_id,content_action);
  end if;

  if action_taken='targeted_mastery' then
    perform english.log_learning_activity(p_user_id,'context_targeted','Context added to Targeted',
      case when cardinality(related_words)>0 then 'Confusion detected: '||array_to_string(related_words,' ↔ ')||' · focused repair queued'
      when diagnosis_type='retention_problem' then 'Retention problem detected · validation queued'
      when diagnosis_type='rule_gap' then 'Rule gap detected · focused repair queued'
      else 'Learning context routed for focused repair' end,
      n.question_id,cid,p_note_id,'targeted',jsonb_build_object('diagnosis',diagnosis_type,'related_terms',related_words),n.created_at);
  elsif needs_ai then
    perform english.log_learning_activity(p_user_id,'context_ai_queued','Context queued for background analysis',
      'Your note needs deeper interpretation; study can continue normally.',n.question_id,cid,p_note_id,null,
      jsonb_build_object('diagnosis',diagnosis_type),n.created_at);
  end if;
  if content_action<>'none' then
    perform english.log_learning_activity(p_user_id,'context_content_change','Context requested a question improvement',
      case content_action when 'improve_options' then 'Answer options queued for critic-gated improvement'
      when 'explain_all_options' then 'Explanation of every option queued'
      else 'Explanation improvement queued' end,
      n.question_id,cid,p_note_id,null,jsonb_build_object('contentAction',content_action,'result',content_result),n.created_at);
  end if;
  if cid is not null then perform english.recompute_concept_evidence(p_user_id,cid); end if;
  return jsonb_build_object('ok',true,'note_id',p_note_id,'concept_id',cid,'action',action_taken,
    'content_action',content_action,'content_result',content_result,
    'related_question_ids',related_ids,'related_terms',related_words,'needs_ai',needs_ai);
exception when others then
  update english.learner_context_notes set processing_status='failed',ai_status='failed',ai_error=sqlerrm,
    diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object('error',sqlerrm,'processor','deterministic_v3'),processed_at=now()
  where note_id=p_note_id and user_id=p_user_id;
  raise;
end
$function$;

create or replace function english.context_revision_auto_apply_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare v_note_id uuid;
begin
  if new.status='ready' and old.status is distinct from 'ready' and new.proposed_payload is not null then
    select n.note_id into v_note_id
    from english.learner_context_notes n
    where n.user_id=new.user_id and n.question_id=new.question_id
      and n.diagnosis->>'content_proposal_id'=new.proposal_id::text
      and coalesce(n.diagnosis->>'content_action','none') in ('enrich_explanation','explain_all_options','improve_options')
    order by n.created_at desc limit 1;

    if v_note_id is not null then
      insert into english.user_question_revisions(user_id,question_id,proposal_id,proposal_version,applied_at)
      values(new.user_id,new.question_id,new.proposal_id,new.proposal_version,now())
      on conflict(user_id,question_id) do update
        set proposal_id=excluded.proposal_id,proposal_version=excluded.proposal_version,applied_at=now();

      update english.question_revision_proposals
      set status='applied',decided_at=now(),updated_at=now()
      where proposal_id=new.proposal_id and status='ready';

      update english.learner_context_notes
      set diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object('content_status','applied','content_applied_at',now())
      where note_id=v_note_id;
    end if;
  end if;
  return new;
end
$function$;

create or replace function public.english_get_learning_ai_updates(p_limit integer default 30)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_limit integer:=greatest(5,least(60,coalesce(p_limit,30)));
  v_context jsonb:='[]'::jsonb;
  v_revisions jsonb:='[]'::jsonb;
  v_summary jsonb:='{}'::jsonb;
begin
  if uid is null then raise exception 'authentication required'; end if;

  with recent as (
    select n.*,
           coalesce(nullif(btrim(q.word),''),nullif(btrim(c.name),''),nullif(left(btrim(q.question),96),''),'English question') display_name,
           coalesce(nullif(btrim(q.topic),''),'English') topic,
           exists(select 1 from english.learner_confusions cf where cf.user_id=uid and cf.source_note_id=n.note_id) created_confusion,
           exists(select 1 from english.learning_route_state r
             where r.user_id=uid and r.question_id=n.question_id and r.route='targeted'
               and ('Learner Context'=any(coalesce(r.origins,'{}'::text[])) or 'Learner Context Related'=any(coalesce(r.origins,'{}'::text[])))) changed_targeted,
           cp.status content_status,
           cp.feedback_reason content_feedback_reason,
           cp.base_payload content_original,
           case when cp.status in ('ready','applied','kept') then cp.proposed_payload else null end content_revised,
           case when cp.status in ('ready','applied','kept') then nullif(left(coalesce(cp.critic->>'rationale',''),700),'') else null end content_quality_note
    from english.learner_context_notes n
    left join english.questions q on q.question_id=n.question_id
    left join english.question_concept_mappings m on m.question_id=n.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    left join english.question_revision_proposals cp
      on cp.user_id=n.user_id
     and cp.proposal_id=case when coalesce(n.diagnosis->>'content_proposal_id','') ~ '^[0-9a-fA-F-]{36}$'
       then (n.diagnosis->>'content_proposal_id')::uuid else null end
    where n.user_id=uid
    order by n.created_at desc limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'kind','context','noteId',note_id,'questionId',question_id,'displayName',display_name,'topic',topic,
    'learnerNote',left(coalesce(note,''),700),
    'status',case
      when lower(coalesce(ai_status,''))='done' or lower(coalesce(processing_status,''))='done' then 'done'
      when lower(coalesce(ai_status,'')) in ('queued','processing') then lower(ai_status)
      when lower(coalesce(processing_status,'')) in ('queued','processing') then lower(processing_status)
      when lower(coalesce(ai_status,''))='failed' or lower(coalesce(processing_status,''))='failed' then 'failed'
      else coalesce(nullif(lower(ai_status),''),nullif(lower(processing_status),''),'pending') end,
    'understood',nullif(left(coalesce(diagnosis->>'rationale',''),900),''),
    'diagnosisType',nullif(diagnosis->>'type',''),'action',nullif(diagnosis->>'action',''),'urgency',nullif(diagnosis->>'urgency',''),
    'relatedTerms',case when jsonb_typeof(diagnosis->'related_terms')='array' then diagnosis->'related_terms' else '[]'::jsonb end,
    'requiresTransfer',coalesce((diagnosis->>'requires_transfer')::boolean,false),
    'changedTargeted',changed_targeted,'createdConfusion',created_confusion,
    'contentAction',nullif(diagnosis->>'content_action','none'),
    'contentProposalId',nullif(diagnosis->>'content_proposal_id',''),
    'contentStatus',coalesce(content_status,nullif(diagnosis->>'content_status','')),
    'contentFeedbackReason',content_feedback_reason,
    'contentOriginal',content_original,'contentRevised',content_revised,'contentQualityNote',content_quality_note,
    'createdAt',created_at,'processedAt',processed_at
  )) order by created_at desc),'[]'::jsonb) into v_context from recent;

  with recent as (
    select p.*,
           coalesce(nullif(btrim(q.word),''),nullif(btrim(c.name),''),nullif(left(btrim(q.question),96),''),'English question') display_name,
           coalesce(nullif(btrim(q.topic),''),'English') topic,
           exists(select 1 from english.user_question_revisions u where u.user_id=uid and u.question_id=p.question_id and u.proposal_id=p.proposal_id) is_active
    from english.question_revision_proposals p
    left join english.questions q on q.question_id=p.question_id
    left join english.question_concept_mappings m on m.question_id=p.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    where p.user_id=uid order by p.created_at desc limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'kind','revision','proposalId',proposal_id,'questionId',question_id,'displayName',display_name,'topic',topic,
    'version',proposal_version,'feedbackReason',feedback_reason,'feedbackNote',nullif(left(coalesce(feedback_note,''),700),''),
    'status',status,'original',base_payload,'revised',case when status in ('ready','applied','kept') then proposed_payload else null end,
    'qualityNote',case when status in ('ready','applied','kept') then nullif(left(coalesce(critic->>'rationale',''),700),'') else null end,
    'active',is_active,'errorCode',case when status='failed' then error_code else null end,
    'createdAt',created_at,'readyAt',ready_at,'decidedAt',decided_at
  )) order by created_at desc),'[]'::jsonb) into v_revisions from recent;

  select jsonb_build_object(
    'contextTotal',(select count(*) from english.learner_context_notes where user_id=uid),
    'contextDone',(select count(*) from english.learner_context_notes where user_id=uid and (lower(coalesce(ai_status,''))='done' or lower(coalesce(processing_status,''))='done')),
    'contextPending',(select count(*) from english.learner_context_notes where user_id=uid and (lower(coalesce(ai_status,'')) in ('queued','processing') or lower(coalesce(processing_status,'')) in ('queued','processing'))),
    'contextFailed',(select count(*) from english.learner_context_notes where user_id=uid and (lower(coalesce(ai_status,''))='failed' or lower(coalesce(processing_status,''))='failed')),
    'revisionTotal',(select count(*) from english.question_revision_proposals where user_id=uid),
    'revisionReady',(select count(*) from english.question_revision_proposals where user_id=uid and status in ('ready','kept')),
    'revisionWorking',(select count(*) from english.question_revision_proposals where user_id=uid and status in ('queued','processing')),
    'revisionApplied',(select count(*) from english.question_revision_proposals where user_id=uid and status='applied'),
    'revisionFailed',(select count(*) from english.question_revision_proposals where user_id=uid and status='failed')
  ) into v_summary;

  return jsonb_build_object('ok',true,'summary',v_summary,'contextUpdates',v_context,'revisionUpdates',v_revisions);
end
$function$;

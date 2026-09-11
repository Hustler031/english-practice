-- Route explicit Add Context content-improvement requests independently from learner-state diagnosis.
-- Content requests use the existing explanation-only revision/critic pipeline and auto-apply only
-- because the learner explicitly asked for that content change. Learning state remains independent.

create or replace function english.context_content_action_from_note(p_note text)
returns text
language plpgsql
immutable
set search_path to 'pg_catalog','english'
as $$
declare
  s text:=lower(regexp_replace(trim(coalesce(p_note,'')),'[[:space:]]+',' ','g'));
begin
  if s='' then return 'none'; end if;

  if s ~ '(add|give|include|write|explain|provide).*(explanation|meaning).*(all|every).*(option|choice|word)'
     or s ~ '(all|every).*(option|choice|word).*(explain|explanation|meaning)'
     or s ~ 'explain.*(all|every).*(option|choice|word)'
     or s ~ 'add explanation.*(option|choice|word)' then
    return 'explain_all_options';
  end if;

  if s ~ '(enrich|improve|expand|enhance|rewrite|strengthen|detail|detailed|better|add).*(the )?explanation'
     or s ~ '(the )?explanation.*(weak|poor|short|brief|incomplete|better|detail|detailed|improve|expand|enrich)'
     or s ~ '(give|provide|need|want).*(better|detailed|richer|more detailed).*(explanation)' then
    return 'enrich_explanation';
  end if;

  return 'none';
end $$;
revoke all on function english.context_content_action_from_note(text) from public,anon,authenticated;
grant execute on function english.context_content_action_from_note(text) to service_role;

create or replace function english.queue_context_content_action_internal(
  p_note_id uuid,
  p_content_action text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $$
declare
  n english.learner_context_notes%rowtype;
  q english.questions%rowtype;
  v_action text:=lower(trim(coalesce(p_content_action,'')));
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

  if v_action not in ('enrich_explanation','explain_all_options') then
    return jsonb_build_object('ok',true,'queued',false,'contentAction','none');
  end if;

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

  -- Do not let a delayed/backfilled context note supersede a newer explicit revision decision.
  if exists(
    select 1 from english.question_revision_proposals p
    where p.user_id=n.user_id and p.question_id=n.question_id
      and p.created_at>n.created_at
      and p.status<>'superseded'
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
    raise exception 'question is not eligible for explanation revision';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(n.user_id::text||'|'||n.question_id,0));

  select r.proposal_version,p.proposed_payload into v_base_version,v_base
  from english.user_question_revisions r
  join english.question_revision_proposals p on p.proposal_id=r.proposal_id
  where r.user_id=n.user_id and r.question_id=n.question_id;

  if v_base is null then
    v_base:=jsonb_build_object(
      'question',q.question,
      'optionA',q.option_a,'optionB',q.option_b,'optionC',q.option_c,'optionD',q.option_d,
      'correctKey',upper(q.correct),'explanation',coalesce(q.explanation,''),
      'questionType',coalesce(q.question_type,''),'difficulty',coalesce(q.difficulty,''),'word',coalesce(q.word,'')
    );
    v_base_version:=0;
  end if;

  update english.question_revision_proposals
  set status='superseded',superseded_at=now(),updated_at=now()
  where user_id=n.user_id and question_id=n.question_id and status in ('queued','processing','ready');

  select coalesce(max(proposal_version),0)+1 into v_version
  from english.question_revision_proposals
  where user_id=n.user_id and question_id=n.question_id;

  insert into english.question_revision_proposals(
    user_id,question_id,proposal_version,base_version,feedback_reason,feedback_note,
    status,base_payload,next_attempt_at,idempotency_key
  ) values(
    n.user_id,n.question_id,v_version,v_base_version,'explanation_weak',left(n.note,600),
    'queued',v_base,now(),v_key
  ) returning proposal_id into v_id;

  update english.learner_context_notes
  set diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object(
    'content_action',v_action,
    'content_proposal_id',v_id::text,
    'content_requested_at',now())
  where note_id=n.note_id;

  begin perform english.kick_revision_worker(1); exception when others then null; end;

  return jsonb_build_object('ok',true,'queued',true,'contentAction',v_action,'proposalId',v_id,'status','queued');
end $$;
revoke all on function english.queue_context_content_action_internal(uuid,text) from public,anon,authenticated;
grant execute on function english.queue_context_content_action_internal(uuid,text) to service_role;

create or replace function public.english_queue_context_content_action(
  p_token text,
  p_note_id uuid,
  p_content_action text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  return english.queue_context_content_action_internal(p_note_id,p_content_action);
end $$;
revoke all on function public.english_queue_context_content_action(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_queue_context_content_action(text,uuid,text) to service_role;

-- Compatibility safety net for already-deployed workers that classify content-only notes as no_action.
create or replace function english.context_content_action_autoroute_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare v_action text;
begin
  if new.ai_status='done' and old.ai_status is distinct from 'done'
     and nullif(new.diagnosis->>'content_proposal_id','') is null then
    v_action:=english.context_content_action_from_note(new.note);
    if v_action<>'none' then
      perform english.queue_context_content_action_internal(new.note_id,v_action);
    end if;
  end if;
  return new;
end $$;
revoke all on function english.context_content_action_autoroute_trigger() from public,anon,authenticated;

drop trigger if exists zz_english_context_content_action_autoroute on english.learner_context_notes;
create trigger zz_english_context_content_action_autoroute
after update of ai_status,diagnosis on english.learner_context_notes
for each row execute function english.context_content_action_autoroute_trigger();

-- A context content command is itself explicit permission to use the critic-approved explanation.
-- Only context-linked proposals auto-apply. Normal Improve Question proposals still require preview/use.
create or replace function english.context_revision_auto_apply_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare v_note_id uuid;
begin
  if new.status='ready' and old.status is distinct from 'ready' and new.proposed_payload is not null then
    select n.note_id into v_note_id
    from english.learner_context_notes n
    where n.user_id=new.user_id
      and n.question_id=new.question_id
      and n.diagnosis->>'content_proposal_id'=new.proposal_id::text
      and coalesce(n.diagnosis->>'content_action','none') in ('enrich_explanation','explain_all_options')
    order by n.created_at desc
    limit 1;

    if v_note_id is not null then
      insert into english.user_question_revisions(user_id,question_id,proposal_id,proposal_version,applied_at)
      values(new.user_id,new.question_id,new.proposal_id,new.proposal_version,now())
      on conflict(user_id,question_id) do update
        set proposal_id=excluded.proposal_id,proposal_version=excluded.proposal_version,applied_at=now();

      update english.question_revision_proposals
      set status='applied',decided_at=now(),updated_at=now()
      where proposal_id=new.proposal_id and status='ready';

      update english.learner_context_notes
      set diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object(
        'content_status','applied','content_applied_at',now())
      where note_id=v_note_id;
    end if;
  end if;
  return new;
end $$;
revoke all on function english.context_revision_auto_apply_trigger() from public,anon,authenticated;

drop trigger if exists zz_english_context_revision_auto_apply on english.question_revision_proposals;
create trigger zz_english_context_revision_auto_apply
after update of status on english.question_revision_proposals
for each row execute function english.context_revision_auto_apply_trigger();

create or replace function public.english_get_learning_ai_updates(p_limit integer default 30)
returns jsonb
language plpgsql
stable
security definer
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
           exists(
             select 1 from english.learning_route_state r
             where r.user_id=uid and r.question_id=n.question_id and r.route='targeted'
               and ('Learner Context'=any(coalesce(r.origins,'{}'::text[])) or 'Learner Context Related'=any(coalesce(r.origins,'{}'::text[])))
           ) changed_targeted,
           cp.status content_status
    from english.learner_context_notes n
    left join english.questions q on q.question_id=n.question_id
    left join english.question_concept_mappings m on m.question_id=n.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    left join english.question_revision_proposals cp
      on cp.user_id=n.user_id
     and cp.proposal_id=case
       when coalesce(n.diagnosis->>'content_proposal_id','') ~ '^[0-9a-fA-F-]{36}$' then (n.diagnosis->>'content_proposal_id')::uuid
       else null end
    where n.user_id=uid
    order by n.created_at desc
    limit v_limit
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

revoke execute on function public.english_get_learning_ai_updates(integer) from public,anon;
grant execute on function public.english_get_learning_ai_updates(integer) to authenticated,service_role;

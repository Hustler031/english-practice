-- Learner-facing Learning Insights feed.
-- This intentionally exposes AI outcomes, not internal concept/debug machinery.
-- Every row is owner-scoped through auth.uid(); question IDs are transport keys only
-- and the UI renders learner-facing names.

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
           exists(
             select 1 from english.learner_confusions cf
             where cf.user_id=uid and cf.source_note_id=n.note_id
           ) created_confusion,
           exists(
             select 1 from english.learning_route_state r
             where r.user_id=uid and r.question_id=n.question_id and r.route='targeted'
               and (
                 'Learner Context'=any(coalesce(r.origins,'{}'::text[]))
                 or 'Learner Context Related'=any(coalesce(r.origins,'{}'::text[]))
               )
           ) changed_targeted
    from english.learner_context_notes n
    left join english.questions q on q.question_id=n.question_id
    left join english.question_concept_mappings m on m.question_id=n.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    where n.user_id=uid
    order by n.created_at desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'kind','context',
    'noteId',note_id,
    'questionId',question_id,
    'displayName',display_name,
    'topic',topic,
    'learnerNote',left(coalesce(note,''),700),
    'status',case
      when lower(coalesce(ai_status,''))='done' or lower(coalesce(processing_status,''))='done' then 'done'
      when lower(coalesce(ai_status,'')) in ('queued','processing') then lower(ai_status)
      when lower(coalesce(processing_status,'')) in ('queued','processing') then lower(processing_status)
      when lower(coalesce(ai_status,''))='failed' or lower(coalesce(processing_status,''))='failed' then 'failed'
      else coalesce(nullif(lower(ai_status),''),nullif(lower(processing_status),''),'pending') end,
    'understood',nullif(left(coalesce(diagnosis->>'rationale',''),900),''),
    'diagnosisType',nullif(diagnosis->>'type',''),
    'action',nullif(diagnosis->>'action',''),
    'urgency',nullif(diagnosis->>'urgency',''),
    'relatedTerms',case when jsonb_typeof(diagnosis->'related_terms')='array' then diagnosis->'related_terms' else '[]'::jsonb end,
    'requiresTransfer',coalesce((diagnosis->>'requires_transfer')::boolean,false),
    'changedTargeted',changed_targeted,
    'createdConfusion',created_confusion,
    'createdAt',created_at,
    'processedAt',processed_at
  )) order by created_at desc),'[]'::jsonb)
  into v_context
  from recent;

  with recent as (
    select p.*,
           coalesce(nullif(btrim(q.word),''),nullif(btrim(c.name),''),nullif(left(btrim(q.question),96),''),'English question') display_name,
           coalesce(nullif(btrim(q.topic),''),'English') topic,
           exists(
             select 1 from english.user_question_revisions u
             where u.user_id=uid and u.question_id=p.question_id and u.proposal_id=p.proposal_id
           ) is_active
    from english.question_revision_proposals p
    left join english.questions q on q.question_id=p.question_id
    left join english.question_concept_mappings m on m.question_id=p.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    where p.user_id=uid
    order by p.created_at desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'kind','revision',
    'proposalId',proposal_id,
    'questionId',question_id,
    'displayName',display_name,
    'topic',topic,
    'version',proposal_version,
    'feedbackReason',feedback_reason,
    'feedbackNote',nullif(left(coalesce(feedback_note,''),700),''),
    'status',status,
    'original',base_payload,
    'revised',case when status in ('ready','applied','kept') then proposed_payload else null end,
    'qualityNote',case when status in ('ready','applied','kept') then nullif(left(coalesce(critic->>'rationale',''),700),'') else null end,
    'active',is_active,
    'errorCode',case when status='failed' then error_code else null end,
    'createdAt',created_at,
    'readyAt',ready_at,
    'decidedAt',decided_at
  )) order by created_at desc),'[]'::jsonb)
  into v_revisions
  from recent;

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

  return jsonb_build_object(
    'ok',true,
    'summary',v_summary,
    'contextUpdates',v_context,
    'revisionUpdates',v_revisions
  );
end
$function$;

revoke execute on function public.english_get_learning_ai_updates(integer) from public,anon;
grant execute on function public.english_get_learning_ai_updates(integer) to authenticated,service_role;

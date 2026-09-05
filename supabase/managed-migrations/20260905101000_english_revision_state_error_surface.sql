-- Learner-facing revision state exposes typed operational classification separately
-- from diagnostic text. The original question remains authoritative unless a proposal
-- reaches ready/applied.
create or replace function public.english_get_question_revision_state(p_question_id text,p_cache_buster bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  p english.question_revision_proposals%rowtype;
  qr english.question_quality_reviews%rowtype;
  v_active integer;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if not exists(
    select 1 from english.questions q
    where q.question_id=p_question_id and english.question_visible_to_user(uid,q.question_id)
  ) then raise exception 'question not found'; end if;

  select proposal_version into v_active
  from english.user_question_revisions
  where user_id=uid and question_id=p_question_id;

  select * into p
  from english.question_revision_proposals
  where user_id=uid and question_id=p_question_id
  order by proposal_version desc limit 1;

  select * into qr
  from english.question_quality_reviews
  where user_id=uid and question_id=p_question_id
  order by created_at desc limit 1;

  return jsonb_build_object(
    'ok',true,
    'activeVersion',v_active,
    'proposal',case when p.proposal_id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'proposalId',p.proposal_id,
      'questionId',p.question_id,
      'version',p.proposal_version,
      'baseVersion',p.base_version,
      'feedbackReason',p.feedback_reason,
      'feedbackNote',p.feedback_note,
      'status',p.status,
      'proposed',case when p.status in ('ready','applied','kept') then p.proposed_payload else null end,
      'critic',case when p.status in ('ready','applied','kept') then p.critic else null end,
      'generationSource',p.generation_source,
      'errorCode',p.error_code,
      -- Only return a bounded diagnostic when the job is terminal; queued retries expose
      -- the typed code without raw provider detail.
      'lastError',case when p.status='failed' then left(coalesce(p.last_error,''),240) else null end,
      'retryAt',case when p.status='queued' and p.next_attempt_at>now() then p.next_attempt_at else null end,
      'createdAt',p.created_at,'readyAt',p.ready_at,'decidedAt',p.decided_at
    )) end,
    'qualityReview',case when qr.review_id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'reviewId',qr.review_id,
      'status',qr.status,
      'verdict',qr.verdict,
      'rationale',case when qr.status='reviewed' then qr.critic->>'rationale' else null end,
      'confidence',case when qr.status='reviewed' then qr.critic->'confidence' else null end,
      'retryAt',case when qr.status='queued' and qr.next_attempt_at>now() then qr.next_attempt_at else null end,
      'serviceFailed',qr.status='failed',
      'createdAt',qr.created_at,'reviewedAt',qr.reviewed_at
    )) end
  );
end
$function$;
revoke all on function public.english_get_question_revision_state(text,bigint) from public,anon;
grant execute on function public.english_get_question_revision_state(text,bigint) to authenticated,service_role;

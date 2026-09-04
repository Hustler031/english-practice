-- Restore the proven context-worker runtime token source while keeping the
-- P1 fair-lane scheduler/recovery/telemetry architecture.
-- The production project stores the worker token in english.context_ai_runtime_guard;
-- no Vault secrets are required for this worker scheduler.

create or replace function english.kick_context_worker(
  p_context_limit integer default 6,
  p_transfer_limit integer default 1
) returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $$
declare
  v_token text;
  req bigint;
  has_context boolean:=false;
  has_transfer boolean:=false;
  has_revision boolean:=false;
  has_quality boolean:=false;
  prev_lane text;
  chosen_lane text;
begin
  perform english.reconcile_context_worker_http();
  -- Preserve the original bank-first transfer discovery contract.
  perform english.enqueue_missing_targeted_transfers(6);

  update english.learner_context_notes
  set ai_status='queued',ai_next_attempt_at=now(),ai_error='stale background processing recovered'
  where ai_status='processing' and ai_attempted_at<now()-interval '5 minutes' and ai_attempts<3;
  update english.learner_context_notes
  set ai_status='failed',ai_next_attempt_at=null,ai_error=coalesce(ai_error,'background processing retries exhausted')
  where ai_status='processing' and ai_attempted_at<now()-interval '5 minutes' and ai_attempts>=3;

  update english.targeted_transfer_jobs
  set status='queued',next_attempt_at=now(),last_error='stale generation recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts<3;
  update english.targeted_transfer_jobs
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'transfer generation retries exhausted'),updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts>=3;

  update english.question_revision_proposals
  set status='queued',next_attempt_at=now(),last_error='stale background processing recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_revision_proposals
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'background processing exhausted retries'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  update english.question_quality_reviews
  set status='queued',next_attempt_at=now(),last_error='stale review recovered',updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts<3;
  update english.question_quality_reviews
  set status='failed',next_attempt_at=null,last_error=coalesce(last_error,'review retries exhausted'),updated_at=now()
  where status='processing' and claimed_at<now()-interval '5 minutes' and attempts>=3;

  select exists(
    select 1 from english.learner_context_notes
    where processing_status='done' and ai_status='queued' and ai_attempts<3
      and (ai_next_attempt_at is null or ai_next_attempt_at<=now())
  ) into has_context;
  select exists(
    select 1 from english.targeted_transfer_jobs
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_transfer;
  select exists(
    select 1 from english.question_revision_proposals
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_revision;
  select exists(
    select 1 from english.question_quality_reviews
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into has_quality;

  select s.last_lane into prev_lane
  from english.worker_scheduler_state s
  where s.singleton=true
  for update;

  if prev_lane='transfer' then
    if has_revision then chosen_lane:='revision';
    elsif has_quality then chosen_lane:='quality_review';
    elsif has_transfer then chosen_lane:='transfer'; end if;
  elsif prev_lane='revision' then
    if has_quality then chosen_lane:='quality_review';
    elsif has_transfer then chosen_lane:='transfer';
    elsif has_revision then chosen_lane:='revision'; end if;
  elsif prev_lane='quality_review' then
    if has_transfer then chosen_lane:='transfer';
    elsif has_revision then chosen_lane:='revision';
    elsif has_quality then chosen_lane:='quality_review'; end if;
  else
    if has_transfer then chosen_lane:='transfer';
    elsif has_revision then chosen_lane:='revision';
    elsif has_quality then chosen_lane:='quality_review'; end if;
  end if;

  if not has_context and chosen_lane is null then
    update english.worker_scheduler_state
    set active_lane=null,active_until=null,updated_at=now()
    where singleton=true;
    return 0;
  end if;

  update english.worker_scheduler_state
  set last_lane=coalesce(chosen_lane,last_lane),
      active_lane=coalesce(chosen_lane,'none'),
      active_until=now()+interval '2 minutes',
      updated_at=now()
  where singleton=true;

  select token into v_token
  from english.context_ai_runtime_guard
  where singleton=true;
  if v_token is null then raise exception 'context runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-context-worker',
    body:=jsonb_build_object(
      'contextLimit',greatest(1,least(8,coalesce(p_context_limit,6))),
      'transferLimit',greatest(1,least(2,coalesce(p_transfer_limit,1))),
      'revisionLimit',1,
      'reviewLimit',1
    ),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=28000
  ) into req;

  insert into english.context_worker_requests(request_id,lane,requested_at)
  values(req,coalesce(chosen_lane,'context'),now())
  on conflict(request_id) do nothing;
  return req;
end $$;

revoke all on function english.kick_context_worker(integer,integer) from public,anon,authenticated;
grant execute on function english.kick_context_worker(integer,integer) to service_role;

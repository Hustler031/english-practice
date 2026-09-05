-- Stage 2 audit remediation: queued and retrying are separate operational states.
-- A queued row with a future next-attempt timestamp is retry_wait and must not also
-- inflate the runnable queued count.

create or replace function public.english_get_ai_worker_health()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','english','auth','cron'
as $function$
declare
  uid uuid:=auth.uid();
  v_semantic timestamptz;
  v_context timestamptz;
  v_revision timestamptz;
  v_semantic_status text;
  v_context_status text;
  v_revision_status text;
  v_queued integer;
  v_processing integer;
  v_retry integer;
  v_failed integer;
  v_oldest timestamptz;
begin
  if uid is null then raise exception 'authentication required'; end if;

  select r.start_time,r.status into v_semantic,v_semantic_status
  from cron.job_run_details r join cron.job j on j.jobid=r.jobid
  where j.jobname='english-semantic-refinement' order by r.start_time desc limit 1;
  select r.start_time,r.status into v_context,v_context_status
  from cron.job_run_details r join cron.job j on j.jobid=r.jobid
  where j.jobname='english-context-intelligence' order by r.start_time desc limit 1;
  select r.start_time,r.status into v_revision,v_revision_status
  from cron.job_run_details r join cron.job j on j.jobid=r.jobid
  where j.jobname='english-question-revision' order by r.start_time desc limit 1;

  select count(*)::int into v_queued from (
    select created_at from english.semantic_queue
      where status='queued' and (next_attempt_at is null or next_attempt_at<=now())
    union all select created_at from english.learner_context_notes
      where user_id=uid and ai_status in ('pending','queued') and (ai_next_attempt_at is null or ai_next_attempt_at<=now())
    union all select created_at from english.targeted_transfer_jobs
      where user_id=uid and status='queued' and (next_attempt_at is null or next_attempt_at<=now())
    union all select created_at from english.question_revision_proposals
      where user_id=uid and status='queued' and (next_attempt_at is null or next_attempt_at<=now())
    union all select created_at from english.question_quality_reviews
      where user_id=uid and status='queued' and (next_attempt_at is null or next_attempt_at<=now())
  ) q;

  select count(*)::int into v_processing from (
    select created_at from english.semantic_queue where status='processing'
    union all select created_at from english.learner_context_notes where user_id=uid and ai_status='processing'
    union all select created_at from english.targeted_transfer_jobs where user_id=uid and status='processing'
    union all select created_at from english.question_revision_proposals where user_id=uid and status='processing'
    union all select created_at from english.question_quality_reviews where user_id=uid and status='processing'
  ) q;

  select count(*)::int into v_retry from (
    select created_at from english.semantic_queue where status='queued' and next_attempt_at>now()
    union all select created_at from english.learner_context_notes where user_id=uid and ai_status in ('pending','queued') and ai_next_attempt_at>now()
    union all select created_at from english.targeted_transfer_jobs where user_id=uid and status='queued' and next_attempt_at>now()
    union all select created_at from english.question_revision_proposals where user_id=uid and status='queued' and next_attempt_at>now()
    union all select created_at from english.question_quality_reviews where user_id=uid and status='queued' and next_attempt_at>now()
  ) q;

  select count(*)::int into v_failed from (
    select updated_at t from english.semantic_queue where status='failed' and updated_at>=now()-interval '7 days'
    union all select coalesce(processed_at,created_at) from english.learner_context_notes where user_id=uid and ai_status='failed' and coalesce(processed_at,created_at)>=now()-interval '7 days'
    union all select updated_at from english.targeted_transfer_jobs where user_id=uid and status='failed' and updated_at>=now()-interval '7 days'
    union all select updated_at from english.question_revision_proposals where user_id=uid and status='failed' and updated_at>=now()-interval '7 days'
    union all select updated_at from english.question_quality_reviews where user_id=uid and status='failed' and updated_at>=now()-interval '7 days'
  ) q;

  select min(created_at) into v_oldest from (
    select created_at from english.semantic_queue where status in ('queued','processing')
    union all select created_at from english.learner_context_notes where user_id=uid and ai_status in ('pending','queued','processing')
    union all select created_at from english.targeted_transfer_jobs where user_id=uid and status in ('queued','processing')
    union all select created_at from english.question_revision_proposals where user_id=uid and status in ('queued','processing')
    union all select created_at from english.question_quality_reviews where user_id=uid and status in ('queued','processing')
  ) q;

  return jsonb_build_object(
    'workers',jsonb_build_object(
      'semantic',jsonb_build_object('healthy',v_semantic_status='succeeded' and v_semantic>=now()-interval '5 minutes','lastRun',v_semantic,'status',v_semantic_status),
      'learning',jsonb_build_object('healthy',v_context_status='succeeded' and v_context>=now()-interval '6 minutes','lastRun',v_context,'status',v_context_status),
      'quality',jsonb_build_object('healthy',v_revision_status='succeeded' and v_revision>=now()-interval '5 minutes','lastRun',v_revision,'status',v_revision_status)
    ),
    'queued',v_queued,
    'processing',v_processing,
    'retrying',v_retry,
    'failed7d',v_failed,
    'oldestPendingAt',v_oldest
  );
end
$function$;

revoke all on function public.english_get_ai_worker_health() from public,anon;
grant execute on function public.english_get_ai_worker_health() to authenticated,service_role;

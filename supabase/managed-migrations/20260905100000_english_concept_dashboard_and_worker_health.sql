-- Stage 1: expose the existing concept intelligence and scheduler health without
-- duplicating the learner model. Counts are always derived from active concepts and
-- current user evidence; operational output is aggregate-only and contains no secrets.

create or replace function english.english_get_concept_intelligence_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  v_total integer;
  v_active_questions integer;
  v_mapped integer;
  v_seen integer;
  v_weak integer;
  v_retention integer;
  v_secure integer;
  v_exam integer;
  v_unseen integer;
  v_high_unseen integer;
  v_needs_validation integer;
  v_confusions integer;
begin
  if uid is null then raise exception 'authentication required'; end if;

  select count(*)::int into v_total from english.concepts c where c.active;
  select count(*)::int into v_active_questions
  from english.questions q
  where q.active and english.question_visible_to_user(uid,q.question_id);
  select count(distinct q.question_id)::int into v_mapped
  from english.questions q
  join english.question_concept_mappings m on m.question_id=q.question_id
  join english.concepts c on c.concept_id=m.concept_id and c.active
  where q.active and english.question_visible_to_user(uid,q.question_id);

  select
    count(*) filter(where coalesce(e.coverage_state,'unseen')='seen')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='weak')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='retention_risk')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='secure')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='exam_ready')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='unseen')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='unseen' and lower(coalesce(c.exam_relevance,''))='high')::int,
    count(*) filter(where coalesce(e.coverage_state,'unseen')='seen' and coalesce(e.confidence_score,0)<60)::int
  into v_seen,v_weak,v_retention,v_secure,v_exam,v_unseen,v_high_unseen,v_needs_validation
  from english.concepts c
  left join english.concept_evidence e on e.user_id=uid and e.concept_id=c.concept_id
  where c.active;

  select count(*)::int into v_confusions
  from english.learner_confusions lc
  where lc.user_id=uid and lc.status<>'resolved';

  return jsonb_build_object(
    'concepts',v_total,
    'active_questions',v_active_questions,
    'mapped_questions',v_mapped,
    'unmapped_questions',greatest(0,v_active_questions-v_mapped),
    'mapping_pct',case when v_active_questions=0 then 0 else round(100.0*v_mapped/v_active_questions,1) end,
    'seen',v_seen,
    'weak_only',v_weak,
    -- Preserve the historical `weak` key semantics for existing consumers.
    'weak',v_weak+v_retention,
    'retention_risk',v_retention,
    'secure',v_secure,
    'exam_ready',v_exam,
    'unseen',v_unseen,
    'covered',v_total-v_unseen,
    'coverage_pct',case when v_total=0 then 0 else round(100.0*(v_total-v_unseen)/v_total,1) end,
    'exam_ready_pct',case when v_total=0 then 0 else round(100.0*v_exam/v_total,1) end,
    'high_yield_unseen',v_high_unseen,
    'needs_validation',v_needs_validation,
    'confusions',v_confusions,
    'reconciles',((v_seen+v_weak+v_retention+v_secure+v_exam+v_unseen)=v_total)
  );
end
$function$;

create or replace function public.english_get_concept_intelligence_summary()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$ select english.english_get_concept_intelligence_summary() $$;
revoke all on function public.english_get_concept_intelligence_summary() from public,anon;
grant execute on function public.english_get_concept_intelligence_summary() to authenticated,service_role;

create or replace function english.english_get_concept_intelligence_detail(p_kind text default 'all')
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with uid as (select auth.uid() id), rows as (
  select
    c.concept_id,
    c.domain,
    c.skill_family,
    c.name,
    c.exam_relevance,
    c.priority_score,
    coalesce(e.coverage_state,'unseen') coverage_state,
    coalesce(e.confidence_score,0) confidence_score,
    coalesce(e.attempts,0) attempts,
    coalesce(e.wrong,0) wrong,
    e.next_review,
    qpick.question_id
  from english.concepts c
  cross join uid
  left join english.concept_evidence e on e.concept_id=c.concept_id and e.user_id=uid.id
  left join lateral (
    select q.question_id
    from english.question_concept_mappings m
    join english.questions q on q.question_id=m.question_id and q.active
    where m.concept_id=c.concept_id and english.question_visible_to_user(uid.id,q.question_id)
    order by case when exists(select 1 from english.question_state s where s.user_id=uid.id and s.question_id=q.question_id and not s.mastered) then 0 else 1 end,
             q.question_id
    limit 1
  ) qpick on true
  where uid.id is not null and c.active
), filtered as (
  select * from rows
  where p_kind in ('all','coverage')
     or (p_kind='weak' and coverage_state='weak')
     or (p_kind in ('retention','retention_risk') and coverage_state='retention_risk')
     or (p_kind='secure' and coverage_state='secure')
     or (p_kind='exam_ready' and coverage_state='exam_ready')
     or (p_kind='seen' and coverage_state='seen')
     or (p_kind='needs_validation' and coverage_state='seen' and confidence_score<60)
     or (p_kind='unseen' and coverage_state='unseen')
     or (p_kind='high_yield_unseen' and coverage_state='unseen' and lower(coalesce(exam_relevance,''))='high')
)
select coalesce(jsonb_agg(to_jsonb(f) order by
  case f.coverage_state when 'weak' then 1 when 'retention_risk' then 2 when 'seen' then 3 when 'unseen' then 4 when 'secure' then 5 else 6 end,
  coalesce(f.priority_score,0) desc,f.confidence_score asc,f.name),'[]'::jsonb)
from filtered f;
$function$;

create or replace function public.english_get_concept_intelligence_detail(p_kind text default 'all')
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$ select english.english_get_concept_intelligence_detail(p_kind) $$;
revoke all on function public.english_get_concept_intelligence_detail(text) from public,anon;
grant execute on function public.english_get_concept_intelligence_detail(text) to authenticated,service_role;

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
    select created_at from english.semantic_queue where status='queued'
    union all select created_at from english.learner_context_notes where user_id=uid and ai_status in ('pending','queued')
    union all select created_at from english.targeted_transfer_jobs where user_id=uid and status='queued'
    union all select created_at from english.question_revision_proposals where user_id=uid and status='queued'
    union all select created_at from english.question_quality_reviews where user_id=uid and status='queued'
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

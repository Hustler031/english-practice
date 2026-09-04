-- Fix Targeted transfer generation lease churn.
-- Existing processing jobs must keep their claim timestamp stable so the
-- 5-minute stale-recovery window can actually expire. Recovery runs before
-- bank-first discovery re-touches an existing job.

create or replace function english.ensure_transfer_generation_job(
  p_user_id uuid,
  p_concept_id text,
  p_source_question_id text,
  p_source_note_id uuid default null,
  p_related_term text default null,
  p_reason text default 'missing_transfer'
) returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare v_job uuid;
begin
  if p_user_id is null or p_concept_id is null or p_source_question_id is null then return null; end if;

  if exists(
    select 1
    from english.questions q
    join english.question_concept_mappings m on m.question_id=q.question_id
    where q.active
      and m.concept_id=p_concept_id
      and q.question_id<>p_source_question_id
      and english.question_visible_to_user(p_user_id,q.question_id)
  ) then return null; end if;

  insert into english.targeted_transfer_jobs(
    user_id,concept_id,source_question_id,source_note_id,related_term,reason,status,metadata
  ) values(
    p_user_id,p_concept_id,p_source_question_id,p_source_note_id,
    nullif(trim(coalesce(p_related_term,'')),''),
    left(coalesce(nullif(trim(p_reason),''),'missing_transfer'),240),
    'queued',jsonb_build_object('bankFirstCheckedAt',now())
  )
  on conflict(user_id,concept_id,source_question_id) do update set
    source_note_id=coalesce(excluded.source_note_id,english.targeted_transfer_jobs.source_note_id),
    related_term=coalesce(excluded.related_term,english.targeted_transfer_jobs.related_term),
    reason=excluded.reason,
    status=case
      when english.targeted_transfer_jobs.status='failed'
       and english.targeted_transfer_jobs.attempts<3 then 'queued'
      else english.targeted_transfer_jobs.status
    end,
    next_attempt_at=case
      when english.targeted_transfer_jobs.status='failed'
       and english.targeted_transfer_jobs.attempts<3 then now()
      else english.targeted_transfer_jobs.next_attempt_at
    end,
    -- A processing row's updated_at is its lease timestamp. Never renew that
    -- lease merely because the discovery cron encounters the same job again.
    updated_at=case
      when english.targeted_transfer_jobs.status='processing'
        then english.targeted_transfer_jobs.updated_at
      when english.targeted_transfer_jobs.status='failed'
       and english.targeted_transfer_jobs.attempts<3
        then now()
      else english.targeted_transfer_jobs.updated_at
    end
  returning job_id into v_job;

  return v_job;
end $$;

revoke all on function english.ensure_transfer_generation_job(uuid,text,text,uuid,text,text)
  from public,anon,authenticated;
grant execute on function english.ensure_transfer_generation_job(uuid,text,text,uuid,text,text)
  to service_role;

create or replace function english.enqueue_missing_targeted_transfers(p_limit integer default 8)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  r record;
  n integer:=0;
  j uuid;
begin
  -- Recover/terminate expired leases before discovery can encounter the same
  -- logical job. This makes stale recovery independent of cron frequency.
  update english.targeted_transfer_jobs
  set status='queued',
      next_attempt_at=now(),
      last_error='stale generation recovered',
      updated_at=now()
  where status='processing'
    and updated_at<now()-interval '5 minutes'
    and attempts<3;

  update english.targeted_transfer_jobs
  set status='failed',
      next_attempt_at=null,
      last_error=coalesce(last_error,'transfer generation retries exhausted'),
      updated_at=now()
  where status='processing'
    and updated_at<now()-interval '5 minutes'
    and attempts>=3;

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
        select 1
        from english.questions q2
        join english.question_concept_mappings m2 on m2.question_id=q2.question_id
        where q2.active
          and m2.concept_id=m.concept_id
          and q2.question_id<>lr.question_id
          and english.question_visible_to_user(lr.user_id,q2.question_id)
      )
    order by case coalesce(lr.metadata->>'targeted_kind','')
      when 'confusion' then 1 else 2 end,lr.updated_at desc
    limit greatest(1,least(12,coalesce(p_limit,8)))
  loop
    j:=english.ensure_transfer_generation_job(
      r.user_id,r.concept_id,r.question_id,r.source_note_id,null,r.reason
    );
    if j is not null then n:=n+1; end if;
  end loop;

  return n;
end $$;

revoke all on function english.enqueue_missing_targeted_transfers(integer)
  from public,anon,authenticated;
grant execute on function english.enqueue_missing_targeted_transfers(integer)
  to service_role;

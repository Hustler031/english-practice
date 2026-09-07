-- Make Daily rollover independent of a single browser bootstrap call.
-- The canonical rule remains unchanged: an unfinished previous batch is never skipped.

create or replace function english.ensure_daily(p_user_id uuid, p_target integer default 120)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch date;
  v_pending integer:=0;
  v_effective integer:=0;
  v_created integer:=0;
  v_archived integer:=0;
  v_next date;
  c record;
begin
  -- Browser bootstrap, focus retry, heartbeat and the backend safety-net may all
  -- arrive together. Serialize per learner so archive/create remains exactly-once.
  perform pg_advisory_xact_lock(hashtext('english.ensure_daily'), hashtext(p_user_id::text));

  select min(quiz_date) into v_batch from english.daily_current where user_id=p_user_id;
  if v_batch is null then
    v_batch:=v_today;
    v_created:=english.create_daily(p_user_id,v_batch,p_target);
  else
    select total,remaining into v_effective,v_pending from english.daily_effective_counts(p_user_id,v_batch,p_target);
    v_effective:=coalesce(v_effective,0);
    v_pending:=coalesce(v_pending,0);
    if v_batch<v_today and v_pending=0 then
      v_archived:=english.archive_daily(p_user_id,v_batch);
      v_next:=v_batch+1;
      v_batch:=v_next;
      v_created:=english.create_daily(p_user_id,v_batch,p_target);
    elsif v_batch=v_today and v_effective<greatest(1,least(120,coalesce(p_target,120))) then
      v_created:=english.repair_daily_shortfall(p_user_id,v_batch,p_target);
    end if;
  end if;

  select * into c from english.daily_effective_counts(p_user_id,v_batch,p_target);
  return jsonb_build_object(
    'ok',true,'batch_date',v_batch,'today',v_today,'pending_previous_day',(v_batch<v_today),
    'created',v_created,'archived',v_archived,'target_is_maximum',true,'target_guaranteed_when_eligible',true,
    'total',coalesce(c.total,0),'completed',coalesce(c.completed,0),
    'satisfied_elsewhere',coalesce(c.satisfied_elsewhere,0),
    'done',coalesce(c.completed,0)+coalesce(c.satisfied_elsewhere,0),
    'remaining',coalesce(c.remaining,0),'raw_planned',coalesce(c.raw_planned,0)
  );
end
$function$;

create or replace function english.rollover_ready_daily_users()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  r record;
  v_before date;
  v_after date;
  v_result jsonb;
  v_checked integer:=0;
  v_advanced integer:=0;
begin
  -- Only users who already own a Daily batch are candidates. Calling ensure_daily
  -- is safe for unfinished batches: it reports pending_previous_day and leaves them
  -- untouched. Effectively-complete batches (completed + satisfied elsewhere) advance.
  for r in
    select distinct user_id
    from english.daily_current
  loop
    select min(quiz_date) into v_before
    from english.daily_current
    where user_id=r.user_id;

    if v_before is not null and v_before < v_today then
      v_checked:=v_checked+1;
      v_result:=english.ensure_daily(r.user_id,120);
      v_after:=nullif(v_result->>'batch_date','')::date;
      if v_after is not null and v_after>v_before then
        v_advanced:=v_advanced+1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok',true,
    'today',v_today,
    'checked',v_checked,
    'advanced',v_advanced
  );
end
$function$;

revoke all on function english.rollover_ready_daily_users() from public;
revoke all on function english.rollover_ready_daily_users() from anon;
revoke all on function english.rollover_ready_daily_users() from authenticated;
grant execute on function english.rollover_ready_daily_users() to service_role;

-- Hourly safety net. The normal browser rollover remains fast-path; this exists so a
-- missed auth/bootstrap event cannot leave a completed old batch stuck all morning.
do $do$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='english-daily-rollover-safety-net';

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'english-daily-rollover-safety-net',
    '17 * * * *',
    'select english.rollover_ready_daily_users();'
  );
end
$do$;

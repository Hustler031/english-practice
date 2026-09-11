-- One locked midnight orchestrator. Cron activation is intentionally deferred until Daily Mix v2 is installed.

create table if not exists english.daily_build_runs(
  user_id uuid not null,
  batch_date date not null,
  build_version text not null default 'central-v1',
  status text not null default 'building' check(status in ('building','completed','failed')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  details jsonb not null default '{}'::jsonb,
  primary key(user_id,batch_date)
);

alter table english.daily_build_runs enable row level security;
revoke all on english.daily_build_runs from public,anon,authenticated;

create or replace function english.run_midnight_build_for_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_daily_batch date;
  v_daily_remaining integer:=0;
  v_focus jsonb;
  v_daily jsonb;
  v_review jsonb;
  v_review_due integer:=0;
  v_review_carry integer:=0;
  v_focus_batch date;
  v_focus_version text;
  v_result jsonb;
begin
  if p_user_id is null then raise exception 'user is required'; end if;

  perform pg_advisory_xact_lock(
    hashtext('english.midnight_build'),
    hashtext(p_user_id::text||':'||v_today::text)
  );

  insert into english.daily_build_runs(user_id,batch_date,build_version,status,started_at,completed_at,details)
  values(p_user_id,v_today,'central-v1','building',now(),null,'{}'::jsonb)
  on conflict(user_id,batch_date) do update
    set status=case when english.daily_build_runs.status='completed' then 'completed' else 'building' end,
        started_at=case when english.daily_build_runs.status='completed' then english.daily_build_runs.started_at else now() end;

  if exists(
    select 1 from english.daily_build_runs
    where user_id=p_user_id and batch_date=v_today and status='completed'
  ) then
    select details into v_result from english.daily_build_runs
    where user_id=p_user_id and batch_date=v_today;
    return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('ok',true,'unchanged',true,'date',v_today);
  end if;

  -- Close any deferrable evidence from yesterday before today is snapshotted.
  if exists(
    select 1 from english.review_due_day_runs
    where user_id=p_user_id and due_date=v_today-1
  ) then
    perform english.reconcile_review_due_deferrals(p_user_id,v_today-1);
  end if;

  -- Scheduler first: today's exact due plus unresolved carryover.
  v_review:=english.capture_review_due_day(p_user_id,v_today);

  -- If yesterday's Daily Mix is fully complete, archive it WITHOUT creating the new mix yet.
  -- This lets Daily Focus claim learning-work concepts before the performance sampler runs.
  select min(quiz_date) into v_daily_batch
  from english.daily_current
  where user_id=p_user_id;

  if v_daily_batch is not null and v_daily_batch<v_today then
    select remaining into v_daily_remaining
    from english.daily_effective_counts(p_user_id,v_daily_batch,120);
    if coalesce(v_daily_remaining,0)=0 then
      perform english.archive_daily(p_user_id,v_daily_batch);
      v_daily_batch:=null;
    end if;
  end if;

  -- Learning mission next. Existing incomplete carryover remains authoritative.
  v_focus:=english.ensure_daily_focus(p_user_id);

  -- Performance practice last. Existing incomplete Daily Mix remains authoritative.
  v_daily:=english.ensure_daily(p_user_id,120);

  perform english.reconcile_daily_focus(p_user_id,(v_focus->>'batchDate')::date);

  select count(*),count(*) filter(where origin_due_date<v_today)
    into v_review_due,v_review_carry
  from english.review_due_obligations
  where user_id=p_user_id and due_date=v_today;

  select batch_date into v_focus_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc limit 1;

  select case when exists(
      select 1 from english.daily_focus_items
      where user_id=p_user_id and batch_date=v_focus_batch and lane='repair'
        and selection_snapshot->>'source'='learning_need_engine'
        and selection_snapshot->>'buildVersion'='v3'
    ) then 'v3' else 'legacy' end
  into v_focus_version;

  v_result:=jsonb_build_object(
    'ok',true,'unchanged',false,'date',v_today,'buildVersion','central-v1',
    'reviewDue',jsonb_build_object('concepts',v_review_due,'carryover',v_review_carry),
    'focus',v_focus||jsonb_build_object('selectionVersion',v_focus_version),
    'daily',v_daily
  );

  update english.daily_build_runs
  set status='completed',completed_at=now(),details=v_result
  where user_id=p_user_id and batch_date=v_today;

  return v_result;
exception when others then
  -- The surrounding caller transaction/subtransaction owns rollback. Re-raise so a partial day is never published.
  raise;
end;
$function$;

create or replace function english.run_midnight_build_all_users()
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  r record;
  v_result jsonb;
  v_ok integer:=0;
  v_failed integer:=0;
  v_errors jsonb:='[]'::jsonb;
begin
  for r in
    select distinct user_id from (
      select user_id from english.question_state where coalesce(attempts,0)>0
      union
      select user_id from english.daily_current
      union
      select user_id from english.daily_focus_batches
    ) u
  loop
    begin
      v_result:=english.run_midnight_build_for_user(r.user_id);
      v_ok:=v_ok+1;
    exception when others then
      v_failed:=v_failed+1;
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'userId',r.user_id,'error',left(sqlerrm,240)
      ));
    end;
  end loop;

  return jsonb_build_object(
    'ok',(v_failed=0),'date',(now() at time zone 'Asia/Kolkata')::date,
    'completed',v_ok,'failed',v_failed,'errors',v_errors
  );
end;
$function$;

revoke all on function english.run_midnight_build_for_user(uuid) from public,anon,authenticated;
revoke all on function english.run_midnight_build_all_users() from public,anon,authenticated;

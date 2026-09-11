-- Daily Focus rollover timeout hardening.
--
-- The first request of a new IST day must not be responsible for a ~12s batch build.
-- Keep the existing 50 Repair + 70 Coverage + 50 Fast Track selection semantics,
-- but (1) avoid re-running Coverage v2 once the batch is already v2 and
-- (2) pre-create a new day's batch from pg_cron after the previous batch is complete.

create or replace function english.ensure_daily_focus(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_batch english.daily_focus_batches%rowtype;
  v_legacy_familiar integer:=0;
  v_new_canonical integer:=0;
begin
  if p_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('english.ensure_daily_focus'),
    hashtext(p_user_id::text)
  );

  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc
  limit 1;

  if not found then
    perform english.create_daily_focus(p_user_id,v_today);
  else
    perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
    select * into v_batch
    from english.daily_focus_batches
    where user_id=p_user_id and batch_date=v_batch.batch_date;

    if v_batch.status='completed' and v_batch.batch_date<v_today then
      perform english.create_daily_focus(p_user_id,v_today);
    end if;
  end if;

  select * into v_batch
  from english.daily_focus_batches
  where user_id=p_user_id
  order by batch_date desc
  limit 1;

  -- Coverage v2 is a one-time normalization for a newly-created legacy 50-item
  -- coverage lane. Once there are 50 v2 new-canonical items and no legacy
  -- familiar rows, re-running the rebalance only burns ~2s and can reshuffle a
  -- not-yet-started lane. Keep the frozen batch frozen instead.
  select
    count(*) filter(where selection_snapshot->>'coverageKind'='familiar'),
    count(*) filter(where selection_snapshot->>'coverageKind'='new')
  into v_legacy_familiar,v_new_canonical
  from english.daily_focus_items
  where user_id=p_user_id
    and batch_date=v_batch.batch_date
    and lane='coverage';

  if coalesce(v_legacy_familiar,0)>0 or coalesce(v_new_canonical,0)<50 then
    perform english.rebalance_daily_focus_coverage_v2(p_user_id,v_batch.batch_date);
  end if;

  perform english.reconcile_daily_focus(p_user_id,v_batch.batch_date);
  return english.daily_focus_summary(p_user_id);
end;
$function$;

create or replace function english.rollover_ready_daily_focus_users()
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','english','auth','public'
as $function$
declare
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
  v_user uuid;
  v_checked integer:=0;
  v_created integer:=0;
  v_failed integer:=0;
  v_errors jsonb:='[]'::jsonb;
begin
  -- Only users whose latest frozen mission is complete are eligible. An active
  -- carry-over batch remains authoritative and a fresh batch is never unlocked.
  for v_user in
    with latest as (
      select distinct on (b.user_id)
             b.user_id,b.batch_date,b.status
      from english.daily_focus_batches b
      order by b.user_id,b.batch_date desc
    )
    select l.user_id
    from latest l
    where l.status='completed'
      and l.batch_date<v_today
      and not exists(
        select 1
        from english.daily_focus_batches t
        where t.user_id=l.user_id and t.batch_date=v_today
      )
  loop
    v_checked:=v_checked+1;
    begin
      perform english.ensure_daily_focus(v_user);
      if exists(
        select 1 from english.daily_focus_batches
        where user_id=v_user and batch_date=v_today
      ) then
        v_created:=v_created+1;
      end if;
    exception when others then
      v_failed:=v_failed+1;
      v_errors:=v_errors || jsonb_build_array(jsonb_build_object(
        'userId',v_user,
        'error',left(sqlerrm,240)
      ));
    end;
  end loop;

  return jsonb_build_object(
    'ok',(v_failed=0),
    'today',v_today,
    'checked',v_checked,
    'created',v_created,
    'failed',v_failed,
    'errors',v_errors
  );
end;
$function$;

revoke all on function english.rollover_ready_daily_focus_users() from public,anon,authenticated;

-- Every ten minutes is intentionally cheap: when there is no eligible rollover,
-- the function performs one indexed latest-batch scan and exits. At midnight IST
-- (18:30 UTC) it pre-builds the next frozen mission before the learner opens it.
select cron.schedule(
  'english-daily-focus-rollover-safety-net',
  '*/10 * * * *',
  'select english.rollover_ready_daily_focus_users();'
);

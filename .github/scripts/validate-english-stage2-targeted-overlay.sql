\set ON_ERROR_STOP on

-- Reuse the full Stage-1 Daily harness, then apply the Stage-2 override and verify
-- that already-selected Targeted-route concepts satisfy the bounded overlay budget.
\ir validate-english-daily-120.sql
\ir ../../supabase/managed-migrations/20260905110000_english_daily_targeted_overlay_budget.sql

select pg_temp.reset_daily_fixture(200,1,'Weak',100);

do $$
declare
  n integer;
  targeted_before integer;
  targeted_after integer;
  target_signal_n integer;
  bad_reason integer;
begin
  n:=english.create_daily_core_20260905(
    '00000000-0000-0000-0000-000000000001',
    ((now() at time zone 'Asia/Kolkata')::date),120
  );
  if n<>120 then raise exception 'base Daily core underfilled before overlay: %',n; end if;

  select count(*) into targeted_before
  from english.daily_current d
  join english.learning_route_state r
    on r.user_id=d.user_id and r.question_id=d.question_id and r.route='targeted'
  where d.user_id='00000000-0000-0000-0000-000000000001';

  -- With 120 selected from a 200-question pool containing only 100 non-targeted rows,
  -- at least 20 Targeted-route concepts must already be present before rebalancing.
  if targeted_before<20 then
    raise exception 'fixture did not guarantee natural Targeted coverage: %',targeted_before;
  end if;

  perform english.rebalance_daily_targeted(
    '00000000-0000-0000-0000-000000000001',
    ((now() at time zone 'Asia/Kolkata')::date),120
  );

  select count(*) into targeted_after
  from english.daily_current d
  join english.learning_route_state r
    on r.user_id=d.user_id and r.question_id=d.question_id and r.route='targeted'
  where d.user_id='00000000-0000-0000-0000-000000000001';

  select count(*) into target_signal_n
  from english.daily_current
  where user_id='00000000-0000-0000-0000-000000000001'
    and coalesce(selection_signals,'{}'::text[]) @> array['TARGET']::text[];

  select count(*) into bad_reason
  from english.daily_current where reason='Targeted Repair';

  if targeted_after<>targeted_before then
    raise exception 'Targeted overlay added extra route concepts despite natural budget satisfaction: before %, after %',targeted_before,targeted_after;
  end if;
  if target_signal_n<>12 then
    raise exception 'Expected exactly 12 bounded TARGET telemetry signals at target 120, got %',target_signal_n;
  end if;
  if bad_reason<>0 then
    raise exception 'Targeted overlay replaced the base Daily reason';
  end if;
  if (select count(*) from english.daily_current where user_id='00000000-0000-0000-0000-000000000001')<>120 then
    raise exception 'Targeted overlay changed Daily capacity';
  end if;
end $$;

select 'English Stage-2 Targeted overlay budget regression passed' result;

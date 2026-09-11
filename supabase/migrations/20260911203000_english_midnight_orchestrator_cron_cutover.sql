-- Activate the single midnight owner after Review Due carryover, Learning Need Engine,
-- Daily Focus v3, and Daily Mix performance-v2 are installed.
-- Legacy jobs are retained but disabled for fast rollback.

do $do$
declare
  j record;
begin
  for j in
    select jobid from cron.job
    where jobname in (
      'english-review-due-snapshot',
      'english-daily-rollover-primary'
    )
  loop
    perform cron.alter_job(j.jobid,active=>false);
  end loop;

  -- Stagger daytime catch-up jobs so Focus/learning claims concepts before Daily performance sampling.
  for j in select jobid from cron.job where jobname='english-daily-focus-rollover-safety-net'
  loop
    perform cron.alter_job(j.jobid,schedule=>'3-59/10 * * * *',active=>true);
  end loop;

  for j in select jobid from cron.job where jobname='english-daily-rollover-safety-net'
  loop
    perform cron.alter_job(j.jobid,schedule=>'7-59/10 * * * *',active=>true);
  end loop;

  -- Telemetry is deliberately moved away from exact midnight build time.
  for j in select jobid from cron.job where jobname='english-review-due-phase2-mix-ledger'
  loop
    perform cron.alter_job(j.jobid,schedule=>'2-59/5 * * * *',active=>true);
  end loop;

  if exists(select 1 from cron.job where jobname='english-central-midnight-orchestrator') then
    perform cron.unschedule('english-central-midnight-orchestrator');
  end if;
  perform cron.schedule(
    'english-central-midnight-orchestrator',
    '30 18 * * *',
    'select english.run_midnight_build_all_users();'
  );

  if exists(select 1 from cron.job where jobname='english-central-midnight-orchestrator-safety') then
    perform cron.unschedule('english-central-midnight-orchestrator-safety');
  end if;
  perform cron.schedule(
    'english-central-midnight-orchestrator-safety',
    '36 18 * * *',
    'select english.run_midnight_build_all_users();'
  );
end;
$do$;

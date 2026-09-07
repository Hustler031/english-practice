do $$
declare v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='english-daily-rollover-primary'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
end $$;

select cron.schedule(
  'english-daily-rollover-primary',
  '31 18 * * *',
  'select english.rollover_ready_daily_users();'
);

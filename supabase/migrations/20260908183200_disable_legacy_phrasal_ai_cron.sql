do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
    from cron.job
    where jobname in ('english-phrasal-daily', 'english-phrasal-hourly-recovery')
  loop
    perform cron.alter_job(v_job_id, active => false);
  end loop;
end
$$;

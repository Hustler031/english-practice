-- One-time Saved backlog drain requested after the Sep 8 recovery work.
-- Keep the normal 5-minute retry scheduler untouched; add a temporary 1-minute
-- accelerator that self-unschedules once no retrying/processing Saved items remain.
-- Existing retry delays are made due once here so every current backlog item gets
-- an immediate fresh chance; subsequent failures keep the normal finish/backoff rules.

update english.saved_enrichment_item_state es
set next_attempt_at = now(),
    updated_at = now()
where es.state = 'retrying';

create or replace function english.kick_saved_enrichment_priority_drain_once()
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','cron'
as $$
declare
  v_remaining integer := 0;
  v_req bigint;
begin
  perform english.reconcile_saved_enrichment_worker_http();

  select count(*)
  into v_remaining
  from english.saved_enrichment_item_state es
  join english.saved_items s
    on s.user_id = es.user_id
   and s.saved_id = es.saved_id
   and s.active
  where es.state in ('retrying','processing');

  if v_remaining = 0 then
    begin
      perform cron.unschedule('english-saved-enrichment-priority-drain-once');
    exception when others then
      null;
    end;
    return null;
  end if;

  -- Existing recovery logic respects single-flight leasing and next_attempt_at,
  -- so the accelerator never parallelizes writers or bypasses a newly assigned backoff.
  v_req := english.kick_saved_enrichment_recovery_if_needed();
  return v_req;
end;
$$;

do $$
begin
  if exists (
    select 1 from cron.job
    where jobname = 'english-saved-enrichment-priority-drain-once'
  ) then
    perform cron.unschedule('english-saved-enrichment-priority-drain-once');
  end if;
end;
$$;

select cron.schedule(
  'english-saved-enrichment-priority-drain-once',
  '* * * * *',
  'select english.kick_saved_enrichment_priority_drain_once();'
);

-- Start immediately instead of waiting for the first cron minute.
select english.kick_saved_enrichment_priority_drain_once();

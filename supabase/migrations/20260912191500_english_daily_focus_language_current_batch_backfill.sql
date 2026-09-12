-- A learner may have completed the 190-item core before Phase 2 is deployed.
-- Append the new language lane to the current study-day batch without altering any existing completion evidence.
do $backfill$
declare r record;
begin
  for r in
    select b.user_id,b.batch_date
    from english.daily_focus_batches b
    where b.batch_date=(now() at time zone 'Asia/Kolkata')::date
  loop
    perform english.ensure_daily_focus_language_lanes(r.user_id,r.batch_date);
  end loop;
end;
$backfill$;

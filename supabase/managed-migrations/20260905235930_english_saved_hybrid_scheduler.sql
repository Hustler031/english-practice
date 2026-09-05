-- Restore recurring My Saved ownership to the private Supabase worker now that
-- generation is Gemini -> independent Groq critic -> bounded Gemini repair.
-- The legacy ChatGPT/GitHub OIDC bridge remains available as a dormant fallback,
-- but normal recurring enrichment is server-side again through the existing
-- token-authorized claim/apply/finish and exact-promotion contracts.

do $cron$
declare
  r record;
begin
  -- Idempotently replace any stale definition of the same worker job.
  for r in select jobid from cron.job where jobname='english-saved-enrichment' loop
    perform cron.unschedule(r.jobid);
  end loop;

  perform cron.schedule(
    'english-saved-enrichment',
    '7 * * * *',
    'select english.kick_saved_enrichment_worker(10);'
  );
end
$cron$;

comment on function english.kick_saved_enrichment_worker(integer) is
  'Hourly My Saved enrichment launcher. Production generator ownership: Gemini writer -> Groq critic -> bounded Gemini repair -> validated existing Saved apply/promotion RPCs.';

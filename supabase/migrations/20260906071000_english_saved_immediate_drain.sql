-- My Saved immediate enrichment: drain one queued item after each successful item.
--
-- Consecutive saves can enqueue a second HTTP wake-up while the one-item worker
-- lease is still active. That second wake-up correctly exits as busy, but the
-- queue previously waited for the next save/hourly cron before being picked up.
--
-- After a successful finish, enqueue exactly one more worker call. pg_net sends
-- only after this transaction commits, so the released lease is visible to the
-- next worker. Provider/processing failures never self-retry here because
-- p_error is non-empty; the existing hourly cron remains the bounded recovery
-- path. The final successful item causes one harmless zero-pending worker call.

create or replace function public.english_saved_enrichment_worker_finish(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_error text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'english'
as $function$
declare
  v_verified jsonb := jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb);
  v_success_count integer := cardinality(coalesce(p_saved_ids,'{}'::text[]));
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;

  if not exists(
    select 1
    from english.saved_enrichment_worker_state
    where singleton=true and lease_id=p_lease_id
  ) then
    raise exception 'saved enrichment worker lease mismatch';
  end if;

  if v_success_count > 0 then
    v_verified := english.maintenance_verify_saved_enrichment(p_saved_ids);
  end if;

  update english.saved_enrichment_worker_state
  set lease_id=null,
      lease_expires_at=null,
      last_finished_at=now(),
      last_count=v_success_count,
      last_error=nullif(left(coalesce(p_error,''),1200),''),
      updated_at=now()
  where singleton=true and lease_id=p_lease_id;

  -- Drain only after a fully successful worker pass. A provider/processing
  -- failure must not form an immediate retry loop; hourly recovery handles it.
  if v_success_count > 0 and nullif(btrim(coalesce(p_error,'')),'') is null then
    begin
      perform english.kick_saved_enrichment_worker(1);
    exception when others then
      -- Finishing the current successful item must remain authoritative even if
      -- the follow-up wake-up itself cannot be queued. Hourly recovery is intact.
      raise warning 'My Saved follow-up enrichment kick failed: %', sqlerrm;
    end;
  end if;

  return v_verified;
end
$function$;

comment on function public.english_saved_enrichment_worker_finish(text,uuid,text[],text) is
  'Verifies/releases a My Saved worker lease and, only after full success, asynchronously wakes exactly one next pending item; failures rely on hourly recovery.';

-- My Saved smart routing: Luna is a one-shot rescue, never an automatic retry loop.
-- If the one-shot rescue itself cannot produce a deterministic-valid item, park the
-- item for manual review immediately. Genuine provider/transient failures that occur
-- before this marker keep the existing retry semantics.

create or replace function english.saved_enrichment_manual_terminal_guard()
returns trigger
language plpgsql
set search_path=pg_catalog,english
as $$
begin
  if upper(btrim(coalesce(new.last_error,''))) like 'SAVED_MANUAL_REVIEW_REQUIRED:%' then
    new.state:='failed';
    new.next_attempt_at:=null;
    new.last_error_class:='manual';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_saved_enrichment_manual_terminal_guard
on english.saved_enrichment_item_state;

create trigger trg_saved_enrichment_manual_terminal_guard
before insert or update of state,last_error,next_attempt_at,last_error_class
on english.saved_enrichment_item_state
for each row
execute function english.saved_enrichment_manual_terminal_guard();

-- Reconcile any item already carrying the new one-shot terminal marker.
update english.saved_enrichment_item_state
set state='failed',next_attempt_at=null,last_error_class='manual',updated_at=now()
where upper(btrim(coalesce(last_error,''))) like 'SAVED_MANUAL_REVIEW_REQUIRED:%';

comment on function english.saved_enrichment_manual_terminal_guard() is
  'Makes SAVED_MANUAL_REVIEW_REQUIRED terminal so a failed Luna one-shot rescue is never automatically regenerated/recritiqued.';

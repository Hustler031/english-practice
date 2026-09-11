-- REVIEW DUE TODAY — ENABLE VALID CROSS-MODULE CREDIT
-- Final coverage contract:
-- 1) Any durable attempt inside module=reviewduetoday covers today's obligation.
-- 2) Outside Review Due, only strong recovered evidence can cover the obligation.
--    Wrong / guessed / low-information evidence remains open.
-- 3) Cross-concept credit and automatic word-clock deferral are enabled together,
--    so sibling evidence cannot silently strand the original scheduled due question.
-- 4) The deferral path is audited and creates no synthetic attempts.

update english.review_due_runtime_config
set cross_concept_credit_enabled = true,
    auto_deferral_enabled = true,
    updated_at = now()
where singleton = true;

do $check$
begin
  if not exists (
    select 1
    from english.review_due_runtime_config
    where singleton
      and cross_concept_credit_enabled
      and auto_deferral_enabled
  ) then
    raise exception 'Review Due cross-credit and auto-deferral must be enabled together';
  end if;
end
$check$;

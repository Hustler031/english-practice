-- Historical production prepass for exact-payload duplicate reconciliation.
--
-- Production ran a conservative, data-only cleanup at this migration version before
-- the generic lossless reconciler was finalized. The later migration
-- 20260908052343_english_exact_duplicate_specialized_reconcile.sql is deliberately
-- written to reconcile every still-active exact-payload duplicate in a deterministic,
-- idempotent way. Keeping this historical version as a replay-safe marker avoids
-- maintaining two competing canonicalization engines while preserving the production
-- migration version/order.
--
-- No schema contract is introduced here; final duplicate canonicalization belongs to
-- the later generic reconciler.
do $$
begin
  null;
end $$;

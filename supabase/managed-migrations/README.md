# English V2 managed migration mirror

This directory records the managed Supabase migration ledger used by the English V2 runtime and migration foundation.

The live Supabase ledger remains the authoritative execution record. The complete 54-migration sequence is now represented here in execution order. `MANIFEST.md` records the mirror status; `20260828211355` is intentionally portable rather than byte-identical because its live owner UUID is not committed to the repository.

## Backend closure state

The English V2 backend now includes versioned support for:

- durable attempt history with idempotent submissions
- retention-aware learning profiles: New, Learning, Fragile, Weak, Persistent Weak, Strong and Proven Mastered
- Daily due-clock reconciliation, target-as-maximum behavior, category weakness/retention weighting, quotas/caps and durable selection rationale
- actionable Daily counts that suppress stale rows without forced replacement
- top-level Central Intelligence and Smart central revision selection
- Starred adaptive intelligence, selection signals and legacy day / 10-day block / 30-day month hierarchy
- Smart My Saved intelligence and hierarchy, including Auto -> internal CU capture semantics
- Phrasal concept-level recognition/recall/confusion intelligence
- Bank Coverage restricted to genuine core-bank exposure
- module-level Progress intelligence for Practice, New, Demand, Hindu, Sources and Saved
- Demand set state and source/provenance-aware composition
- authenticated-only RPC write surface with direct user-state table DML blocked
- database health/reconciliation checks for learning state, flags, references, duplicates, Daily state and generated-content ownership
- strict separation of user learning state from shared canonical question/Hindu content
- owner-scoped Saved-generated questions, including future promotion provenance, cross-user visibility isolation and practice-set membership guards

GPT enrichment execution and its schedule are intentionally deferred; the existing saved-item enrichment data contract remains in place and was not redesigned by backend finalization.

Do not treat Google Sheets and Supabase as independently writable production masters after final cutover. Until cutover, the existing Apps Script app remains the production/rollback runtime.

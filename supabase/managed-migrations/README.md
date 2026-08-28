# English V2 managed migration mirror

This directory records the Supabase managed migration ledger used by the English V2 runtime.

The live Supabase project remains the authoritative execution ledger until the full historical SQL mirror is materialized here. New V2 database changes must be versioned both in Supabase's managed migration history and in this repository.

## Runtime parity state

The current English V2 runtime includes versioned migrations for:

- learning-profile reconstruction from durable Performance attempts
- Daily due-clock reconciliation and selection
- My Saved capture/type/enrichment/promotion, including Auto -> internal CU
- Hindu vocabulary registry and practice
- authenticated read models for Starred, Difficult, Topic, Source, Demand and New Practice
- hardened RLS for user-state tables
- Phrasal concept intelligence, smart selection, today/history/hub APIs

`MANIFEST.md` lists the complete managed ledger and repository mirror status.

Do not treat Google Sheets and Supabase as independently writable production masters after final cutover. Until cutover, the existing Apps Script app remains the production/rollback runtime.

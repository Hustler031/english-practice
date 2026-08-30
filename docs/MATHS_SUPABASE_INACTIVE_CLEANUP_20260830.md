# Maths Supabase Inactive-Row Cleanup — 2026-08-30

This addendum supersedes the operational counts in `MATHS_SUPABASE_MIGRATION_HANDOFF_20260830.md` wherever they differ.

## User-directed rule

Rows marked `Inactive` in the **current primary Maths workbook** must not exist in the operational Maths migration/runtime dataset.

The current primary workbook remains authoritative over the pre-cleanup archive. Therefore an older archive copy does not restore a Question_ID that the current workbook explicitly marks Inactive.

Raw source and historical evidence remain immutable and auditable.

## Inactive rows found

Current workbook scan:

- `Generated_Practice`: 140 Active, 0 Inactive
- `Questions`: 838 Active, 1 Inactive

The only current-primary Inactive Question_ID was:

- `MIA017` — current row 163, `Mixture & Alligation / Weighted Mixture`, `Practice_Bank=ACADEMIC`

The archive contains an older Active copy of `MIA017`, but current-primary status overrides archive status.

## Operational cleanup performed

`MIA017` was removed from:

- `maths.questions`
- `maths.question_bank_memberships`
- `maths.diagram_assets`
- `maths.session_questions`

There were no operational Attempts, Exposures, QuestionState, Concept, Star, Demand-set or Note rows for `MIA017`.

Two operational session positions referenced the inactive question. They were removed and each affected session was compacted to contiguous zero-based positions. The Practice More session current index was shifted from 18 to 17 because the removed position was before the resume index. The Library session remained at index 0.

No historical session row or historical session item was deleted.

## Updated operational counts

- Canonical questions: **1,468**
- Diagram ledger rows: **1,468**
- Diagram-bearing questions: **336** (unchanged; `MIA017` had no diagram)
- ACADEMIC bank memberships: **269**
- Operational session positions: **1,061**

## Preserved audit/evidence counts

Unchanged:

- Raw source rows: **3,900**
- Raw rows for `MIA017`: **2** (current Inactive + archive Active)
- Historical attempt evidence: **1,225**
- Historical sessions: **179**
- Historical session positions: **4,706**

The raw/current Inactive row is intentionally retained in the audit ledger so the deletion policy is independently verifiable.

## Persistent audit record

A new migration run is recorded as:

`maths-inactive-cleanup-20260830`

Importer/version marker:

`maths-lossless-v1+inactive-cleanup-v1`

Reconciliation records verify:

- current-primary Inactive IDs found: **1**
- operational rows remaining for those IDs: **0**
- active canonical union after current-primary override: **1,468**
- `maths.questions`: **1,468**
- raw source rows before/after cleanup: **3,900 / 3,900**

## Final rule for Maths V2

Runtime/frontend work must treat current-primary `Status=Inactive` as a hard exclusion. Do not rehydrate `MIA017` or any future current-primary Inactive Question_ID from archive-only historical copies.

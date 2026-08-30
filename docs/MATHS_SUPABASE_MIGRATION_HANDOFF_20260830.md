# Maths Supabase Migration Handoff — 2026-08-30

## Scope

This handoff closes the **Maths data-migration-only** phase.

No Maths frontend was built or redesigned in this phase. No existing Maths UI was modified. No Maths V2 deployment was performed. English and GK internals were not changed. The existing live Maths Apps Script production app remains untouched.

Target Supabase project: `hytehindbmjdwcfptsic`

Target schema: `maths`

Migration branch: `maths-v2-integration`

Baseline branch commit before this handoff document: `536a52bfc09d8f14e513e945fcc3bf297240fb88`

## Authoritative sources

Two source snapshots are preserved:

1. `maths-current-20260830`
   - workbook: `Maths Revision`
   - role: `current_primary`
   - importer: `maths-lossless-v1`
   - current source is authoritative for overlapping operational records.

2. `maths-archive-20260819`
   - workbook: `Maths Revision — Pre-Cleanup Archive 2026-08-19`
   - role: `pre_cleanup_archive`
   - importer: `maths-lossless-v1`
   - archive is supplemental historical evidence and is never allowed to overwrite current operational state.

Every hydrated source row is retained in `maths.raw_source_rows` with source workbook/run, source sheet, source row number, full source JSON and a row hash.

### Raw source ledger

- Current source rows: **2,032**
- Archive source rows: **1,868**
- Total raw source rows: **3,900**

No source row was deleted to make the normalized model fit.

## Canonical Maths content

`maths.questions` contains **1,469 distinct canonical Question_ID records**:

- **979** selected from the current workbook
- **490** archive-only Question_IDs retained because they no longer exist in the current workbook

The archive contains 837 content IDs, of which 347 overlap current content. Overlaps are not duplicated canonically; the full archive rows remain preserved in `maths.raw_source_rows`.

### Practice-bank preservation

Academic classification remains independent from special-bank membership.

`maths.question_bank_memberships` currently contains:

- ACADEMIC: **270**
- CALCULATION: **368**
- CALCULATION_TRAINING: **140**
- CONCEPTS: **37**
- GENERATED: **140**
- MOCK: **71**
- MOCK_QUESTIONS: **71**
- MOCK_FORMULA_REVISION: **57**
- SUPPORT: **36**

This prevents MQ/MFR/CT membership from overwriting academic Chapter/Topic/Subtopic data.

## Diagram ledger

`maths.diagram_assets` contains one ledger row for every canonical question: **1,469** rows.

- Diagram-bearing questions: **336**
- Non-diagram questions: **1,133**
- `preserved_inline`: **336**
- `not_applicable`: **1,133**
- unresolved diagrams: **0**
- diagram-bearing rows missing payload: **0**
- diagram-bearing rows missing diagram type: **0**

All migrated Maths diagrams are structured inline JSON/geometry metadata. No external image/blob asset had to be invented or substituted.

## Learning evidence

### Attempts and exposures

`maths.historical_attempt_evidence`: **1,225** source attempt rows preserved exactly.

- Archive source attempts: 798
- Current source attempts: 427

`maths.attempts`: **1,212** FK-safe/queryable attempt rows.

`maths.exposures`: **391** valid normalized seen/exposure rows.

There are **13 source attempt references to missing historical question definitions**. They are deliberately not converted into fabricated canonical questions:

- current: 12 `CBPDF...` orphan question references
- archive: 1 `EL007` orphan question reference

Those rows remain available in the historical evidence/raw ledgers.

### QuestionState

`maths.question_state_evidence`: **403** source State rows preserved.

- current State rows: 394
- archive State rows: 9

`maths.question_state`: **394** current operational State rows.

The current State cache was imported as-is. It was **not bulk-recomputed from Attempts** because that would destroy historical evidence about the source system's own cache state.

Persistent integrity reporting records:

- 30 `state_attempt_count_diff` warnings
- 9 `state_last_attempt_diff_gt_60s` warnings

These are evidence/cache divergences, not migration omissions.

## Sessions and exact resume evidence

Historical session evidence:

- `maths.historical_sessions`: **179** rows
- `maths.historical_session_items`: **4,706** ordered question positions

Breakdown:

- current source sessions: **54**
- current source positions: **1,076**
- archive source sessions: **125**
- archive source positions: **3,630**

Operational current materialization:

- `maths.sessions`: **54**
- `maths.session_questions`: **1,063** valid positions

The difference of 13 current positions is intentional: those positions point to missing `CBPDF...` definitions. All 13 positions remain preserved in `historical_session_items` and the raw source rows, but are excluded from the FK-constrained operational table rather than inventing missing questions.

Archive integrity also records 3 orphan session-question references and 4 invalid legacy `Params_JSON` rows. Their original source JSON remains preserved.

## Concepts

`maths.concept_events`: **50** historical source events.

- current: 45
- archive: 5

`maths.concept_membership`: **44** current distinct operational memberships.

`CIRC008` has two source membership events. Both are retained in the event ledger; the latest current row is the operational membership.

## Demand sets

`maths.demand_set_evidence`: **5** source definition snapshots.

- current: 3
- archive: 2

Operational current sets:

- `maths.practice_sets`: **3**
- `maths.practice_set_items`: **192** ordered memberships

Current demand-set membership reconciles exactly: **192 source memberships = 192 operational memberships**.

## Notes and manual revision history

Notes:

- `maths.note_evidence`: **2** source note rows
- `maths.user_notes`: **1** current operational note

Star/manual revision history:

- `maths.star_event_evidence`: **127** source rows
  - current: 79
  - archive: 48
- `maths.star_events`: **78** distinct current operational event keys

The current source contains one exact duplicate Starred log row for `CG055`. Both source rows are retained in evidence; the operational event cache de-duplicates the exact event key.

## Chapter plan, settings and progress snapshots

- `maths.chapter_plan`: **12** meaningful rows materialized across both snapshots
  - current meaningful rows: 2
  - archive meaningful rows: 10
- `maths.settings_snapshot`: **29** source settings rows
  - current: 16
  - archive: 13
- `maths.progress_snapshots`: **44** rows
  - current: 24
  - archive: 20

Blank source placeholders are still present in `raw_source_rows`; only meaningful rows are materialized into the operational/audit helper tables.

Current Maths settings snapshot includes the source values for Daily size, New quota, Difficult rotation, new-content window, timezone and plan start date. These were preserved as data snapshots, not reinterpreted into new learning logic during migration.

## Persistent reconciliation

`maths.migration_reconciliation` contains **39** persistent reconciliation checks.

All source entities either reconcile exactly or carry an explicit source-origin warning explaining why an FK-safe operational cache has fewer rows than the historical evidence ledger.

Key PASS checks include:

- all 3,900 raw rows preserved
- 1,469 canonical Question_ID union = 1,469 `maths.questions`
- 336 diagram-bearing questions = 336 preserved diagram payloads
- current State 394 = operational State 394
- current Demand Sets 3 = operational sets 3
- current Demand Set memberships 192 = operational items 192
- current distinct Concept IDs 44 = operational memberships 44
- source attempt/exposure valid union 1,212 = operational Attempts 1,212
- current distinct Star event keys 78 = operational Star events 78

## Persistent integrity report

`maths.migration_integrity_issues` contains **no error-severity rows**.

Recorded warnings are source-origin anomalies and are intentionally retained rather than "fixed" by inventing data:

Current source:

- 12 orphan attempt question references (`CBPDF...`)
- 13 orphan session question references (`CBPDF...`)
- 30 State-vs-attempt-count divergences
- 9 State-vs-last-attempt-time divergences greater than 60 seconds

Archive source:

- 1 orphan attempt question reference (`EL007`)
- 3 orphan session question references (`EL007`)
- 4 invalid legacy session Params JSON rows

Informational duplicate-history records:

- `CIRC008` concept event history
- `CG055` Starred event history

These warnings must not be silently removed by a future V2 build.

## Access controls

RLS is enabled across the Maths schema tables.

Historical/audit ledgers such as `raw_source_rows`, `historical_attempt_evidence`, `historical_sessions`, `historical_session_items`, `migration_integrity_issues`, `migration_reconciliation`, source State/events/snapshots and migration metadata have no authenticated-user policies and remain audit/service-role only.

User-operational tables are owner-scoped by RLS. Public content tables such as canonical questions, diagram ledger and bank membership are authenticated-read only.

All user-bound operational Maths tables currently resolve to a single migrated owner, consistent with the source workbook's single-user learning history.

## Supabase migration ledger

The following Maths migration versions are recorded in `supabase_migrations.schema_migrations`:

1. `20260830121830` — `maths_lossless_data_foundation`
2. `20260830121917` — `maths_historical_evidence_ledger`
3. `20260830123431` — `maths_complete_migration_schema`
4. `20260830123600` — `maths_migration_parse_helpers`
5. `20260830123722` — `maths_complete_learning_evidence`
6. `20260830123745` — `maths_complete_session_evidence`
7. `20260830123836` — `maths_complete_diagram_and_bank_ledger`
8. `20260830124036` — `maths_normalize_seen_exposures`
9. `20260830124331` — `maths_persistent_integrity_report`
10. `20260830124444` — `maths_persistent_reconciliation`
11. `20260830124700` — `maths_migration_final_hardening`

The database migration ledger is the authoritative record of the exact SQL that was applied.

## Contract for the follow-up Maths V2 build

A separate frontend/runtime build may now use this schema, but it must preserve these rules:

1. Treat `maths.questions` as the canonical content union, with current source preferred over archive overlap.
2. Do not fabricate definitions for orphan `CBPDF...` or `EL007` historical references.
3. Treat raw/evidence tables as immutable migration authority; do not rewrite them to make runtime caches look cleaner.
4. Treat `maths.question_state` as the migrated current cache snapshot and Attempts/Exposures as historical evidence. Any future learning-engine reconciliation must be an explicit runtime design decision, not a migration rewrite.
5. Preserve special-bank membership independently from academic Chapter/Topic/Subtopic.
6. Preserve exact session order/current-index/rendered-question evidence when implementing resume.
7. Preserve manual flags, concept history, demand-set order, notes and Starred revision history.
8. Render the preserved structured diagram payloads; do not replace them with invented diagrams.
9. Keep all user mutation paths owner-scoped through RLS/RPCs.
10. Do not mutate or depend on the old live Apps Script app during V2 development.

## Final migration verdict

**MATHS DATA MIGRATION: COMPLETE FOR ALL AVAILABLE SOURCE DATA.**

This means every available source row and learning-evidence row is preserved losslessly/auditably, and every record that can be safely materialized without inventing missing source definitions has been materialized. The explicitly documented orphan references remain historical evidence by design.

This handoff does **not** claim that the future Maths V2 frontend/runtime has been built or deployed.
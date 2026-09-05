# English V2 AI architecture — Stage 2 independent audit bundle

Date: 2026-09-05

Stage-1 base branch: `english-ai-architecture-stabilization-stage1-20260905`
Stage-1 frozen base SHA: `b6f462c9ee06a8d416fcab4c148bd762476cb735`
Stage-2 branch: `english-ai-architecture-audit-stage2-20260905`
Stage-2 validation code SHA before this documentation-only commit: `bc211b1a98d1ed0ba13e711e9ab46eb6e07c0cd9`
Stage-2 PR: `#117`, draft, base = frozen Stage-1 branch.

## Stage-2 rule

Stage 2 is an independent audit plus targeted remediation only. No new learning architecture or learner-facing feature was introduced. Production remains untouched; Stage 3 is the release/production-validation phase.

## Independent findings and remediations

### 1. Targeted Daily overlay could over-inject

**Finding:** Stage-1 correctly preserved Weak/Fragile/Persistent Weak/etc. as the base Daily reason, but `rebalance_daily_targeted` counted only rows already carrying the `TARGET` signal. Targeted-route concepts that the deterministic base selector had already chosen did not satisfy the overlay budget, so the rebalancer could replace additional rows and increase Targeted-route representation unnecessarily.

**Remediation:** `20260905110000_english_daily_targeted_overlay_budget.sql` counts naturally selected Targeted-route Daily concepts first. Up to the bounded target budget is marked for telemetry, and only a genuine remaining deficit may replace untouched lower-priority rows. Base reasons remain unchanged and total Daily capacity remains 120 when 120 eligible distinct concepts exist.

**Regression:** `.github/scripts/validate-english-stage2-targeted-overlay.sql` first captures Targeted-route representation from `create_daily_core_20260905`, then proves rebalancing does not add further Targeted-route rows when the natural base selection has already satisfied the budget.

### 2. Worker Health double-counted retry-wait as queued

**Finding:** `english_get_ai_worker_health()` counted every physical `status='queued'` row in `queued`, including rows whose `next_attempt_at` was in the future. The same rows were also counted in `retrying`, so operational backlog totals were not state-exclusive.

**Remediation:** `20260905111000_english_worker_health_queue_semantics.sql` defines `queued` as runnable now (`next_attempt_at is null or <= now()`) and `retrying` as future retry-wait. Processing and failed counts remain unchanged.

**Regression:** `.github/scripts/validate-english-stage2-worker-health.sql` creates one runnable queued job and one future retry-wait job and requires `queued=1`, `retrying=1`, `processing=0`.

### 3. Dedicated Revision stale recovery bypassed typed terminal classification

**Finding:** the older generic revision claim function can recover stale `processing` rows before the dedicated Stage-1 failure classifier sees them. A third stale attempt can therefore become terminal `failed` without the Stage-1 `RETRIES_EXHAUSTED` error code; a reclaimed retry could also retain a previous transient error code while actively processing again.

**Live evidence:** read-only production inspection found the single failed revision proposal at three attempts with `Background AI request timed out safely after 24s`. Production does not yet have the Stage-1 `error_code` column because Stage 1/2 are intentionally undeployed.

**Remediation:** `20260905112000_english_revision_stale_retry_classification.sql` makes the dedicated Revision claim wrapper normalize stale recovery first: retryable stale work is classified transiently, third-attempt stale work becomes typed `RETRIES_EXHAUSTED`, and the transient code is cleared after a retry is actively reclaimed.

**Regression:** `.github/scripts/validate-english-stage2-revision-stale-retry.sql` executes a stale attempts=2 and attempts=3 fixture and verifies active retry recovery plus typed terminal exhaustion.

## Live read-only cross-check

Production still shows the old Daily state because Stage 1/2 have not been deployed:

- current Daily rows observed: 44;
- actionable questions observed: 5,566;
- actionable unique concepts observed: 3,919;
- revision queue: 4 ready, 1 failed;
- semantic queue: 11,917 done;
- transfer queue: 8 done.

This is expected release drift, not a Stage-2 source regression. Stage 3 must deploy the validated migration sequence and then verify the live 120-capacity repair and worker lifecycle behavior.

## Supabase ↔ Git reconciliation

The authoritative Stage-1 closure is `supabase/managed-migrations/ENGLISH_LIVE_LEDGER.json`: 70/70 live English migration executions from Sep 1 through Sep 4 are mapped to managed Git sources and protected by `.github/scripts/validate-english-migration-reconciliation.cjs`.

`STAGE1_AI_ARCHITECTURE_AUDIT_BUNDLE.md` and the older Stage-1 paragraph in `MANIFEST.md` were written before that final reconciliation commit and retain historical wording about pending exact recovery. They are superseded for release decisions by the final live ledger plus this Stage-2 bundle; no historical audit file was rewritten to pretend it had contained later evidence.

## Validation on Stage-2 remediation head `bc211b1…`

All triggered GitHub workflows completed successfully:

- Validate English Stage 2 Audit — PASS
  - Targeted overlay budget regression — PASS
  - Worker Health queued/retrying semantics — PASS
  - Revision stale/retry classification — PASS
- Validate English Daily 120 — PASS
- Validate English Daily Hindu Boundary — PASS
- Validate English Concept Dashboard — PASS
- Validate English Migration Reconciliation — PASS (70/70)
- Validate English V2 Web — PASS
  - dependency install — PASS
  - fresh-session migration syntax — PASS
  - question revision migration behavior — PASS
  - fresh-session/cooldown/mastery contracts — PASS
  - full English reliability/learning contracts — PASS
  - shared GK contracts — PASS
  - Maths source boundary/contracts — PASS
  - TypeScript — PASS
  - production build — PASS
- Validate GK V2 — PASS
  - clean-room backend reconstruction — PASS
  - behavioral contracts — PASS
  - TypeScript — PASS
  - production build — PASS
  - final scope/secret cleanliness guard — PASS

## Stage-2 classification

**BLOCKER:** 0 after remediation.

**KNOWN LOW-RISK / RELEASE-EXPECTED:** production still runs the pre-Stage-1/2 implementation until Stage 3. This includes the observed 44-row Daily batch and the old untyped failed revision row. They must be repaired/verified during the controlled Stage-3 release; they are not evidence that the Stage-2 source branch is failing.

**INTENTIONAL:** no Stage-2 production SQL, Edge Function deployment, Cloudflare deployment, merge to `main`, learner-data rewrite, Maths implementation change, or GK implementation change.

Production was **NOT deployed** in Stage 2.

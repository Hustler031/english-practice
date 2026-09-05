# English V2 AI architecture — Stage 2 independent audit bundle

Date: 2026-09-05

Stage-1 base branch: `english-ai-architecture-stabilization-stage1-20260905`
Stage-1 frozen base SHA: `b6f462c9ee06a8d416fcab4c148bd762476cb735`
Stage-2 branch: `english-ai-architecture-audit-stage2-20260905`
Final Stage-2 audited code SHA before this documentation-only freeze: `c630167e2905b8182f6953fbfb591d3f822d080f`
Stage-2 PR: `#117`, draft, base = frozen Stage-1 branch.

## Stage-2 rule

Stage 2 was an independent audit plus targeted remediation only. No new learning architecture was introduced. Production remained untouched throughout Stage 2; the next phase is controlled release and production validation.

## Independent findings and remediations

### 1. Targeted Daily overlay could over-inject

Stage 1 correctly preserved Weak/Fragile/Persistent Weak/etc. as the base Daily reason, but `rebalance_daily_targeted` counted only rows already carrying the `TARGET` signal. Targeted-route concepts naturally selected by the deterministic base selector did not satisfy the overlay budget, so extra Targeted concepts could be injected.

Remediation: `20260905110000_english_daily_targeted_overlay_budget.sql` counts naturally selected Targeted-route concepts first. Only a true deficit may replace untouched lower-priority rows. Base reasons remain unchanged and capacity remains exactly 120 when at least 120 distinct eligible concepts exist.

Regression: `.github/scripts/validate-english-stage2-targeted-overlay.sql`.

### 2. Worker Health double-counted retry-wait as queued

`english_get_ai_worker_health()` counted future retry-wait rows both as `queued` and `retrying`.

Remediation: `20260905111000_english_worker_health_queue_semantics.sql` makes `queued` runnable-now only and `retrying` future `next_attempt_at` work.

Regression: `.github/scripts/validate-english-stage2-worker-health.sql`.

### 3. Dedicated Revision stale recovery bypassed typed terminal classification

The legacy generic revision claim could recover stale processing rows before the dedicated Stage-1 failure classifier saw them, allowing third-attempt stale work to become terminal without a typed `RETRIES_EXHAUSTED` code and allowing active retries to retain old transient codes.

Remediation: `20260905112000_english_revision_stale_retry_classification.sql` normalizes stale recovery in the dedicated Revision claim path, types terminal exhaustion, and clears stale transient codes once a retry is actively reclaimed.

Regression: `.github/scripts/validate-english-stage2-revision-stale-retry.sql`.

### 4. English helper functions retained mutable search paths and four FK relationships lacked covering indexes

Fresh Supabase security/performance advisor inspection identified 17 English helper functions with mutable search paths and four English FK advisories. These were legitimate hardening items; unrelated GK/Maths warnings and generic unused-index warnings were not chased.

Remediation: `20260905113000_english_helper_search_path_and_fk_indexes.sql` applies behavior-neutral fixed `search_path = pg_catalog, english` settings to the exact 17 flagged helpers and adds three indexes that cover all four English FK relationships.

Regression: `.github/scripts/validate-english-stage2-db-hardening.sql` with dedicated `Validate English Stage 2 DB Hardening` workflow.

### 5. Inner English worker RPCs inherited PostgreSQL default PUBLIC execute

The public Edge-worker wrappers were already service-role-only and the inner functions also verified private worker tokens, but several inner `english`-schema claim/apply/fail helpers still inherited default PUBLIC EXECUTE. This was unnecessary attack surface.

Remediation: `20260905114000_english_inner_worker_acl_hardening.sql` revokes `public`, `anon`, and `authenticated` execution from the Context/Transfer/Quality internal worker API and grants `service_role` explicitly. Existing public worker wrappers remain the supported service-role surface.

Regression: `.github/scripts/validate-english-stage2-worker-acl.sql` with dedicated `Validate English Stage 2 Worker ACL` workflow.

### 6. Scheduler-only Semantic and Context Edge Functions advertised wildcard browser CORS

Semantic and Context workers used private scheduler tokens and service-role RPCs, but their source still returned `Access-Control-Allow-Origin: *`. Browser CORS was unnecessary for scheduler-only server-to-server endpoints.

Remediation: wildcard origin advertising was removed from `english-concept-semantic` and `english-context-worker`. Revision was already non-wildcard. `.github/scripts/validate-english-ai-architecture.cjs` now rejects wildcard CORS across all three worker sources.

## Ownership / tenant-boundary audit

Read-only production inspection verified:

- My Saved writes (`english_set_saved_enrichment`, `english_set_saved_item_type`, `english_update_saved_item`, `english_promote_saved_item`) resolve `auth.uid()` and constrain the saved item to that user.
- Sprint generation lifecycle RPCs (`start`, `begin`, `complete`, `fail`, usage logging) bind jobs/sessions to `auth.uid()`.
- Sprint Bank public wrappers bind marks, finalization and reads to `auth.uid()`.
- `english.promote_sprint_bank_item(...)`, the internal canonical promotion helper, is service-role-only and additionally validates the supplied user/session/bank row relationship.
- user-facing Revision proposals/reviews remain user-owned; worker-side claims/results are isolated behind private worker authorization and service-role wrappers.

No cross-user write path was found in the audited English flows.

## Worker ownership after Stage 2

- Semantic worker: embeddings, similarity and semantic mapping only.
- Context/Learning worker: learner diagnosis and transfer fallback only.
- Revision/Quality worker: Improve Question and canonical answer-quality review only.

Context source contains no Revision/Quality claim path. Architecture CI enforces this ownership boundary.

## Live read-only pre-release cross-check

Production still runs the old Daily behavior because Stage 1/2 had intentionally not yet been deployed at this audit point:

- current Daily rows observed: 44;
- actionable questions observed: 5,566;
- actionable unique concepts observed: 3,919;
- revision queue observed: 4 ready, 1 failed;
- semantic queue observed: 11,917 done;
- transfer queue observed: 8 done.

This is release drift to be corrected by the controlled production deployment, not a source-branch regression.

## Supabase ↔ Git reconciliation

`supabase/managed-migrations/ENGLISH_LIVE_LEDGER.json` is the authoritative historical ledger: 70/70 live English migration executions from Sep 1 through Sep 4 are mapped to managed Git sources and CI-protected by `.github/scripts/validate-english-migration-reconciliation.cjs`.

`STAGE1_AI_ARCHITECTURE_AUDIT_BUNDLE.md` is retained as a historical Stage-1 artifact. Any older wording in it about pending migration recovery is superseded by the 70/70 live ledger and this Stage-2 release audit.

## Validation on final audited code SHA `c630167e2905b8182f6953fbfb591d3f822d080f`

All nine triggered checks completed successfully; no failed or in-progress checks remained:

- full English V2 validation / production build — PASS;
- GK V2 validation / production build — PASS;
- Daily exact-120 / non-starvation — PASS;
- Hindu Daily exposure boundary — PASS;
- Concept Intelligence dashboard reconciliation — PASS;
- migration reconciliation — PASS (70/70 historical live entries);
- Stage-2 Targeted / Worker Health / Revision remediation suite — PASS;
- English DB hardening regression — PASS;
- inner Worker ACL regression — PASS.

The full English V2 suite includes dependency install, TypeScript, production build, English reliability/learning contracts, fresh-session/cooldown/mastery, question revision behavior, shared GK contracts, and Maths source boundary/contracts.

## Supabase advisor classification

Release-blocking English findings addressed in source:

- mutable-search-path helper warnings: fixed for the exact 17 English helpers found during Stage 2;
- unindexed English FK warnings: covered by the Stage-2 indexes;
- worker inner-RPC least privilege: hardened.

Intentional/non-blocking categories are not treated as defects without concrete evidence:

- authenticated `SECURITY DEFINER` app RPCs that are explicitly the signed-in application API;
- internal deny-by-default RLS tables with no direct client policies;
- generic unused-index recommendations;
- GK/Maths advisor items outside English scope;
- project-wide Auth leaked-password-protection setting, which is not an English application architecture defect.

## Stage-2 classification

**BLOCKER:** 0 after remediation.

**KNOWN LOW-RISK / RELEASE-EXPECTED:** production still runs the pre-Stage-1/2 implementation until the controlled release. The 44-row Daily batch and the old failed revision item must be reconciled/verified after migrations are applied.

**INTENTIONAL:** no Stage-2 production SQL, Edge Function deployment, Cloudflare deployment, learner-data rewrite, Maths implementation change, or GK implementation change occurred during Stage 2.

Production was **NOT deployed** in Stage 2.

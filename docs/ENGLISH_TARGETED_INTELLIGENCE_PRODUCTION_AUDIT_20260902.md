# English V2 — Targeted Mastery / Learning Intelligence Production Audit

Date: 2026-09-02

Scope: English V2 only. Production backend is Supabase. Frontend release target is Cloudflare Workers only. No GK or Maths internals were changed.

## Executive result

The concept-centric learning architecture is genuinely operating in production. Learner attempts, Add Context, I Guessed, background Luna diagnosis, bank-first transfer search, Targeted routing, generated transfer creation, critic quality gating, activity logging, and signal reconciliation all have live production evidence.

The audit also found six integration defects that could make the learner-facing Targeted view look less accurate than the underlying evidence. Those defects were repaired in the production Supabase migration `english_targeted_context_delivery_integrity` and preserved in this branch as `supabase/managed-migrations/20260902043000_english_targeted_context_delivery_integrity.sql`.

The frontend modernization is deliberately UX-only after those backend integrity fixes: Targeted Mastery is now a compact workspace with drill-down category views, Learning Intelligence is compact/collapsible, and Home no longer exposes Bank Coverage in Quick Start.

## Live evidence observed

### Attempts and learner signals

Recent production activity contained real quiz attempts across normal and Targeted lanes, three learner Context notes, and four I Guessed signals.

The I Guessed records were reversible and did not alter correctness of the original correct attempts.

### Add Context

Three real notes covered three different paths:

- `PV0310`: a genuine `bear on` / `bear out` confusion was resolved deterministically to `confusion_pair` and reused existing bank items.
- `PV0400`: a retention note about the second meaning of `get at` was processed by `gpt-5.6-luna` as `retention_problem` and routed to spaced Targeted validation.
- `OWS0457`: a request for reverse-direction questions because option elimination was too easy was processed by `gpt-5.6-luna` as `transfer_problem`.

At audit time all three notes had completed processing; no context note was failed or stuck pending.

### Background worker

The `english-context-intelligence` cron remains active every two minutes and production job-run history observed during the audit was successful. The worker remained bounded and there was no evidence of queue flooding.

### Real generated transfer

A natural I Guessed event for `HV20260819_003` (`HINDU_WORD_WARRANTED`) found no bank alternate and created a real transfer-generation job.

That job completed in one attempt and produced private question `AIT_7371A0421A064347` with origin `targeted_generated`, owner isolation, and critic quality score `0.97`.

The audit found and fixed a delivery defect that previously allowed the generated item to be replaced by the old source question. Post-fix authenticated Targeted session output now delivers `AIT_7371A0421A064347` directly as a `transfer_check`.

The last natural lifecycle step remains runtime observation: the learner still needs to answer this generated item and later provide sufficient fresh/spaced proof so the open uncertainty can resolve.

## Defects found and fixed

### 1. False related concept from substring matching

The deterministic Context parser used substring matching against question words. A note containing the word `questions` could therefore match the vocabulary item `Quest`.

Observed consequence: the `OWS0457` transfer note incorrectly created a separate Quest confusion/related Targeted route.

Fix:

- related-word extraction only runs for a true confusion note;
- matching now uses normalized token/phrase boundaries rather than raw substring containment;
- the historical false confusion/provenance produced by this bug was removed while retaining real learner attempts as evidence.

### 2. Luna related terms were treated as confusion pairs for non-confusion diagnoses

The background diagnosis consumer previously routed matched `relatedTerms` as `confusion` even when Luna had diagnosed a transfer or retention problem.

Fix: only `confusion_pair` and `lexical_interference` can create cross-concept learner-confusion rows. Transfer problems remain concept-centric and use the bank-first transfer path.

### 3. Explicit Targeted kind could be overridden by legacy origins

Category derivation previously checked broad route origins before explicit `targeted_kind` metadata. This could display a real retention or transfer route as confusion.

Fix: one helper, `english.targeted_route_kind(...)`, now makes explicit metadata authoritative. Legacy origins are only fallbacks.

### 4. Generic Need Learning could hide Transfer / Retention for the same concept

Concept deduplication previously ranked `need_learning` ahead of `transfer_check` and `retention_check`.

Fix: deduplication now prioritizes:

1. confusion
2. transfer check
3. retention check
4. need learning

This makes explicit learner signals visible instead of being swallowed by the older generic backlog.

### 5. Generated transfer could be swapped back to its source question

Targeted delivery always searched for an alternate item. When the selected row was itself a newly generated `targeted_generated` transfer, that alternate search could select the original question and defeat the generation lifecycle.

Fix: an `AI Transfer` / learner-owned `targeted_generated` row is delivered directly.

Post-fix authenticated session proof showed the generated question itself in the focused set.

### 6. Targeted session nonce was ignored

The frontend already supplied a fresh session nonce, but the backend wrapper ignored it. Reopening focused practice could therefore produce the same ordered backlog repeatedly.

Fix: the nonce now rotates equally ranked concepts/alternates while retaining signal priority. Two different nonce tests returned different general backlog items while keeping explicit confusion/transfer work first.

## Post-fix Targeted state

A post-fix authenticated summary snapshot showed approximately:

- Active tracked concepts: 595
- Due now: 315
- My Confusions: 1
- Need Learning: 587
- Transfer Checks: 4
- Retention Checks: 3

These values are a live snapshot, not fixed expectations.

The large Need Learning total remains a product prioritization concern. The audit did not mass-delete or mass-generate anything. Instead, the scheduler now prevents generic backlog from outranking explicit signals and the new UI keeps the raw backlog behind an inspectable category view rather than dumping it onto the main page.

## Signal decay / recovery audit

`reconcile_learning_signals_after_attempt` implements reversible uncertainty:

- a correct fresh attempt on another question of the same concept can resolve an open I Guessed signal;
- confusion progresses through testing / improving and needs fresh plus spaced evidence before resolution;
- later contradictory evidence can reopen the confusion;
- Targeted recovery waits for sufficient evidence and no unresolved confidence/confusion blockers.

The real bear confusion correctly remained open after later contradictory performance, so the current behavior is evidence-driven rather than a permanent manual label.

## Security audit

Verified boundaries remain intact:

- learner-facing Targeted RPCs require authentication;
- public worker RPCs are not executable by anon/authenticated roles and remain service-only;
- `targeted_generated` and `saved_generated` origin metadata is owner-scoped;
- question visibility remains owner-only for private generated questions;
- the generated transfer observed during this audit belongs to the active learner and is visible through the intended owner path.

No browser exposure of the OpenAI key or private concept tables was introduced.

## Performance / architecture audit

Home still uses the lightweight `english_get_targeted_summary()` RPC. Detailed Targeted content is loaded only on the Targeted page, so this work does not re-introduce the previous heavy Home snapshot pattern.

No current Daily session was mutated by these fixes. No separate mastery state or scheduler was created.

## UX modernization in this branch

### Targeted Mastery

The long all-expanded page has been replaced with a compact dashboard-style workspace:

- focused due-now command card;
- clickable cards for My Confusions, Need Learning, Transfer Checks, Retention Checks and Recovered;
- each category opens an internal detail view instead of expanding the whole main page;
- question IDs, state, confidence and route reason stay inspectable;
- My Confusions supports surgical single-confusion practice;
- the main page shows only a small priority preview rather than the raw 500+ backlog.

### Learning Intelligence

The page is now action-first rather than dashboard-heavy:

- compact concept-model summary;
- Targeted Mastery and Today’s Info as clear actions;
- Today’s Info remains real database activity only;
- Context/I Guessed/Confusions remain compact signal cards;
- Recent Context stays collapsed;
- Priority Concepts shows a short list by default and expands on demand;
- System health/mapping stays collapsed unless the learner wants the audit view.

### Home / Revision

- Bank Coverage is removed from Home Quick Start.
- Targeted Mastery is moved higher and Home shows `due` rather than the huge raw active backlog.
- Bank Coverage remains reachable from Revision.
- Revision Targeted status emphasizes due/confusion/transfer counts rather than raw active count.

## Remaining production observation

After this frontend branch is validated and released through the normal `feature branch -> CI -> main -> Cloudflare` path, the highest-value manual runtime check is:

`I Guessed -> generated transfer -> learner answers generated item -> open guess resolves on valid independent evidence -> later spaced proof -> Targeted exits/recovery`

The generated question and delivery stages are now proven. The learner-attempt/resolution tail should be observed naturally rather than faked or force-mutated.

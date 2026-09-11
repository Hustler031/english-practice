# English V2 — Review Due Today Deployment Readiness

Date: 2026-09-11 (IST)

## Release decision

The learner-facing Review Due Today lane is deployment-ready with **cross-concept credit OFF by default**.

This release adds a fourth dynamic row inside Daily Focus while preserving the existing Daily Focus denominator:

- Repair: 50
- Bank Coverage: 70
- Fast Track: 50
- Daily Focus denominator: **170 unchanged**
- Review Due Today: **separate dynamic obligation; not part of 170**

The safe initial release practices exact scheduled due questions. Cross-module sibling/concept credit remains measured in shadow mode until its two runtime gates are explicitly enabled after the shadow GO criteria are met.

## Production state before this release

Already applied in production:

1. `20260911091322_english_review_due_today_phase1_shadow.sql`
2. `20260911091704_english_review_due_today_phase1_performance_hotfix.sql`
3. `20260911091750_english_review_due_today_phase1_attempt_key_fastpath.sql`
4. `20260911091933_english_review_due_today_phase1_execute_acl.sql`
5. `20260911092003_english_review_due_today_phase1_anon_acl.sql`
6. `20260911092538_english_review_due_phase2_shadow_decision.sql`
7. `20260911092709_english_review_due_phase2_selection_ledger.sql`

These existing production migrations are accounting/observability only. They do not change Daily Mix or Daily Focus routing.

## Migrations to apply with the learner-facing release

Apply in this exact order:

1. `20260911100000_english_review_due_practice_lane.sql`
   - adds learner-facing resolution classification;
   - adds Review Due summary and practice RPC;
   - one unresolved obligation per concept;
   - no fake attempts and no routing mutation.

2. `20260911100500_english_review_due_cross_credit_deferral_gate.sql`
   - adds runtime gates, both default `false`;
   - adds auditable question-clock deferral ledger;
   - installs the end-of-day deferral job as a no-op while gates are false;
   - preserves the existing question scheduler when no deferral exists.

3. `20260911101000_english_review_due_gate_aware_lane.sql`
   - while cross-credit is OFF, learner-facing practice is restricted to exact due question IDs;
   - when cross-credit is eventually enabled, fresh sibling recovery becomes eligible;
   - exposes gate state in summary/payload.

## Initial production configuration

The required initial state is:

```text
cross_concept_credit_enabled = false
auto_deferral_enabled       = false
```

Do not change either flag as part of the first learner-facing deployment.

With both flags OFF:

- exact due question answered correctly with strong evidence can resolve today's obligation;
- the exact question's normal `english_submit_answer -> recompute_question_state` path advances its own word/question review clock;
- sibling answers remain visible to the shadow analytics but do not close the learner-facing obligation;
- no cross-concept deferrals are written;
- the end-of-day deferral cron is a no-op.

## Frontend release contract

`/english/focus` contains four rows:

1. Repair Intelligence
2. Bank Coverage
3. Fast-Track Mastery
4. Review Due Today

Review Due Today:

- is loaded from `english_get_review_due_lane`;
- submits attempts with module provenance `reviewduetoday`;
- forces a fresh cache key with a nonce;
- flushes/waits for queued answer saves before re-reading the lane;
- refreshes the summary after the durable-answer event;
- remains separate from the 170 progress denominator.

Home has one Daily Focus entry. Its subtitle includes the Review Due remainder; there is no duplicate standalone shadow card.

## Scheduler semantics

The authoritative scheduled obligation source remains:

`english.question_state.next_review`

The concept key is used only to deduplicate the **same IST day's obligation**. It is not a global concept cooldown.

A concept may still be served by another module on the same or following day when that module has an independent learning reason such as:

- Weak / Persistent Weak;
- confusion recovery;
- transfer proof;
- Starred / My Saved learner intent;
- Grammar or Phrasal acquisition;
- Fast Track mastery proof;
- Sprint or other explicit practice.

## Evidence rules

Strong evidence requires:

- qualifying learner-facing module provenance;
- correct answer;
- not marked `I Guessed` for that attempt;
- question not flagged `too_easy` for the learner.

Learner-facing resolution:

- strong exact due answer: satisfied;
- wrong answer: needs repair;
- guessed/too-easy correct: low confidence;
- no qualifying exact evidence: remaining;
- later recovery may clear a wrong only under the configured recovery rules;
- sibling recovery is learner-effective only when cross-concept credit is enabled.

The conservative shadow status is retained separately for audit comparisons.

## Cross-concept credit activation gate

Do not enable cross-concept credit until all GO criteria are met:

1. At least 10 useful immutable shadow days, preferably 14.
2. Snapshot success >=99.9% of expected user-days.
3. Daily accounting invariant always holds:
   `due_at_start = satisfied + needs_repair + low_confidence + remaining`.
4. No duplicate obligation identity for the same user + date + concept.
5. No Review-Due-attributable answer-save or latency regression.
6. No unresolved/ambiguous concept mapping in the due set.
7. No guessed-only or too-easy-only false satisfaction.
8. Independent Repair/Targeted/Starred/Saved/Grammar/Phrasal reasons remain preserved.
9. Avoidable Daily Mix overlap is materially useful (recommended >=5% of Daily Mix capacity).
10. New-canonical Bank Coverage remains non-starved.

When all criteria pass, enable cross-credit and auto-deferral together, never one without the other.

## Why the two flags are coupled

Concept-level sibling evidence can satisfy today's retention obligation, but it must not leave the original word/question clock stale. Therefore sibling credit must be paired with an auditable word-clock deferral.

The deferral ledger:

- does not manufacture an attempt;
- does not change accuracy/history;
- records the evidence question and timestamp;
- records the previous `next_review`;
- records the deferral deadline and state;
- allows existing guess/context review overrides to bring a review earlier.

## Deployment order

1. Confirm PR CI is green.
2. Confirm branch is not behind `main`.
3. Apply the three learner-facing migrations in timestamp order.
4. Verify both runtime gates remain `false`.
5. Verify authenticated Review Due summary and lane RPCs; anon access must remain denied.
6. Verify Review Due lane with cross-credit OFF serves only exact due question IDs.
7. Deploy the web branch.
8. Smoke-test Home -> Daily Focus -> Review Due Today.
9. Answer one safe test item and verify:
   - attempt is durable;
   - Review Due count refreshes;
   - that question's scheduler moves through the normal recompute path;
   - Daily Focus 170 denominator is unchanged.
10. Leave cross-concept credit OFF and continue shadow collection.

## Rollback

The safest rollback sequence is feature-preserving rather than destructive:

1. Revert the frontend commit/merge to remove the Review Due row if learner-facing behavior must be withdrawn.
2. Keep both runtime gates `false`.
3. Do not delete Review Due snapshots, selection ledgers, or audit history.
4. The end-of-day deferral cron remains harmless with gates OFF.
5. Existing Daily Mix, Repair, Coverage, Fast Track, Targeted, Grammar, Phrasal, attempts, mastery and canonical content continue independently.

If a backend rollback is required before any cross-credit activation, the new learner RPCs can be removed/replaced without history rewriting because the initial release does not create synthetic attempts or cross-credit deferrals.

## Validation evidence

Completed before release readiness:

- Review Due dedicated CI contracts: PASS.
- English V2 contracts: PASS.
- TypeScript: PASS.
- production web build: PASS.
- GK boundary validation: PASS.
- gate-aware SQL rollback test: 153 lane rows, 0 non-exact rows with cross-credit OFF.
- cross-credit behavior rollback simulation:
  - sibling strong evidence stays shadow-only with gate OFF;
  - same evidence resolves with gate ON;
  - wrong -> fresh sibling recovery resolves only with gate ON;
  - guessed / too-easy evidence does not falsely satisfy.
- production Phase 1 summary path had previously been optimized to approximately 10 ms order-of-magnitude latency.

## Release posture

**GO for deployment of the exact-due learner-facing practice lane with cross-concept credit OFF.**

**NO-GO for enabling cross-concept sibling credit until the shadow GO criteria are met.**

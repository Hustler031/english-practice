# English V2 — Review Due Today phased rollout

Date: 2026-09-11 (IST)

## Executive decision

Use a two-phase rollout.

- **Phase 1 — Shadow accounting:** ACTIVE in Supabase. No routing, quota, mastery, attempt, or `next_review` behavior changes.
- **Phase 2 — Coordinated routing:** DESIGN LOCKED, but activation is gated. Do not enable until Phase 1 evidence passes the GO gates below.

## Audited production facts

- Generic scheduled review originates from `english.question_state.next_review` / `english.learning_profile(...)`.
- `english.concept_evidence.next_review` is a separate concept-intelligence clock. It is NOT the same schedule and must not become the Review Due Today authority.
- On 2026-09-11 at audit time:
  - seen questions: 3,045
  - active/non-mastered seen questions: 2,989
  - exact question-level due: 155 questions
  - exact question-scheduler due after concept dedup: 153 concepts
  - concept-evidence exact due: 116 concepts
  - overlap between those two concept sets: only 15 concepts
  - question-scheduler overdue: 2,161 rows at the initial audit; 1,708 concepts after concept dedup at that point
- All 3,045 seen questions had a usable concept key; no active low-confidence/flagged mapping was found.
- Daily Focus remains Repair 50 + Bank Coverage 70 + Fast Track 50 = 170.
- Bank Coverage 70 remains 20 familiar/pending siblings + 50 new canonical concepts. The 50-new component is orthogonal and must not be reduced by Review Due Today.
- Daily Mix already has cross-module concept satisfaction (`english.daily_satisfied_concepts`) for correct attempts outside Daily. This is useful precedent, but its rule is looser than the new strict Review Due Today evidence rule.
- Daily Focus `Completed` currently means the exact selected question was attempted; it does not require a correct answer. Therefore Daily Focus completion status must never be reused as Review Due Today satisfaction.

## Historical proxy: study-impact signal

For 13 available Daily Mix days from 2026-08-29 through 2026-09-10:

- average Daily Mix rows/day: 109.5
- average review-state rows/day: 96.7
- review-state share: 88.3% of Daily Mix rows
- average review concepts/day: 95.5
- average review concepts already correctly touched elsewhere before Daily Mix: 10.5/day
- weighted pre-Daily cross-module satisfaction: 11.0% of review concepts

This does **not** mean 88.3% of Daily Mix should be removed. Weak/Persistent Weak/Fragile/Difficult/Marked repetition is often pedagogically valuable. The 11.0% overlap is a candidate pool for duplicate reduction, subject to evidence-quality and independent-learning-reason checks.

Initial lower-bound Daily Mix capacity candidate: roughly 5–10 questions/day (~5–9% of a ~109.5-question day). A larger reduction is not authorized until Phase 1 produces clean due-at-start evidence.

## Core semantic rule

**Question/word clock schedules the obligation. Concept key deduplicates the obligation for that IST day.**

A concept being satisfied today means only:

> today's scheduled review obligation is closed.

It does NOT mean:

> suppress this concept globally until the scheduled word/question review date.

The same concept may appear tomorrow, or later the same day when Central Intelligence has an independent pedagogical reason: weakness, confusion, transfer check, user-starred intent, saved practice, Sprint, Grammar/Phrasal acquisition, etc.

## Phase 1 — Shadow accounting

### Production behavior

Phase 1 adds:

1. `english.review_due_day_runs`
   - immutable per-user + IST-day snapshot header
2. `english.review_due_obligations`
   - one row per user + day + concept
   - stores exact due question IDs from `question_state.next_review`
3. `english.capture_review_due_day(...)`
   - idempotent, advisory-lock protected
4. `english.capture_review_due_today_all_users()`
   - independent snapshot wrapper
5. `public.english_get_review_due_today()`
   - read-only authenticated summary
6. `english-review-due-snapshot` cron
   - 18:30 UTC = 00:00 IST
   - one minute before the existing primary Daily rollover

### Strict shadow evidence rule

For a due concept on that day:

- qualifying correct + not guessed + question not flagged `too_easy` + no qualifying wrong that day -> `satisfied`
- any qualifying wrong that day -> `needs_repair`
- only guessed-correct or too-easy-correct evidence -> `low_confidence`
- no qualifying attempt -> `remaining`

Wrong evidence deliberately overrides same-day success in Phase 1. This is conservative shadow accounting; it prevents false satisfaction while we measure behavior.

Unknown/blank module provenance does not satisfy the strict obligation.

### Failure isolation

Phase 1 does NOT add an attempt trigger. It derives status from canonical attempts when read. Therefore:

- an RPC failure cannot stop an answer from saving;
- a snapshot failure cannot corrupt attempts/history/mastery;
- retrying snapshot creation is idempotent;
- existing routing remains fully authoritative.

## Phase 2 — Coordinated routing (GATED OFF)

### Global rule

Introduce two separate signals:

- `scheduled_review_satisfied_today`
- `independent_learning_reason`

Decision:

- satisfied today + no independent learning reason -> suppress only redundant generic scheduled-review forcing for the rest of that IST day
- satisfied today + independent learning reason -> allow the module to serve the concept
- wrong / guessed / low-information evidence -> never suppress repair/targeted work

### Module policy

#### Daily Mix

Keep adaptive intelligence. Remove only generic scheduled-due work already strictly satisfied elsewhere when there is no independent reason.

Do NOT suppress:
- Weak
- Persistent Weak
- Fragile when retention evidence remains weak
- Difficult/Marked user-intent work
- confusion clusters
- transfer checks
- meaningful diversity/adaptive selection

Initial expected reclaim after GO: ~5–10 questions/day based on historical proxy, not a quota reduction.

#### Daily Focus Repair

Preserve the 50 quota initially.

Priority remains:
- failed review
- Weak/Persistent Weak
- retention failure
- unresolved guessed/confusion evidence

A concept being merely scheduled-due is not itself a Repair reason.

#### Bank Coverage

Keep 70 unchanged initially.

- 50 genuinely new canonical: NEVER reduced by Review Due Today.
- 20 familiar/pending siblings: keep initially; later evaluate duplicate overlap separately.

#### Fast Track

Keep 50 unchanged initially. Fast Track is mastery proof, not generic due clearing.

A valid Fast Track attempt may satisfy today's review obligation, but review satisfaction must not suppress independent mastery proof.

#### Targeted Mastery

Keep confusion recovery, transfer proof, guessed-signal recovery, and targeted retention checks independent.

Do NOT use Review Due Today as a global concept cooldown.

#### Grammar / Phrasal / Starred / My Saved / Hindu / Sprint

Keep their own pedagogical/user-intent routing. A strict valid attempt may satisfy today's central obligation, but the central obligation does not own those modules.

## Overdue policy

Never merge overdue debt into the Due Today denominator.

UI/logic must use two separate concepts:

- **Due Today** — exact scheduled obligations captured at 00:00 IST
- **Older Review Debt** — separate backlog, capped and gradually normalized

Do not force the current historical backlog into one day.

Future backlog priority:
1. Persistent Weak
2. Weak
3. Fragile
4. Learning
5. Strong

Always concept-dedup first. Backlog cap must be introduced separately after measurement.

## UI contract

Daily Focus remains:

`Repair 50 + Bank Coverage 70 + Fast Track 50 = 170`

Review Due Today is a separate dynamic Central Intelligence obligation and does not count toward 170.

Phase 1 Home card is read-only/shadow.

Future Phase 2 card:

- Due at start
- Satisfied elsewhere
- Needs repair
- Low-confidence evidence
- Remaining

Overdue is shown separately and never inflates the Due Today number.

## Phase 2 GO gates

Do not activate routing refinement until all of these are true:

1. At least 10 useful learning days of immutable snapshots are available, preferably 14.
2. Snapshot capture succeeds on >=99.9% of expected user-days.
3. Daily accounting invariant holds exactly:
   `due_at_start = satisfied + needs_repair + low_confidence + remaining`.
4. Duplicate credit count is zero: one obligation per user + day + concept.
5. No attempt-save error/latency regression is attributable to Review Due Today.
6. No missing/ambiguous concept mapping in the due set; current baseline is 0 missing.
7. Strict satisfaction contains zero guessed-only and zero too-easy-only false positives.
8. Shadow audit confirms that suppressing a candidate would not remove an independent Repair/Targeted/Starred/Saved/Grammar/Phrasal reason.
9. Measured avoidable Daily Mix overlap is material (recommended activation threshold >=5% of Daily Mix rows or equivalent concept capacity).
10. New-canonical coverage remains non-starved.

Any failure above is a NO-GO for routing activation; Phase 1 shadow can continue safely.

## Phase 2 activation order

When GO gates pass:

1. Enable central same-day satisfaction signal for Daily Mix generic scheduled-due candidates only.
2. Keep all quotas unchanged and measure one full cycle.
3. Extend the same independent-learning-reason guard to Repair candidate dedup only.
4. Leave Coverage-new, Fast Track, Targeted, Grammar, Phrasal, Starred, My Saved, Hindu, Sprint roles unchanged; they only contribute evidence.
5. Re-measure before any quota reduction.

The first Phase 2 change is composition/routing refinement, not workload reduction.

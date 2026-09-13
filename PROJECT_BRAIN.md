# English V2 — Project Brain

_Last updated: 2026-09-13 (IST)_

This file is the durable technical context for the English V2 project. It exists so future work can resume from the current architecture instead of reconstructing decisions from old chats.

## Read this first

Before changing English V2:

1. Read this file.
2. Verify the relevant live Supabase functions/data and current `main` before acting.
3. Treat live schema/data and committed migrations as stronger evidence than this summary if they disagree.
4. Do not touch Maths or GK while working on English V2 unless explicitly requested.
5. Preserve learner history, Central Intelligence evidence, frozen daily/focus batches, and existing routing contracts unless a change explicitly targets them.
6. Never put API keys, tokens, passwords, private user IDs, service-role credentials, or other secrets in this file. This repository is public.

## Source-of-truth hierarchy

1. Live production database/schema and runtime behavior.
2. GitHub `main` and committed Supabase migrations.
3. This `PROJECT_BRAIN.md` living summary.
4. Optional Google Doc mirror for human-readable history/notes.
5. Chat memory for high-level preferences only.

If two sources conflict, verify live behavior before making a production change.

## Project scope

- Product: personal SSC CGL English learning app.
- Repository: `Hustler031/english-practice`.
- Stack: Next.js + Supabase + Cloudflare Workers.
- Production English route: `https://english-practice.ashabup0.workers.dev/english`.
- English only in this project context. Maths/GK are separate concerns and must not be modified incidentally.
- User is a non-coder; implementation choices should be decisive, safe, and explained in plain language.

## Core learning philosophy

The system should minimize useless repetition while aggressively following genuine uncertainty.

Signals:

- Clean correct with no doubt signal → normal progression.
- `I Guessed` → correctness is preserved, but confidence is low; route to a Targeted transfer check.
- Mark/Star → learner wants revision/priority; this is learning intent, not the same as a guess.
- Difficult → stronger explicit difficulty signal.
- Wrong → negative evidence; weak/repair/targeted routing applies according to context.

Do not treat a clean correct answer as uncertain unless there is actual negative evidence or an explicit learner signal.

## Daily system — current structure

### Daily Mix

- Target: 120 questions.
- Performance-router based.
- Typical reason buckets include Controlled New, Targeted Performance, Learning Risk, Transfer Validation, and Mixed Performance.
- Daily Mix and Daily Focus are separate planning surfaces but concept conflicts are controlled.

### Daily Focus

Fresh Focus target: **220 total**.

- Repair: 70
- Grammar: 15
- Phrasal: 15
- Bank Coverage: 70
- Fast Track: 50

Lifecycle:

- An incomplete Focus batch carries over.
- A completed batch does not restart on the same day.
- A new Focus batch is created only on the next fresh study day.
- Existing/frozen batches must not be silently rebuilt when routing logic changes.

### Review Due Today

Review Due is scheduler-owned and separate from the 220 Focus target.

- It captures concept-level obligations from `question_state.next_review` plus unresolved carryover.
- Cross-credit can satisfy a Review Due obligation when strong qualifying evidence for the same concept is produced elsewhere that day.
- Review Due should represent work that is genuinely still owned by the review scheduler; it must not duplicate another module that currently owns the concept.

## Fast Track ownership contract

### Entry from Bank Coverage

A genuine bank question goes to Fast Track when:

- it is the first-ever attempt,
- the Bank Coverage attempt is clean/correct,
- there is no prior wrong on that question,
- the question is not marked Difficult.

This is implemented in `english.route_after_attempt_trigger()`.

### Fast Track verification

Fast Track owns the concept while the route is active and status is one of:

- `ready`
- `waiting`
- `retention_watch`

A clean Fast Track verification may move to `retention_watch` if Central Intelligence has not yet established long-gap Proven Mastery.

Retention checks remain inside the Fast Track lane; there is no separate retention module.

A failed Fast Track/retention check can route the item to Targeted/Repair.

### Review Due ownership guard — implemented 2026-09-13

**Important invariant:** an active Fast Track-owned concept must not simultaneously become an independent Review Due obligation.

Migration:

- `supabase/migrations/20260913231500_english_review_due_fast_track_ownership.sql`

Production logic baseline before this documentation-only commit:

- `050cb9c2f568e1c4593b3bbd685cd46a95e29ce7`
- commit message: `Implement Review Due Fast Track ownership guard`

Behavior:

- Review Due capture excludes concepts currently owned by active Fast Track.
- Carryover also excludes concepts that are now Fast Track-owned.
- If Fast Track later fails/exits to Targeted/Repair, normal review ownership can resume.
- Existing Review Due UI/query paths also respect the ownership guard.

Validation immediately after deployment on 2026-09-13:

- projected raw due concepts before guard: 464
- projected Fast Track-owned overlaps: 212
- projected due concepts after guard: 252
- leaked active Fast Track concepts after guard: 0
- projected due question rows after guard: 258
- Sep 14 snapshot had not yet been prematurely created during validation.

These counts are date-specific diagnostics, not permanent constants.

## Review Due cross-credit

Review Due is concept-deduped. A qualifying clean attempt elsewhere can satisfy the obligation when cross-credit is enabled.

For the 2026-09-14 read-only/full-build simulation after the Fast Track ownership fix:

- Review Due opening concepts: 252
- Daily Mix: 120
- Focus: 220
- Review concepts also planned in Focus: 31
- Review concepts also planned in Daily Mix: 28
- Review concepts overlapped by either planned module: 59
- Review concepts not pre-covered by Daily/Focus: 193

Therefore the opening Review Due number is not equal to unavoidable extra workload; it can shrink as qualifying attempts are completed elsewhere.

The simulation was rolled back; no Sep 14 Review/Focus/Daily rows were left behind.

## Learning profile / spaced-memory checkpoints

Current learning-profile model:

- All raw attempts count toward totals/accuracy.
- Only the **first attempt on each IST study date** is the spaced-memory checkpoint.
- Same-day repeats do not advance the spaced-memory streak.

Current states include:

- New
- Weak
- Persistent Weak
- Fragile
- Learning
- Strong
- Proven Mastered

Current broad interval behavior:

- Weak / Persistent Weak: short review (~+1 day)
- Fragile: short review, depending on streak
- Learning: currently +1 day
- Strong: +7 days
- Proven Mastered: +30 days

### Open design issue — NOT implemented yet

The current clean-learning progression is probably too aggressive for a high-volume learner because two consecutive clean study-day checkpoints can still produce another next-day review before becoming Strong.

Observed on the projected 2026-09-14 Review pool before the Fast Track ownership cleanup:

- 102 concepts had clean first checkpoints on both Sep 12 and Sep 13 and were still due again on Sep 14.

Preferred direction under discussion:

- 1st clean confirmation → +1 day
- 2nd consecutive clean confirmation with no uncertainty signal → +3 days
- next clean confirmation → Strong / ~+7 days
- later long-gap confirmation → Proven Mastered / ~+30 days

Weak, wrong, guessed, difficult, confusion, and explicit-learning-intent items should remain more aggressive.

**Do not implement this merely because it appears here.** It is an approved design direction under discussion, but needs a clean simulation and final implementation decision first.

### Proven Mastered edge case to audit

A small edge case was observed where already-Proven-Mastered items can reclassify to Strong because the long-gap classification is recalculated from the latest checkpoint pair. This should be audited before changing the spacing model.

## `I Guessed` behavior

Implemented behavior in `english.english_record_guess(...)`:

- preserves the answer's correctness,
- records a `guessed` confidence signal,
- pulls `next_review` forward to no later than ~12 hours,
- routes the item to Targeted,
- sets `targeted_kind = transfer_check`,
- seeks a fresh alternate question for the same concept,
- if no alternate exists, a transfer-generation job can be queued.

Interpretation:

- use `I Guessed` only for genuine low-confidence correct answers,
- do not use it on easy/fully-known questions,
- Mark/Star is for revision intent rather than low-confidence correctness.

## Repair selection

Repair target: 70.

The selection engine prioritizes critical learning needs first. Typical high-priority evidence includes:

- Persistent Weak / Weak
- Targeted confusion/learning/transfer
- Fast Track failure
- Fragile/risk evidence
- explicit learner intent such as Saved/Starred when appropriate

The exact priority function is live in Supabase and must be inspected before changing quotas or ordering.

## My Saved first-exposure SLA

Implemented 2026-09-13.

Goal: a Saved item must not become a passive bookmark that stays buried.

Contract:

- applies only after the saved item is active/Ready and has a usable practice question,
- duplicate saves for the same concept share one first-exposure obligation,
- natural practice elsewhere can satisfy the first-exposure requirement,
- otherwise the concept becomes priority by the second fresh Focus batch,
- Tier-1/Tier-2 critical Repair work remains protected,
- Saved SLA uses remaining non-critical Repair capacity,
- after first meaningful exposure, normal CI/spaced-learning rules govern.

Migration:

- `20260913204500_english_saved_first_exposure_sla.sql`

PR / merge history:

- PR #221
- merged implementation commit: `0b7d8b4ed3addfc7d07db75fb0ae5b47a40304d9`

A prior smoke simulation confirmed a previously starved Saved item (`dipsophobia`) would be surfaced under the SLA.

## Phrasal usage-first V2

Implemented 2026-09-13.

Daily Phrasal 20 curriculum:

- 4 Recognition
- 8 Usage/Recall
- 8 Confusion

Daily Focus Phrasal 15 adaptive target:

- 2 Recognition
- 7 Usage/Recall
- 6 Confusion

Key rule:

- `context_fill` is treated as Usage.

Relevant migrations:

- `20260913182500_english_phrasal_usage_first_intelligence.sql`
- `20260913183000_english_phrasal_daily_curriculum_v2.sql`
- `20260913183500_english_phrasal_focus_ci_v2.sql`

Implementation baseline:

- PR #220
- production logic commit at deployment time: `e337fdd5f3c8761cf7be4d13e06ea0a8e33a3008`

Frozen existing batches were intentionally preserved.

## Daily Confusion 15

Daily Confusion target: 15.

Composition:

- 4 confusable-word items
- 3 phrasal contrasts
- 3 look-alike/spelling items
- 2 homophone/homonym items
- 3 usage/collocation/governed-pattern items

Quality rules:

- SSC-style surfaces
- close educational distractors
- no filler
- natural answer balance
- explanation must teach why the correct answer works and why distractors fail

Current hub/revision implementation exists under the English Confusion flow.

Known integration note to verify before claiming otherwise:

- Review Due cross-credit historically accepted legacy module `hindu`; the newer `confusion` module was not in that qualifier list at the time of the last audit. Re-check live function before relying on Confusion to satisfy Review Due.

## Content quality principles

- Prefer genuinely challenging/high-yield SSC English.
- Avoid easy filler.
- Merriam-Webster is the preferred lexical reference, Cambridge next, then other authoritative sources.
- For confusables, synonyms, collocations, governed prepositions, phrasals, and usage questions, explanations should explicitly distinguish close alternatives.
- Near-confusing distractors are preferred over obviously wrong options.

## Production-safety rules

Before a routing/scheduler change:

1. Inspect live function definitions and relevant user-state data.
2. Quantify the actual problem with a read-only query.
3. Simulate the proposed result, preferably transactionally/rollback where possible.
4. Preserve frozen current batches unless the change specifically requires migration of them.
5. Apply the smallest production change that establishes the intended invariant.
6. Re-run a post-change simulation/diagnostic.
7. Commit the matching migration to GitHub.
8. Update this Project Brain.

Do not claim an item is fixed merely because code was written; verify the live behavior.

## Project Brain maintenance contract

After every **major implemented** change, update this file in the same work session with:

- what changed,
- whether it is PROPOSED or IMPLEMENTED,
- migration/PR/commit reference,
- invariants that must remain true,
- validation/smoke result,
- any newly discovered limitation or pending decision.

Do not append every minor chat detail. Keep this file compact enough to read at the start of future work.

For time-sensitive counts, always write the date and treat them as diagnostics, not permanent architecture.

## Google Doc mirror

A Google Doc may be maintained as a more readable project notebook/history. Recommended rule:

- GitHub `PROJECT_BRAIN.md` = canonical technical summary.
- Google Doc = readable mirror / decision journal / longer explanation.

Do not let the Google Doc become a competing source of truth for live schema or committed code. If the two disagree, verify GitHub + live Supabase and then repair the stale document.

When the Google Doc is connected/shared for editing, keep its major architecture/decision sections synchronized with this file after significant changes.

## Current open items

1. Decide and simulate the lighter clean-learning schedule (`C,C` should probably not force an immediate third consecutive-day review).
2. Audit the small Proven Mastered → Strong reclassification edge case before changing learning-profile intervals.
3. Re-check whether the new `confusion` module qualifies for Review Due cross-credit and fix if desired.
4. Continue observing Review Due after the Fast Track ownership guard to ensure no duplicate-ownership regression.
5. Keep Saved first-exposure backlog draining without allowing it to displace critical Repair work.

---

### Fast resume checklist for a future ChatGPT session

Read this file, then verify:

- current `main` HEAD,
- latest migrations,
- current Daily/Focus batch lifecycle,
- relevant live Supabase function(s),
- whether the requested change is already implemented, merely proposed, or stale.

Then continue from the current system instead of rebuilding project context from scratch.

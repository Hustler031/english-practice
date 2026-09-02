# English V2 — Question Quality / Revision Intelligence Audit — 2026-09-02

## Scope

English V2 only. Production is not changed by this branch. Home, Targeted Mastery overview, Learning Intelligence/Insights pages, GK internals, Maths internals, Cloudflare configuration and Vercel configuration are outside this implementation.

## Product contract implemented

### Improve Question = repair the question on screen

- `Options too obvious`: preserve the current stem, canonical correct key and correct option; improve weak distractors and rewrite the matching explanation.
- `Distractors are unrelated`: preserve the current stem, canonical correct key and correct option; replace unrelated distractors with close SSC-realistic alternatives and rewrite the explanation.
- `Explanation is weak`: preserve stem and all four options; rewrite explanation only.
- `Correct answer looks doubtful`: do not create a personal revision. Queue an independent canonical quality review; never silently mutate the canonical question/key.
- Custom feedback: make the minimum concept-faithful repair while preserving the canonical grading identity.

A bank item is reference evidence for traps/concept boundaries. It cannot become a silent replacement question in Improve Question.

### Related Practice = explicit new-question intent

A separate learner action requests a new related/confusable practice item. The backend checks the owner-visible bank first, skips alternates already measured as trivial for this learner, reuses a suitable bank item when present, and only otherwise queues the existing bounded private transfer-generation path. Reusable confusable terms are persisted for later discrimination practice.

### SSC toughness gate

Generated transfer questions and non-explanation-only revisions must satisfy validity and exam-difficulty quality: exactly one defensible answer, close distractors, no obvious elimination, upper-moderate/hard SSC CGL fit, at least two realistic trap distractors, distractor closeness >= 0.70, concept fidelity, fair/non-artificial difficulty, no ambiguity, matching explanation, critic quality >= 0.85. Generated transfers additionally require fresh context, semantic novelty >= 0.65 and exact/near-duplicate rejection.

The prompts explicitly reject easy-but-valid questions and CAT/GRE-style artificial obscurity.

## Backend intelligence added

- Learner-specific question difficulty calibration from correctness, response time and I Guessed evidence.
- Per-distractor selection/effectiveness ledger.
- Learner-specific `too_easy` signal used to de-prioritize trivial Targeted items.
- Revision strategy outcome tracking including follow-up performance.
- Confusable-cluster persistence.
- Private generated-question provenance.
- Worker observability/latency ledger.
- Canonical question-quality review queue.
- Explicit measurable Targeted exit evaluation based on distinct fresh proof, delayed proof, contradictions, confusions and unresolved guesses.

No second mastery engine is introduced.

## Worker safety

Context processing remains first. Only one non-context AI lane runs per invocation: Targeted transfer, then revision if no transfer was claimed, then canonical quality review if neither earlier lane has work. Improve Question therefore cannot starve the proven Context -> Targeted transfer path.

## Validation

Final validated branch head: `071f347949b3618f2dc1a02d9fe24a16bcc22fc8`.

English CI passed migration execution + lifecycle behavior tests, learner-specific triviality and bank-first related-practice tests, repair-only invariants, canonical quality-review isolation, fresh-session/mastery and reliability contracts, shared GK contracts, Maths boundary/contracts, TypeScript and production build. Separate GK validation also passed reconstruction, behavioral contracts, TypeScript, production build and scope guards.

## Release state

PR #109 remains open and unmerged. No migrations/functions from this PR have been applied to production Supabase and no production deployment has been performed.

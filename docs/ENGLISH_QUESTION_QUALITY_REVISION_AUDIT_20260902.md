# English V2 — Final Question Quality / Learner UI Pre-Deployment Audit — 2026-09-02

## Scope

English V2 only. This branch does not change production until an explicit release is approved. GK and Maths internals, Vercel, and Cloudflare configuration are untouched.

## Final verdict

**READY TO DEPLOY after explicit user approval.**

No production merge, Supabase migration, Edge Function deployment, or Cloudflare deployment was performed during this audit.

A real authenticated browser pass cannot be performed against this unmerged branch because no branch preview is deployed. The first authorized production release must therefore include an authenticated post-deploy smoke pass before the release is considered closed.

## Product contract verified

### Improve Question = repair the question on screen

- `Options too obvious`: preserve the current stem, canonical correct key and correct option; improve weak distractors and rewrite the matching explanation.
- `Distractors are unrelated`: preserve the current stem, canonical correct key and correct option; replace unrelated distractors with close SSC-realistic alternatives and rewrite the explanation.
- `Explanation is weak`: preserve stem and all four options; rewrite explanation only.
- `Correct answer looks doubtful`: do not create a personal revision. Queue an independent canonical quality review; never silently mutate the canonical question/key.
- Custom feedback: make the minimum concept-faithful repair while preserving the canonical grading identity.

Bank items remain reference evidence for traps and concept boundaries. They cannot become a silent replacement question in Improve Question.

### Explicit related-practice intent

Related/new-question intent is kept inside the custom Improve note instead of adding a fourth permanent question-screen action. The backend checks the owner-visible bank first, rejects learner-trivial or unproven easy/Medium alternates, reuses a suitable hard bank item when available, and only otherwise enters the bounded private transfer-generation path. The real source word is retained in confusable-term context.

### SSC toughness gate

Generated transfer questions and applicable revisions must satisfy both correctness and exam-difficulty quality: exactly one defensible answer, close distractors, no obvious elimination, upper-moderate/hard SSC CGL fit, at least two realistic trap distractors, distractor closeness >= 0.70, concept fidelity, fair/non-artificial difficulty, no ambiguity, matching explanation, and critic quality >= 0.85. Generated transfers additionally require fresh context, semantic novelty >= 0.65, and exact/near-duplicate rejection.

The prompts and critic explicitly reject easy-but-valid questions and CAT/GRE-style artificial obscurity.

## Backend intelligence verified

- Learner-specific question difficulty calibration from correctness, response time, and I Guessed evidence.
- Per-distractor selection/effectiveness ledger.
- Learner-specific `too_easy` signal used to de-prioritize trivial Targeted items.
- Revision strategy outcome tracking including follow-up performance.
- Confusable-cluster persistence.
- Private generated-question provenance.
- Worker observability/latency ledger.
- Canonical question-quality review queue.
- Explicit measurable Targeted exit evaluation based on distinct fresh proof, delayed proof, contradictions, confusions, and unresolved guesses.

No second mastery engine is introduced.

## Worker safety

Context processing remains first. Only one non-context AI lane runs per invocation: Targeted transfer, then revision if no transfer was claimed, then canonical quality review if neither earlier lane has work. Improve Question therefore cannot starve the existing Context -> Targeted transfer path.

## Learner UI verified

Home keeps the existing structure and adds one compact `Next Best Action`. Targeted suggestions are gated by authoritative due-now work rather than future retention totals.

Practice presents Daily Practice, Targeted Mastery, Fast Track, New Practice, Topic Practice, and Exam Sprint, with Sources/custom/bank options retained as secondary choices.

Targeted Mastery presents `FIX NOW`, `YOUR CONFUSIONS` when present, `WAITING FOR LATER`, and `Learning Insights`. Learner-facing names replace internal IDs. Start Focused Practice and Fix Now use a due-only Targeted session so scheduled future retention cannot leak into immediate repair.

Revision presents Due Now, Difficult & Incorrect, Starred, My Saved, Browse by Topic, and Learning Insights.

Learning Insights presents TODAY'S INFO / What changed today, FIX NOW, CHECK SOON, IMPROVING, SCHEDULED FOR LATER, and How your learning plan works. Normal learner surfaces do not expose model names, route-event jargon, question IDs, or confidence percentages.

## Question-screen coverage verified

After answer/explanation the common question screen exposes exactly:

- Add Context
- I Guessed
- Too Easy / Improve Question

Shared practice routes already inherit this through `QuizRunner`. Final audit found and fixed the two direct renderers that did not:

- Daily now hydrates accepted personal revisions and exposes all three learning actions.
- The Hindu quiz now hydrates accepted revisions through `centralQuestionId` and exposes Add Context, I Guessed, and Improve Question while preserving its existing marking, Saved Vocab, Difficult, Mastered, and round behavior.

## Real defects found and fixed in final audit

1. Daily direct renderer was outside revision overlay/action flow — fixed.
2. Hindu direct renderer was outside revision/context/guess flow — fixed.
3. Home Next Best Action could treat future Targeted totals as immediate work — fixed.
4. Generic Targeted batch could place a future retention item into Fix Now — fixed with authenticated due-only Targeted session.
5. Related Practice could reuse an unproven Medium/easy same-concept bank alternate — fixed with a hard/observed-difficulty suitability gate while preserving bank-first.

A production data audit supplied a concrete example for the fifth issue: the same-concept DESULTORY alternate was Medium and trivially eliminable, matching the learner's complaint. That class of alternate no longer bypasses the SSC-tough generation path.

## Security / compatibility audit

Production schema was inspected read-only. Existing questions, mappings, attempts, question state, concept evidence, confidence signals, confusions, Targeted transfer jobs, and learning-route state are compatible with the new migrations.

Personal revisions remain user-owned overlays over the same canonical Question_ID. The canonical bank row, attempt history, question state, and concept evidence are not rewritten by revision application.

Production remains untouched: the new revision/quality tables and due-only Targeted RPC are absent until an authorized release.

## Validation

Final validated branch head before this documentation-only update: `712b1a6b988a8973939284c120e21639dd822cdd`.

English CI PASS on that implementation head:
- all revision/quality/UI-support/final-audit migrations execute in ephemeral PostgreSQL;
- revision lifecycle behavior;
- repair-only invariants;
- canonical doubtful-answer review;
- cross-user isolation;
- learner-specific triviality calibration;
- hard bank-first related-practice behavior;
- unproven Medium alternate rejection;
- source-word confusable anchor preservation;
- due-only Targeted exclusion of future retention;
- learner-facing label/exact Targeted route isolation;
- fresh-session and mastery contracts;
- existing English reliability/learning contracts;
- shared GK contracts;
- Maths boundary/contracts;
- TypeScript;
- production build.

Separate GK validation PASS on the same implementation head: clean-room reconstruction, behavioral contracts, TypeScript, production build, and final scope/secret guard.

## Release state

PR #109 remains open and unmerged. No migrations/functions from this PR have been applied to production Supabase and no production deployment has been performed.

After explicit user approval, release must merge PR #109, apply English migrations, deploy the updated English context worker, allow the normal Cloudflare production build, and then run an authenticated production smoke test across Home, Practice, Targeted Fix Now/Waiting, Revision, Learning Insights, shared QuizRunner, Daily, Hindu, revision queue/ready/preview/apply, Related Practice, and background worker completion.

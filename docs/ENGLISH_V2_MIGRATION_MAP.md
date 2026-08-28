# English V2 — Supabase Migration Map

Baseline: `main@bc1ccc4bc40428c0871a3bd29bcbcb43d79e4e90`

## Non-negotiable rule

V2 changes persistence and delivery architecture first. It must not redesign or simplify the learning model. Existing Daily, mastery, My Saved, Starred, Difficult, New Practice, source/topic practice, Hindu and phrasal behavior remain authoritative until parity tests prove a deliberate replacement.

## Canonical data ownership

| Current source | V2 target | Authority / purpose |
|---|---|---|
| `Questions` | `english.questions` | Canonical question/content bank |
| `Performance` | `english.attempts` | Durable learning event log; authoritative evidence for learning profiles |
| `Question_Status` | `english.question_state` | Current/materialized state, not a replacement for attempt history |
| `Daily_History` | `english.daily_history` | Historical Daily membership/status |
| `Daily_Quiz` | `english.daily_current` | Current persisted Daily batch and sequence |
| `My_Words` | `english.saved_items` | Saved item/enrichment payload |
| `My_Word_Types` | `english.saved_item_types` | Capture type and resolved internal lexical type, including internal `CU` |
| `Starred_Revision_Log` | `english.star_events` | Authoritative Star/Unstar event history |
| `Starred_Revision_Difficult` | `english.difficult_state` | Current difficult state |
| `Mastered_Log` | `english.mastery_events` | Durable explicit mastery/restoration intent |
| `Sources` | `english.sources` | Source registry/import metadata |
| `Hindu_Words` | `english.hindu_words` | News-vocabulary source metadata and first/last practice state |
| `Recall_Check` | `english.recall_checks` | Recall/re-ingestion checks |
| `Demanded_Practice` | `english.practice_sets` + `english.practice_set_items` | Normalized demand-set membership |

## Current migration status

Core content/state migration is complete and reconciled:

- 6,745 unique canonical questions.
- 1 duplicate source question row safely deduplicated.
- 1,964 current `Question_Status` rows assigned to the authenticated user.
- 1,675 distinct valid `Daily_History` rows.
- 238 `My_Words` rows.
- 4 historical Daily rows referencing removed/non-canonical questions retained in immutable migration evidence rather than fabricated into the canonical question bank.

Behavior-parity audit identified additional production-critical source data which must be migrated before V2 cutover:

- `Performance`: 4,623 rows. This is critical because `LearningIntelligence.gs` derives learning profiles from the durable attempt log. 36 historical attempts reference 19 questions no longer in the canonical bank; preserve those as migration evidence and do not create fake canonical questions.
- `Starred_Revision_Log`: 702 rows; 684 STAR and 18 UNSTAR events. One historical event references a removed question and must remain historical evidence only.
- `Starred_Revision_Difficult`: 72 current-state rows.
- `Mastered_Log`: 59 rows. Duplicate events are legitimate history and must not be collapsed merely because the Question_ID repeats.
- `Daily_Quiz`: 120 current batch rows; sequence must be preserved.
- `My_Word_Types`: 106 rows; current types are V=44, CU=19, SM=16, OWS=13, IP=7, PV=7.
- `Sources`: 17 rows.
- `Hindu_Words`: 270 non-empty rows.
- `Demanded_Practice`: 50 rows.
- `Recall_Check`: currently no data rows.

## Learning model parity

### Attempts are durable truth

`Performance` is not optional historical analytics. Current `LearningIntelligence.gs` reconstructs learning profiles from it. Therefore V2 must retain the event history and use `english.question_state` as a materialized/current representation.

The V2 submit path must be transactional:

1. Validate authenticated user and question.
2. Enforce idempotency using the client attempt/submission key.
3. Insert the attempt event.
4. Update/recompute current question state.
5. Update session position/current Daily state when applicable.
6. Apply Star/Difficult/Mastered changes requested with the submission.
7. Commit once; otherwise roll back all changes.

There must never be a state in which an attempt is durable but its required current-state transition silently failed.

### Learning states and due clock

Preserve the current profile states and intervals until parity testing explicitly approves a change:

- New
- Learning
- Weak
- Persistent Weak
- Fragile
- Strong
- Proven Mastered

Existing proven mastery and due-date calculations in `LearningIntelligence.gs` remain the reference behavior.

## Daily parity

`DailyAdaptive.gs` is the reference implementation during V2 migration.

Required behavior:

- Persisted Daily is a candidate/history list, not independent learning truth.
- A pending previous-day Daily may remain actionable until its valid pending material is exhausted.
- Persisted rows are revalidated against the batch-date/due-clock rules; stale non-due Strong/Proven Mastered rows must not re-enter merely because a later midnight makes them due.
- Starred or Difficult status may boost material that is otherwise eligible/due but may not independently make non-due content eligible.
- Controlled New remains valid for genuinely unattempted bank questions.
- Daily target remains a maximum; do not manufacture replacement questions simply to restore the target.
- Current Daily sequence must survive reload/resume.

## My Saved / lexical type parity

User-facing capture choices remain:

`Auto | V | SM | OWS | PV | I/P`

Internal resolved type additionally supports `CU` (Concept / Usage).

Rules:

- Explicit V/SM/OWS/PV/IP selection is authoritative.
- Auto may resolve internally to V, SM, OWS, PV, IP or CU.
- CU must never be silently collapsed to Vocabulary.
- Promotion/reconciliation from a Ready saved item into a permanent central question must be idempotent.
- Existing saved-item `Practice_Question_ID` links must be retained where valid.

## Starred / Difficult / Mastered parity

- Current Star state is reconstructed from the latest Star/Unstar event where event history exists.
- Difficult is independent current state and remains independently queryable.
- Explicit/manual mastery intent is durable history; V2 must not infer that a historical manual mastery event never happened merely because a current row was restored.
- Current practice universes exclude inactive/mastered items in the same situations as the Apps Script implementation.

## Practice hub parity

### New Practice

Reference: `NewPracticeLive.gs`.

Preserve type/source classification, active/non-mastered filtering, weak/new/starred/random modes, recent-content ordering and the distinction between My Saved, The Hindu, handwritten and other source groups.

### Topic Practice

Reference: `TopicPractice.gs`.

Preserve category mapping and `weak`, `started`, `new`, `random`, `all` modes.

### Source Practice

Reference: `SourcePractice.gs`.

Preserve source grouping, recent-content cutoff behavior, The Hindu date children, weak/recent/starred/started prioritization and active/non-mastered filtering.

### Demand Sets

Reference: `Demand.gs`.

Normalize memberships into `practice_sets` + `practice_set_items`; retain source sequence. `weak` and `random` behavior must continue to use current learning-state evidence.

### Hindu

Hindu practice is intentionally repeatable. Completion marks first pass but does not remove the day's words from subsequent rounds. V2 must preserve first/last practice timestamps and attempt-history based round counts.

### Phrasal mastery

Reference: `PhrasalMastery.gs`.

Preserve concept grouping, recognition/recall/confusion families, difficult/starred influence, fresh variants, coverage rotation and central Proven Mastered semantics.

## API boundary for V2

The browser must not write arbitrary application tables with elevated credentials. Public client code uses the Supabase publishable key and the authenticated user's session. RLS remains enabled.

Prefer a small explicit server/RPC surface for mutations:

- `start_daily`
- `resume_daily`
- `submit_answer`
- `set_starred`
- `set_difficult`
- `set_mastered`
- `save_word`
- `set_saved_item_type`
- `promote_saved_item`
- `start_practice_session`

Read models may use authenticated views/RPCs for dashboard counts and practice hubs so the browser never downloads the full question/state tables to calculate them.

## Frontend migration rule

Do not rewrite V2 as a line-for-line port of Apps Script. Port behavior behind tests, then build a new Next.js UI against the tested API boundary.

Expected routes:

- `/english`
- `/english/daily`
- `/english/new`
- `/english/saved`
- `/english/starred`
- `/english/topic/[category]`
- `/english/source/[source]`
- `/english/demand/[set]`
- `/english/hindu`
- `/english/phrasal`

Question navigation should preload the session batch so Previous/Next is local and immediate; writes remain durable and idempotent.

## Cutover gates

No production cutover until all of the following pass:

1. Supplemental behavior data imported and reconciled.
2. No unexplained missing or duplicate attempt IDs.
3. No production FK orphans; removed historical references accounted for in migration evidence.
4. Daily selection parity fixtures pass against the current Apps Script behavior.
5. Learning-state/due-date parity fixtures pass.
6. My Saved type/promotion fixtures pass, including Auto→CU.
7. Star/Difficult/Mastered latest-state fixtures pass.
8. Demand/Hindu/Phrasal/New/Source/Topic practice fixtures pass.
9. RLS tests prove one user cannot read/write another user's state.
10. Browser E2E verifies answer → Previous → Star → reload/resume persistence and the other critical interaction flows.

Until those gates pass, the existing Apps Script English app and Google Sheet remain the production source/runtime and rollback path.

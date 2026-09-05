# English V2 AI architecture stabilization — Stage 1 audit bundle

Branch: `english-ai-architecture-stabilization-stage1-20260905`
Starting `main`: `34779f1c5cf61554e2d2460ca90f9dac7a787396`

## Production reconciliation

Read-only Supabase inspection found three live ledger entries absent from the repository
mirror: `20260904192910 english_dedicated_revision_worker_schedule`,
`20260904193012 english_phrasal_maintenance_and_ai_budgets`, and
`20260904193504 english_dedicated_revision_claim`. It also found a live active
`english-revision-worker` (v2, SHA `179318e5…`) absent from Git. The worker source has
been recovered into `supabase/functions/english-revision-worker/index.ts`; the ledger
and equivalence status are recorded in the migration manifest. Exact SQL text for the
three historical live migrations is not exposed by the connected Supabase migration API,
so it is explicitly marked as remaining historic drift rather than fabricated.

## Ownership and lifecycle

| Worker | Owns | Protection |
|---|---|---|
| `english-concept-semantic` | embeddings and mappings | existing content-version guard |
| `english-context-worker` | learner-context diagnosis and bank-first transfer fallback | bounded claims/retries |
| `english-revision-worker` | revision proposals, critic and doubtful-answer review | dedicated claim, critic gate, stale/superseded guard |

The Stage 1 migration adds explicit error codes, model/prompt/input metadata fields,
lease metadata and an idempotency key to revision proposals. Physical `queued` with a
future `next_attempt_at` remains the compatible `retry_wait` representation. Error
classification distinguishes `AI_TIMEOUT`, `RATE_LIMIT`, `PROVIDER_5XX`,
`NETWORK_TRANSIENT`, `MALFORMED_OUTPUT`, `QUALITY_REJECTED`, `STALE_INPUT`,
`AUTH_CONFIG`, and `RETRIES_EXHAUSTED`.

## Learner-visible result delivery

The revision UI now states whether a proposal is queued/processing, quality-rejected,
superseded, retry-exhausted, or affected by a system failure. It never describes a
timeout/transient failure as a quality rejection.

## CI and validation

- English CI now runs for pushes to `main` and PRs, and watches all three English worker paths.
- Repo-side ownership/lifecycle drift contract: PASS.
- `git diff --check`: PASS.
- TypeScript/build/full PostgreSQL contract suite: not executed locally because this checkout has no `node_modules` and no `psql`; CI is configured to run them on the branch.

## Deliberately untouched

No production deploy, no live SQL mutation, no Maths or GK source change, no learner-data rewrite,
and no Phrasal/Hindu/Daily behavior change were performed in this Stage 1 commit.

## Remaining review item

Before production application, export the exact text of the three live historical migrations
from the project administration ledger and replace the manifest-only entries with faithful files.
This is a reproducibility gap, not an inferred SQL replacement.

Production was **NOT deployed**.

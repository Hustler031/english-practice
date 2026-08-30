# English V2 quiz session classification

This audit documents the runtime contract used by the fresh-session reliability change.

| Module / lane | Classification | Runtime policy |
| --- | --- | --- |
| Daily | Fixed / persisted session | Resume current Daily exactly; no fresh-session rotation |
| Central Revision (Due / Weak / Recall / Difficult / Smart-equivalent RPC modes) | Fresh adaptive | Live current-state selection; previous-session hard cooldown; soft least-recent rotation; fallback only when needed |
| Difficult | Fresh adaptive | Live current-state selection with Difficult intelligence preserved |
| My Saved Smart / Weak / Difficult / Starred / Random / All | Fresh adaptive | Live current-state selection with Saved intelligence preserved |
| My Saved New | Strict unseen | Never Revised only; no seen/served backfill |
| My Saved History / fixed day | History / fixed | Existing historical-day batch unchanged |
| New Practice All / Weak / Random / Starred | Fresh adaptive | Live current-state selection |
| New Practice New / New Words | Strict unseen | Attempted/served items do not backfill requested count |
| Topic Practice All / Weak / Random / etc. | Fresh adaptive | Live current-state selection |
| Topic Practice New | Strict unseen | No seen/served backfill |
| Sources / PDFs Practice All / Weak / Random / Starred | Fresh adaptive | One grouped-source live session; server-side dedupe before exposure recording |
| Sources / PDFs Practice New | Strict unseen | One grouped-source unseen session; no seen/served backfill |
| Starred Revision | Fresh adaptive | Existing Starred intelligence preserved inside freshness buckets |
| Phrasal Smart / Weak / Difficult / Starred / Random / All | Fresh adaptive | Existing one-concept/variant intelligence preserved; final Question_ID dedupe enforced |
| Phrasal Today | Fixed / intentional repeat | Existing permanent Today batch unchanged |
| Phrasal History | History / intentional repeat | Existing permanent history batch unchanged |
| Extra Practice | Fresh adaptive | Dedicated `extra` lane; no Revision-key fallback |
| Bank Coverage Unseen | Strict unseen | Genuinely unseen only; may return fewer than requested |
| Bank Coverage Seen Practice | Intentional review/repeat | Existing seen-practice semantics unchanged; live read, no freshness exclusion |
| Bank Coverage Today Review (All Again / Wrong / Difficult) | Intentional review/repeat | Existing same-day review semantics unchanged |
| Demanded Practice Weak / Random | Fresh adaptive | Live current-state rotation |
| Demanded Practice Practice All / Resume | Fixed / deterministic | Existing deterministic set and resume index unchanged |
| The Hindu Today / rounds | Fixed / intentional repeat | Existing today set and round repetition unchanged |

The generic 12-hour cache remains available for informational reads such as home/hub/progress/history/library/source metadata, but fresh-session RPCs are explicitly excluded from that cache policy.

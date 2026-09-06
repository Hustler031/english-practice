# Hindu sheet ingest overflow contract

- Scheduled ChatGPT proposes 25-30 fully generated/enriched current-news items.
- Backend rejects only structural failures, exact/family history collisions, or independent critic failures.
- Every backend-approved item is accepted.
- Up to the remaining 20 daily Hindu slots are published, highest critic score first.
- Backend-approved items beyond the daily display capacity are stored as `accepted_retained` in `english.hindu_candidate_backlog`; they are not rejected for capacity.
- The Sheet/queue response reports `accepted`, `published`, `retained`, `rejected`, and per-item decisions separately.

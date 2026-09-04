# English V2 P1/P2 Reliability Audit Closure

This change set closes the confirmed audit findings without redesigning English V2 or touching Maths/GK internals.

## P1

- Targeted / Next Best Action exact-question cooldown and fresh-session delivery.
- Durable answer-outbox handoff before a new Targeted set; pending IDs remain hard exclusions.
- Live Targeted mastery/summary reads so 12-hour cache cannot keep due counts stale.
- Hindu vocabulary remains exposure-only for Daily until explicitly retained (Marked or Saved Vocab).
- Context worker scheduling covers Transfer, Revision and Quality Review fairly, with bounded stale recovery and HTTP failure telemetry.

## P2

- Backfills missing Fixed Preposition explanations without overwriting existing valid explanations.
- Expires stale quiz-session records while preserving attempts/history.
- Gives Sprint generation jobs terminal completed/abandoned lifecycle states and reconciles stale claimed jobs.
- Revokes anonymous execution on the audited SECURITY DEFINER RPCs.
- Applies RLS init-plan and targeted FK/index hardening.

## Validation intent

The existing English V2 interaction-cooldown contract now includes P1/P2 assertions. The PR workflow also runs TypeScript/build, English contracts, shared GK contracts, and Maths boundary checks.

-- Reconcile historical Starred provenance into the route event ledger.
-- Bootstrap can attach `From Starred` as one of several origins while its single BOOTSTRAP
-- event uses another primary origin (for example Historical Clean Bank or From My Saved).
-- The Starred UI's lifetime "Moved" counters are event-backed, so add idempotent provenance
-- events for any route state that demonstrably entered Fast Track / Targeted from Starred history.

insert into english.learning_route_events(
  user_id,question_id,event_at,event_type,from_route,to_route,origin,reason,event_key,metadata
)
select
  r.user_id,r.question_id,coalesce(r.entered_fast_track_at,now()),'PROVENANCE_RECONCILE',null,'fast_track','From Starred',
  'Historical Starred provenance reconciled to Fast Track',
  'starred-origin-reconcile:'||r.user_id::text||':'||r.question_id||':fast-track',
  jsonb_build_object('source','learning_route_state')
from english.learning_route_state r
where 'From Starred'=any(coalesce(r.origins,'{}'::text[]))
  and r.entered_fast_track_at is not null
on conflict(event_key) do nothing;

insert into english.learning_route_events(
  user_id,question_id,event_at,event_type,from_route,to_route,origin,reason,event_key,metadata
)
select
  r.user_id,r.question_id,coalesce(r.targeted_at,now()),'PROVENANCE_RECONCILE',null,'targeted','From Starred',
  'Historical Starred provenance reconciled to Targeted',
  'starred-origin-reconcile:'||r.user_id::text||':'||r.question_id||':targeted',
  jsonb_build_object('source','learning_route_state')
from english.learning_route_state r
where 'From Starred'=any(coalesce(r.origins,'{}'::text[]))
  and r.targeted_at is not null
on conflict(event_key) do nothing;

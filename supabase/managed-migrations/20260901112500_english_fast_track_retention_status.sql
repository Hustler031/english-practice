-- Allow the Fast Track lane to own a non-terminal Retention Watch phase.
alter table english.learning_route_state
  drop constraint if exists learning_route_state_fast_track_status_check;
alter table english.learning_route_state
  add constraint learning_route_state_fast_track_status_check
  check (fast_track_status is null or fast_track_status in ('ready','waiting','retention_watch','mastered'));

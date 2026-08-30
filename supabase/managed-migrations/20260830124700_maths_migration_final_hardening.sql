alter table maths.practice_sets alter column user_id set not null;

create index if not exists maths_attempts_user_question_attempted_idx on maths.attempts(user_id, question_id, attempted_at desc);
create index if not exists maths_exposures_user_question_seen_idx on maths.exposures(user_id, question_id, seen_at desc);
create index if not exists maths_question_state_user_last_attempt_idx on maths.question_state(user_id, last_attempt desc);
create index if not exists maths_sessions_user_updated_idx on maths.sessions(user_id, updated_at desc);
create index if not exists maths_concept_membership_user_active_idx on maths.concept_membership(user_id, active, question_id);
create index if not exists maths_star_events_user_event_idx on maths.star_events(user_id, event_at desc);
create index if not exists maths_practice_sets_user_created_idx on maths.practice_sets(user_id, created_at desc);



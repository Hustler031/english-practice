-- A generated-but-not-yet-started Sprint is still the learner's single active Sprint.
drop index if exists english.english_sprint_one_active_per_user_idx;
create unique index english_sprint_one_active_per_user_idx
  on english.sprint_sessions(user_id)
  where status in ('ready','in_progress','paused');

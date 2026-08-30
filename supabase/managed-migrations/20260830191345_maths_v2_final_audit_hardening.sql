
-- Maths V2 final audit hardening: security, RLS planner efficiency and
-- two runtime foreign-key lookup paths. No learner/content rows are changed.

alter function maths._norm(text)
  set search_path = pg_catalog, public, maths;
alter function maths._chapter_group(text)
  set search_path = pg_catalog, public, maths;
alter function maths._major_topic(text, text, text, text)
  set search_path = pg_catalog, public, maths;
alter function maths._calc_type(maths.runtime_questions)
  set search_path = pg_catalog, public, maths;
alter function maths._calc_recall_eligible(maths.runtime_questions)
  set search_path = pg_catalog, public, maths;
alter function maths._migrate_ts(text)
  set search_path = pg_catalog, public, maths;

revoke execute on function maths._norm(text) from public, anon, authenticated;
revoke execute on function maths._chapter_group(text) from public, anon, authenticated;
revoke execute on function maths._major_topic(text, text, text, text) from public, anon, authenticated;
revoke execute on function maths._calc_type(maths.runtime_questions) from public, anon, authenticated;
revoke execute on function maths._calc_recall_eligible(maths.runtime_questions) from public, anon, authenticated;
revoke execute on function maths._migrate_ts(text) from public, anon, authenticated;

drop policy if exists maths_attempts_own on maths.attempts;
create policy maths_attempts_own on maths.attempts
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_concept_membership_own on maths.concept_membership;
create policy maths_concept_membership_own on maths.concept_membership
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_exposures_own on maths.exposures;
create policy maths_exposures_own on maths.exposures
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_practice_sets_own on maths.practice_sets;
create policy maths_practice_sets_own on maths.practice_sets
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_question_state_own on maths.question_state;
create policy maths_question_state_own on maths.question_state
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_sessions_own on maths.sessions;
create policy maths_sessions_own on maths.sessions
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_star_events_own on maths.star_events;
create policy maths_star_events_own on maths.star_events
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists maths_practice_set_items_own on maths.practice_set_items;
create policy maths_practice_set_items_own on maths.practice_set_items
  for all to authenticated
  using (exists (
    select 1 from maths.practice_sets s
    where s.set_id = practice_set_items.set_id
      and s.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from maths.practice_sets s
    where s.set_id = practice_set_items.set_id
      and s.user_id = (select auth.uid())
  ));

drop policy if exists maths_session_questions_own on maths.session_questions;
create policy maths_session_questions_own on maths.session_questions
  for all to authenticated
  using (exists (
    select 1 from maths.sessions s
    where s.session_id = session_questions.session_id
      and s.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from maths.sessions s
    where s.session_id = session_questions.session_id
      and s.user_id = (select auth.uid())
  ));

drop index if exists maths.maths_attempts_user_question_time_idx;
create index if not exists maths_attempts_question_idx
  on maths.attempts(question_id);
create index if not exists maths_session_questions_question_idx
  on maths.session_questions(question_id);


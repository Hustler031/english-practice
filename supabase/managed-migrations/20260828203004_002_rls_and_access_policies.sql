-- Lock down migration evidence completely.
alter table legacy.import_batches enable row level security;
alter table legacy.sheet_rows enable row level security;
alter table legacy.reconciliation_runs enable row level security;
revoke all on schema legacy from anon, authenticated;
revoke all on all tables in schema legacy from anon, authenticated;

-- App schemas are authenticated-only. Anonymous users get no direct DB access.
revoke all on schema english from anon;
revoke all on schema gk from anon;
revoke all on schema maths from anon;
grant usage on schema english, gk, maths to authenticated;

-- Enable RLS on every application table.
alter table english.questions enable row level security;
alter table english.question_state enable row level security;
alter table english.attempts enable row level security;
alter table english.daily_history enable row level security;
alter table english.saved_items enable row level security;
alter table english.sources enable row level security;
alter table english.practice_sets enable row level security;
alter table english.practice_set_items enable row level security;

alter table gk.questions enable row level security;
alter table gk.question_state enable row level security;
alter table gk.attempts enable row level security;
alter table gk.sessions enable row level security;
alter table gk.session_questions enable row level security;
alter table gk.exposures enable row level security;
alter table gk.lectures enable row level security;
alter table gk.user_notes enable row level security;
alter table gk.flags enable row level security;

alter table maths.questions enable row level security;
alter table maths.question_state enable row level security;
alter table maths.attempts enable row level security;
alter table maths.sessions enable row level security;
alter table maths.session_questions enable row level security;
alter table maths.concept_membership enable row level security;
alter table maths.practice_sets enable row level security;
alter table maths.practice_set_items enable row level security;
alter table maths.star_events enable row level security;

-- Explicit grants. RLS remains the row-level enforcement boundary.
grant select on english.questions, english.sources, english.practice_sets, english.practice_set_items to authenticated;
grant select, insert, update, delete on english.question_state, english.attempts, english.daily_history, english.saved_items to authenticated;
grant usage, select on all sequences in schema english to authenticated;

grant select on gk.questions, gk.lectures to authenticated;
grant select, insert, update, delete on gk.question_state, gk.attempts, gk.sessions, gk.session_questions, gk.exposures, gk.user_notes, gk.flags to authenticated;
grant usage, select on all sequences in schema gk to authenticated;

grant select on maths.questions, maths.concept_membership, maths.practice_sets, maths.practice_set_items to authenticated;
grant select, insert, update, delete on maths.question_state, maths.attempts, maths.sessions, maths.session_questions, maths.star_events to authenticated;
grant usage, select on all sequences in schema maths to authenticated;

-- Content is readable only after authentication.
drop policy if exists english_questions_authenticated_read on english.questions;
create policy english_questions_authenticated_read on english.questions for select to authenticated using (true);
drop policy if exists english_sources_authenticated_read on english.sources;
create policy english_sources_authenticated_read on english.sources for select to authenticated using (true);
drop policy if exists english_practice_sets_authenticated_read on english.practice_sets;
create policy english_practice_sets_authenticated_read on english.practice_sets for select to authenticated using (true);
drop policy if exists english_practice_set_items_authenticated_read on english.practice_set_items;
create policy english_practice_set_items_authenticated_read on english.practice_set_items for select to authenticated using (true);

-- User-owned English data.
drop policy if exists english_question_state_own on english.question_state;
create policy english_question_state_own on english.question_state for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists english_attempts_own on english.attempts;
create policy english_attempts_own on english.attempts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists english_daily_history_own on english.daily_history;
create policy english_daily_history_own on english.daily_history for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists english_saved_items_own on english.saved_items;
create policy english_saved_items_own on english.saved_items for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- GK shared content.
drop policy if exists gk_questions_authenticated_read on gk.questions;
create policy gk_questions_authenticated_read on gk.questions for select to authenticated using (true);
drop policy if exists gk_lectures_authenticated_read on gk.lectures;
create policy gk_lectures_authenticated_read on gk.lectures for select to authenticated using (true);

-- GK user-owned tables.
drop policy if exists gk_question_state_own on gk.question_state;
create policy gk_question_state_own on gk.question_state for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists gk_attempts_own on gk.attempts;
create policy gk_attempts_own on gk.attempts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists gk_sessions_own on gk.sessions;
create policy gk_sessions_own on gk.sessions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists gk_exposures_own on gk.exposures;
create policy gk_exposures_own on gk.exposures for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists gk_user_notes_own on gk.user_notes;
create policy gk_user_notes_own on gk.user_notes for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists gk_flags_own on gk.flags;
create policy gk_flags_own on gk.flags for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists gk_session_questions_own on gk.session_questions;
create policy gk_session_questions_own on gk.session_questions for all to authenticated
using (exists (select 1 from gk.sessions s where s.session_id = session_questions.session_id and s.user_id = auth.uid()))
with check (exists (select 1 from gk.sessions s where s.session_id = session_questions.session_id and s.user_id = auth.uid()));

-- Maths shared content.
drop policy if exists maths_questions_authenticated_read on maths.questions;
create policy maths_questions_authenticated_read on maths.questions for select to authenticated using (true);
drop policy if exists maths_concept_membership_authenticated_read on maths.concept_membership;
create policy maths_concept_membership_authenticated_read on maths.concept_membership for select to authenticated using (true);
drop policy if exists maths_practice_sets_authenticated_read on maths.practice_sets;
create policy maths_practice_sets_authenticated_read on maths.practice_sets for select to authenticated using (true);
drop policy if exists maths_practice_set_items_authenticated_read on maths.practice_set_items;
create policy maths_practice_set_items_authenticated_read on maths.practice_set_items for select to authenticated using (true);

-- Maths user-owned tables.
drop policy if exists maths_question_state_own on maths.question_state;
create policy maths_question_state_own on maths.question_state for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists maths_attempts_own on maths.attempts;
create policy maths_attempts_own on maths.attempts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists maths_sessions_own on maths.sessions;
create policy maths_sessions_own on maths.sessions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists maths_star_events_own on maths.star_events;
create policy maths_star_events_own on maths.star_events for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists maths_session_questions_own on maths.session_questions;
create policy maths_session_questions_own on maths.session_questions for all to authenticated
using (exists (select 1 from maths.sessions s where s.session_id = session_questions.session_id and s.user_id = auth.uid()))
with check (exists (select 1 from maths.sessions s where s.session_id = session_questions.session_id and s.user_id = auth.uid()));
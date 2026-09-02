-- Owner-scope every private generated question origin for authenticated reads.
drop policy if exists english_question_origins_authenticated_read on english.question_origins;
create policy english_question_origins_authenticated_read
on english.question_origins
for select
to authenticated
using (
  origin_kind not in ('saved_generated','targeted_generated')
  or owner_user_id = (select auth.uid())
);

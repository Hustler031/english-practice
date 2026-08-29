create index if not exists english_practice_set_state_set_id_idx on english.practice_set_state(set_id);
create index if not exists english_practice_sets_owner_user_id_idx on english.practice_sets(owner_user_id);

alter policy english_attempts_select_own on english.attempts using (user_id = (select auth.uid()));
alter policy english_daily_current_select_own on english.daily_current using (user_id = (select auth.uid()));
alter policy english_daily_history_select_own on english.daily_history using (user_id = (select auth.uid()));
alter policy english_difficult_state_select_own on english.difficult_state using (user_id = (select auth.uid()));
alter policy english_hindu_vocab_registry_select_own on english.hindu_vocab_registry using (user_id = (select auth.uid()));
alter policy english_mastery_events_select_own on english.mastery_events using (user_id = (select auth.uid()));
alter policy english_practice_set_state_select_own on english.practice_set_state using (user_id = (select auth.uid()));
alter policy english_question_state_select_own on english.question_state using (user_id = (select auth.uid()));
alter policy english_saved_item_types_select_own on english.saved_item_types using (user_id = (select auth.uid()));
alter policy english_saved_items_select_own on english.saved_items using (user_id = (select auth.uid()));
alter policy english_star_events_select_own on english.star_events using (user_id = (select auth.uid()));
alter policy english_question_origins_authenticated_read on english.question_origins using ((origin_kind <> 'saved_generated'::text) or (owner_user_id = (select auth.uid())));

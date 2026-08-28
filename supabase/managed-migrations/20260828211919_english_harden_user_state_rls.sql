drop policy if exists english_attempts_own on english.attempts;
create policy english_attempts_select_own on english.attempts for select to authenticated using(user_id=auth.uid());

drop policy if exists english_daily_current_own on english.daily_current;
create policy english_daily_current_select_own on english.daily_current for select to authenticated using(user_id=auth.uid());

drop policy if exists english_daily_history_own on english.daily_history;
create policy english_daily_history_select_own on english.daily_history for select to authenticated using(user_id=auth.uid());

drop policy if exists english_difficult_state_own on english.difficult_state;
create policy english_difficult_state_select_own on english.difficult_state for select to authenticated using(user_id=auth.uid());

drop policy if exists english_hindu_vocab_registry_own on english.hindu_vocab_registry;
create policy english_hindu_vocab_registry_select_own on english.hindu_vocab_registry for select to authenticated using(user_id=auth.uid());

drop policy if exists english_mastery_events_own on english.mastery_events;
create policy english_mastery_events_select_own on english.mastery_events for select to authenticated using(user_id=auth.uid());

drop policy if exists english_question_state_own on english.question_state;
create policy english_question_state_select_own on english.question_state for select to authenticated using(user_id=auth.uid());

drop policy if exists english_saved_item_types_own on english.saved_item_types;
create policy english_saved_item_types_select_own on english.saved_item_types for select to authenticated using(user_id=auth.uid());

drop policy if exists english_saved_items_own on english.saved_items;
create policy english_saved_items_select_own on english.saved_items for select to authenticated using(user_id=auth.uid());

drop policy if exists english_star_events_own on english.star_events;
create policy english_star_events_select_own on english.star_events for select to authenticated using(user_id=auth.uid());

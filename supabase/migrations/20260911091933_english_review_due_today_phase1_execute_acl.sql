revoke execute on function english.review_due_concept_key(text) from public;
revoke execute on function english.review_due_module_qualifies(text) from public;
revoke execute on function english.capture_review_due_day(uuid,date) from public;
revoke execute on function english.capture_review_due_today_all_users() from public;
revoke execute on function public.english_get_review_due_today() from public;
grant execute on function public.english_get_review_due_today() to authenticated;

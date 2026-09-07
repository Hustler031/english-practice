-- Sprint state is a signed-in learner read. Keep this SECURITY DEFINER RPC
-- unavailable to anonymous callers; its result is scoped by auth.uid().
revoke all on function public.english_get_chatgpt_sprint_state() from public;
revoke execute on function public.english_get_chatgpt_sprint_state() from anon;
grant execute on function public.english_get_chatgpt_sprint_state() to authenticated;
grant execute on function public.english_get_chatgpt_sprint_state() to service_role;

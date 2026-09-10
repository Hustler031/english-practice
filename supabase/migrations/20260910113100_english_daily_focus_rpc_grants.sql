-- Public-schema RPCs are authenticated-only. SECURITY DEFINER still validates auth.uid().
revoke all on function public.english_get_daily_focus_summary() from public;
revoke all on function public.english_get_daily_focus_summary() from anon;
revoke all on function public.english_get_daily_focus_lane(text) from public;
revoke all on function public.english_get_daily_focus_lane(text) from anon;

grant execute on function public.english_get_daily_focus_summary() to authenticated;
grant execute on function public.english_get_daily_focus_lane(text) to authenticated;

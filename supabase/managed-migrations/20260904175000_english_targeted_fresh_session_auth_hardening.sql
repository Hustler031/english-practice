-- The Targeted fresh-session gateway is a learner-authenticated API only.
-- It already binds all reads/writes to auth.uid(); remove the unnecessary
-- anonymous EXECUTE grant so the exposed SECURITY DEFINER surface is explicit.

revoke execute on function public.english_start_targeted_fresh_session(
  integer,text,uuid,text,text[],boolean
) from public,anon;

grant execute on function public.english_start_targeted_fresh_session(
  integer,text,uuid,text,text[],boolean
) to authenticated;

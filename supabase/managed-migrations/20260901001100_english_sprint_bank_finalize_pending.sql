-- Recovery path for a completed Sprint whose user-selected Bank marks were saved before completion.
create or replace function public.english_finalize_completed_sprint_bank_marks()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); r record; qid text; n integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  for r in
    select b.source_session_id,b.source_position
    from english.sprint_bank_items b
    join english.sprint_sessions s on s.session_id=b.source_session_id and s.user_id=b.user_id
    where b.user_id=uid and b.question_id is null and s.status='completed'
    order by s.completed_at,b.source_position
  loop
    qid:=english.promote_sprint_bank_item(uid,r.source_session_id,r.source_position);
    if qid is not null then n:=n+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'promoted',n);
end $$;

revoke execute on function public.english_finalize_completed_sprint_bank_marks() from public,anon;
grant execute on function public.english_finalize_completed_sprint_bank_marks() to authenticated,service_role;

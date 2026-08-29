-- User-facing public pools that contain active canonical questions must respect owner visibility.
do $$
declare r record;d text;
begin
 for r in
  select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and p.proname like 'english_%'
    and p.proname<>'english_promote_saved_item' and pg_get_functiondef(p.oid) like '%q.active%'
 loop
  d:=pg_get_functiondef(r.oid);
  if d not like '%question_visible_to_user(auth.uid(),q.question_id)%' then
    d:=replace(d,'q.active','(q.active and english.question_visible_to_user(auth.uid(),q.question_id))');
    execute d;
  end if;
 end loop;
end $$;

-- Daily generation.
do $$ declare d text; begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='english' and p.proname='create_daily' and pg_get_function_identity_arguments(p.oid)='p_user_id uuid, p_batch_date date, p_target integer';
 if d is not null and d not like '%question_visible_to_user(p_user_id,q.question_id)%' then
   d:=replace(d,$x$where q.active and not coalesce(s.mastered,false)$x$,$x$where q.active and english.question_visible_to_user(p_user_id,q.question_id) and not coalesce(s.mastered,false)$x$);
   execute d;
 end if;
end $$;

-- Phrasal concept universe.
do $$ declare d text; begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='english' and p.proname='phrasal_concepts' and pg_get_function_identity_arguments(p.oid)='p_user_id uuid';
 if d is not null and d not like '%question_visible_to_user(p_user_id,q.question_id)%' then
   d:=replace(d,$x$where q.active and (english.canonical_category(q.topic)='PHRASAL'$x$,$x$where q.active and english.question_visible_to_user(p_user_id,q.question_id) and (english.canonical_category(q.topic)='PHRASAL'$x$);
   execute d;
 end if;
end $$;

-- Phrasal batch variant choice must not select another owner's generated variant.
do $$ declare d text; begin
 select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='english_get_phrasal_batch' and pg_get_function_identity_arguments(p.oid)='p_mode text, p_count integer';
 if d is not null and d not like '%question_visible_to_user(uid,q.question_id)%' then
   d:=replace(d,$x$where not coalesce(s.mastered,false)$x$,$x$where english.question_visible_to_user(uid,q.question_id) and not coalesce(s.mastered,false)$x$);
   execute d;
 end if;
end $$;

-- Generic mutation RPCs can only operate on visible questions.
do $$
declare r record;d text;
begin
 for r in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('english_submit_answer','english_set_starred','english_set_difficult','english_set_mastered')
 loop
  d:=pg_get_functiondef(r.oid);
  d:=replace(d,'where question_id=btrim(p_question_id);','where question_id=btrim(p_question_id) and english.question_visible_to_user(uid,question_id);');
  d:=replace(d,'where question_id=btrim(p_question_id) and active;','where question_id=btrim(p_question_id) and active and english.question_visible_to_user(uid,question_id);');
  execute d;
 end loop;
end $$;

-- Internal english-schema functions are implementation details, not browser RPCs.
do $$ declare r record; begin
 for r in select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='english' and p.prokind='f'
 loop
  execute format('revoke execute on function %I.%I(%s) from public,anon,authenticated',r.nspname,r.proname,r.args);
  execute format('grant execute on function %I.%I(%s) to service_role',r.nspname,r.proname,r.args);
 end loop;
end $$;
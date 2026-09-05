-- A protected attempted-but-now-ineligible row remains in daily_current by design.
-- Sequence allocation must therefore use the raw batch maximum, while capacity uses
-- only completed/actionable rows. Guarded source rewrite keeps the 09:45 selector intact.
do $patch$
declare
  vdef text;
  vnext text;
  vold text:=E'  select count(*),coalesce(max(d.sequence),0)\n  into v_count,v_sequence_base\n  from english.daily_current d\n  where d.user_id=p_user_id and d.quiz_date=p_batch_date\n    and (\n      lower(coalesce(d.status,'''') )=''completed''\n      or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>''''\n    );';
  -- pg_get_functiondef preserves the body text, but the compact coalesce expression in
  -- the source has no extra space before the closing parenthesis. Keep a second exact form.
  vold_exact text:=E'  select count(*),coalesce(max(d.sequence),0)\n  into v_count,v_sequence_base\n  from english.daily_current d\n  where d.user_id=p_user_id and d.quiz_date=p_batch_date\n    and (\n      lower(coalesce(d.status,''''))=''completed''\n      or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>''''\n    );';
  vnew text:=E'  select count(*) filter (where\n      lower(coalesce(d.status,''''))=''completed''\n      or english.daily_reason(p_user_id,d.question_id,p_batch_date)<>''''\n    ),coalesce(max(d.sequence),0)\n  into v_count,v_sequence_base\n  from english.daily_current d\n  where d.user_id=p_user_id and d.quiz_date=p_batch_date;';
begin
  select pg_get_functiondef(p.oid) into vdef
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english' and p.proname='create_daily_core_20260905'
  order by p.oid desc limit 1;
  if vdef is null then raise exception 'english.create_daily_core_20260905 is missing'; end if;
  if position('count(*) filter (where' in vdef)>0 then return; end if;
  vnext:=replace(vdef,vold_exact,vnew);
  if vnext=vdef then vnext:=replace(vdef,vold,vnew); end if;
  if vnext=vdef then raise exception 'Daily sequence allocator source changed; refusing blind patch'; end if;
  execute vnext;
end
$patch$;

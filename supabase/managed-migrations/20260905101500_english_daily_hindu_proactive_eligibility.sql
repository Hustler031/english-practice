-- Stage 1: Hindu/current-news questions are exposure-only until the learner explicitly
-- marks or keeps them in vocabulary. The existing daily_current trigger remains a final
-- write boundary; this patch prevents the selector from choosing an ineligible Hindu row
-- in the first place, so one exposure-only candidate cannot abort/short-fill a Daily build.

do $patch$
declare
  vdef text;
  vnext text;
  vneedle text:=E'    and r.reason<>''''\n    and not exists(';
  vrepl text:=E'    and r.reason<>''''\n    and english.hindu_daily_eligible(p_user_id,q.question_id)\n    and not exists(';
begin
  select pg_get_functiondef(p.oid) into vdef
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='english' and p.proname='create_daily_core_20260905'
  order by p.oid desc
  limit 1;

  if vdef is null then
    raise exception 'english.create_daily_core_20260905 is missing';
  end if;
  if position('english.hindu_daily_eligible(p_user_id,q.question_id)' in vdef)>0 then
    return;
  end if;

  vnext:=replace(vdef,vneedle,vrepl);
  if vnext=vdef then
    raise exception 'Daily candidate source changed; refusing blind Hindu eligibility patch';
  end if;
  execute vnext;
end
$patch$;

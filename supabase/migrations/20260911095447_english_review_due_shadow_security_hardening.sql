-- REVIEW DUE TODAY — SHADOW SECURITY HARDENING
-- Tightens already-active internal Review Due objects without changing routing.

create or replace function english.review_due_module_qualifies(p_module text)
returns boolean
language sql
immutable
set search_path to 'pg_catalog'
as $function$
select case
  when lower(btrim(coalesce(p_module,''))) in (
    'daily','dailyfocusrepair','fasttrack','bankcoverage',
    'grammardaily','phrasaldaily','phrasalrevision','targeted',
    'starredrevision','mysavedrevision','hindu','extra','difficult',
    'source','demand','weak','practice','revision','new','reviewduetoday'
  ) then true
  when lower(btrim(coalesce(p_module,''))) like 'grammardaily:%' then true
  when lower(btrim(coalesce(p_module,''))) like 'sprint_%' then true
  when lower(btrim(coalesce(p_module,''))) like 'sprint:%' then true
  else false
end;
$function$;

alter table english.review_due_day_runs enable row level security;
alter table english.review_due_obligations enable row level security;
alter table english.review_due_phase2_daily_mix_selections enable row level security;

revoke all on function english.review_due_module_qualifies(text) from public,anon,authenticated;
revoke all on english.review_due_day_runs from public,anon,authenticated;
revoke all on english.review_due_obligations from public,anon,authenticated;
revoke all on english.review_due_phase2_daily_mix_selections from public,anon,authenticated;

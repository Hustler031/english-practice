create or replace function public.english_get_home_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
with uid as (
  select auth.uid() id
), summary as (
  select public.english_dashboard_summary() value
), saved as (
  select
    count(*) filter (where not mastered)::int eligible,
    count(*) filter (where not mastered and due)::int due
  from uid
  cross join lateral english.saved_revision_candidates(uid.id)
), starred as (
  select
    count(*) filter (where starred and not mastered)::int focus,
    count(*) filter (where difficult and starred and not mastered)::int difficult
  from uid
  cross join lateral english.starred_manual_index(uid.id)
), bank as (
  select
    count(*)::int total,
    count(*) filter (where coalesce(s.attempts,0) > 0)::int exposed
  from uid
  join english.questions q on uid.id is not null and english.is_genuine_bank_question(q)
  left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id
), phrasal as (
  select count(*)::int today_count
  from uid
  join english.questions q on uid.id is not null
   and q.active
   and english.question_visible_to_user(uid.id,q.question_id)
   and q.source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD')
   and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
), hindu as (
  select coalesce(jsonb_agg(jsonb_build_object('id',h.hindu_id) order by h.hindu_id),'[]'::jsonb) rows
  from uid
  join english.hindu_words h on uid.id is not null
   and h.active
   and h.word_date=(now() at time zone 'Asia/Kolkata')::date
)
select case when uid.id is null then
  jsonb_build_object('ok',false,'error','Authentication required')
else
  jsonb_build_object(
    'ok',true,
    'studyDay',greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1),
    'summary',summary.value,
    'intelligence',jsonb_build_object(
      'daily',jsonb_build_object(
        'actionableRemaining',coalesce((summary.value->>'daily_remaining')::int,0),
        'suppressed',coalesce((summary.value->>'daily_suppressed')::int,0)
      ),
      'coreCoverage',jsonb_build_object(
        'percent',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end
      )
    ),
    'phrasal',jsonb_build_object(
      'today',jsonb_build_object('ready',phrasal.today_count>0,'count',phrasal.today_count),
      'stats',jsonb_build_object('due',0)
    ),
    'bank',jsonb_build_object(
      'total',bank.total,
      'exposed',bank.exposed,
      'coverage',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end
    ),
    'saved',jsonb_build_object(
      'stats',jsonb_build_object('saved',saved.eligible,'eligible',saved.eligible,'due',saved.due)
    ),
    'starred',jsonb_build_object(
      'stats',jsonb_build_object('focus',starred.focus,'manualDifficult',starred.difficult,'difficult',starred.difficult)
    ),
    'hindu',hindu.rows
  )
end
from uid cross join summary cross join saved cross join starred cross join bank cross join phrasal cross join hindu;
$$;

revoke all on function public.english_get_home_snapshot() from public, anon;
grant execute on function public.english_get_home_snapshot() to authenticated, service_role;

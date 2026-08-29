create or replace function english.question_visible(p_question_id text)
returns boolean language sql stable security definer
set search_path=pg_catalog,english,auth as $$
select case when auth.uid() is null then false else english.question_visible_to_user(auth.uid(),p_question_id) end;
$$;
revoke execute on function english.question_visible(text) from public,anon;
grant execute on function english.question_visible(text) to authenticated,service_role;

drop policy if exists english_questions_authenticated_read on english.questions;
create policy english_questions_authenticated_read on english.questions for select to authenticated
using (english.question_visible(question_id));

create or replace function english.enforce_practice_set_question_owner()
returns trigger language plpgsql security definer set search_path=pg_catalog,english,auth as $$
declare q_owner uuid; q_kind text; s_owner uuid;
begin
 select origin_kind,owner_user_id into q_kind,q_owner from english.question_origins where question_id=new.question_id;
 if q_kind='saved_generated' then
  select owner_user_id into s_owner from english.practice_sets where set_id=new.set_id;
  if s_owner is distinct from q_owner then raise exception 'Private generated question cannot enter a shared or foreign practice set'; end if;
 end if;
 return new;
end $$;
drop trigger if exists english_practice_set_question_owner_guard on english.practice_set_items;
create trigger english_practice_set_question_owner_guard before insert or update of set_id,question_id on english.practice_set_items for each row execute function english.enforce_practice_set_question_owner();
revoke execute on function english.enforce_practice_set_question_owner() from public,anon,authenticated;
grant execute on function english.enforce_practice_set_question_owner() to service_role;

create or replace function public.english_get_intelligence_health()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id),
profiles as (
 select qs.question_id,qs.attempts stored_attempts,qs.status stored_status,qs.next_review stored_next,qs.mastered,
        p.attempts calc_attempts,p.state calc_state,p.next_review calc_next
 from english.question_state qs cross join uid cross join lateral english.learning_profile(uid.id,qs.question_id) p
 where qs.user_id=uid.id
),pc as (
 select count(*)::int state_rows,
  count(*) filter(where stored_attempts<>calc_attempts)::int attempt_count_mismatch,
  count(*) filter(where stored_status is distinct from(case when mastered then 'Mastered' else calc_state end))::int derived_status_mismatch,
  count(*) filter(where stored_next is distinct from(case when mastered then null::timestamptz else calc_next end))::int next_review_mismatch
 from profiles
),latest_star as (
 select distinct on(e.question_id)e.question_id,(e.action='STAR') expected_starred from english.star_events e cross join uid where e.user_id=uid.id order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
),sc as (
 select count(*) filter(where qs.last_marked is distinct from ls.expected_starred)::int starred_state_mismatch from latest_star ls cross join uid join english.question_state qs on qs.user_id=uid.id and qs.question_id=ls.question_id
),d as (
 select count(*)::int stored,count(*) filter(where lower(coalesce(status,''))='completed')::int completed from english.daily_current cross join uid where user_id=uid.id
),cur as (
 select count(*) filter(where lower(coalesce(status,''))<>'completed')::int remaining from uid cross join lateral english.current_daily_items(uid.id)
),dm as (
 select count(*) filter(where cardinality(selection_signals)=0 or selection_snapshot='{}'::jsonb)::int missing_selection_metadata from english.daily_current cross join uid where user_id=uid.id
),integrity as (
 select
  (select count(*) from english.attempts a left join english.questions q on q.question_id=a.question_id cross join uid where a.user_id=uid.id and q.question_id is null)::int orphan_attempts,
  (select count(*) from english.question_state s left join english.questions q on q.question_id=s.question_id cross join uid where s.user_id=uid.id and q.question_id is null)::int orphan_state_rows,
  (select count(*) from(select attempt_id from english.attempts cross join uid where user_id=uid.id group by attempt_id having count(*)>1)z)::int duplicate_attempt_ids,
  (select count(*) from english.saved_items si cross join uid left join english.questions q on q.question_id=si.practice_question_id where si.user_id=uid.id and nullif(btrim(si.practice_question_id),'') is not null and q.question_id is null)::int invalid_saved_links,
  (select count(*) from english.difficult_state ds cross join uid join english.question_state qs on qs.user_id=uid.id and qs.question_id=ds.question_id where ds.user_id=uid.id and ds.difficult and qs.mastered)::int difficult_mastered_rows,
  (select count(*) from english.attempts a cross join uid where a.user_id=uid.id and not english.question_visible_to_user(uid.id,a.question_id))::int invisible_attempts,
  (select count(*) from english.question_state s cross join uid where s.user_id=uid.id and not english.question_visible_to_user(uid.id,s.question_id))::int invisible_state_rows,
  (select count(*) from english.daily_current dc cross join uid where dc.user_id=uid.id and not english.question_visible_to_user(uid.id,dc.question_id))::int invisible_daily_rows,
  (select count(*) from english.question_origins o where o.origin_kind='saved_generated' and o.owner_user_id is null)::int generated_without_owner,
  (select count(*) from english.practice_set_items i join english.question_origins o on o.question_id=i.question_id and o.origin_kind='saved_generated' join english.practice_sets ps on ps.set_id=i.set_id where ps.owner_user_id is distinct from o.owner_user_id)::int private_set_membership_violations
),counts as (
 select (select count(*) from english.questions q cross join uid where q.active and english.question_visible_to_user(uid.id,q.question_id))::int active_questions,
        (select count(*) from english.attempts cross join uid where user_id=uid.id)::int attempts
)
select case when(select id from uid)is null then jsonb_build_object('ok',false,'error','Authentication required') else
jsonb_build_object(
 'ok',(pc.attempt_count_mismatch=0 and pc.derived_status_mismatch=0 and pc.next_review_mismatch=0 and sc.starred_state_mismatch=0 and i.orphan_attempts=0 and i.orphan_state_rows=0 and i.duplicate_attempt_ids=0 and i.invalid_saved_links=0 and dm.missing_selection_metadata=0 and i.invisible_attempts=0 and i.invisible_state_rows=0 and i.invisible_daily_rows=0 and i.generated_without_owner=0 and i.private_set_membership_violations=0),
 'version',2,
 'counts',jsonb_build_object('activeQuestions',c.active_questions,'attempts',c.attempts,'stateRows',pc.state_rows),
 'learning',jsonb_build_object('attemptCountMismatch',pc.attempt_count_mismatch,'statusMismatch',pc.derived_status_mismatch,'nextReviewMismatch',pc.next_review_mismatch),
 'flags',jsonb_build_object('starredStateMismatch',sc.starred_state_mismatch,'difficultMasteredRows',i.difficult_mastered_rows),
 'integrity',jsonb_build_object('orphanAttempts',i.orphan_attempts,'orphanStateRows',i.orphan_state_rows,'duplicateAttemptIds',i.duplicate_attempt_ids,'invalidSavedLinks',i.invalid_saved_links,'invisibleAttempts',i.invisible_attempts,'invisibleStateRows',i.invisible_state_rows,'invisibleDailyRows',i.invisible_daily_rows,'generatedWithoutOwner',i.generated_without_owner,'privateSetMembershipViolations',i.private_set_membership_violations),
 'daily',jsonb_build_object('stored',d.stored,'completed',d.completed,'actionableRemaining',cur.remaining,'suppressed',greatest(0,d.stored-d.completed-cur.remaining),'missingSelectionMetadata',dm.missing_selection_metadata,'targetIsMaximum',true)
) end
from pc cross join sc cross join d cross join cur cross join dm cross join integrity i cross join counts c;
$$;
revoke execute on function public.english_get_intelligence_health() from public,anon;
grant execute on function public.english_get_intelligence_health() to authenticated,service_role;
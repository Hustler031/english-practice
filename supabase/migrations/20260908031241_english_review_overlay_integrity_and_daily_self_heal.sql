create or replace function english.active_review_override_due(p_user_id uuid,p_question_id text)
returns timestamptz
language sql
stable security definer
set search_path=pg_catalog,english,auth
as $$
with guess_due as (
  select min(g.created_at + interval '12 hours') due
  from english.learner_confidence_signals g
  where g.user_id=p_user_id and g.question_id=p_question_id
    and g.signal='guessed' and g.resolved_at is null
), context_due as (
  select min(coalesce(n.processed_at,n.created_at) + interval '12 hours') due
  from english.learner_context_notes n
  where n.user_id=p_user_id and n.question_id=p_question_id
    and (
      lower(coalesce(n.ai_status,'')) in ('pending','queued','processing')
      or exists(
        select 1 from english.learning_route_state r
        where r.user_id=p_user_id and r.question_id=p_question_id
          and r.route='targeted'
          and r.metadata->>'source_note_id'=n.note_id::text
      )
    )
)
select case
  when g.due is null then c.due
  when c.due is null then g.due
  else least(g.due,c.due)
end
from guess_due g cross join context_due c;
$$;

revoke all on function english.active_review_override_due(uuid,text) from public,anon,authenticated;

create or replace function english.sync_question_review_due(p_user_id uuid,p_question_id text)
returns timestamptz
language plpgsql
security definer
set search_path=pg_catalog,english,auth
as $$
declare
  p record;
  v_mastered boolean;
  v_override timestamptz;
  v_next timestamptz;
  v_today date:=(now() at time zone 'Asia/Kolkata')::date;
begin
  select mastered into v_mastered
  from english.question_state
  where user_id=p_user_id and question_id=p_question_id;
  if not found then return null; end if;

  select * into p from english.learning_profile(p_user_id,p_question_id);
  v_override:=english.active_review_override_due(p_user_id,p_question_id);
  v_next:=case
    when coalesce(v_mastered,false) then null
    when p.next_review is null then v_override
    when v_override is null then p.next_review
    else least(p.next_review,v_override)
  end;

  update english.question_state
  set next_review=v_next,updated_at=now()
  where user_id=p_user_id and question_id=p_question_id
    and next_review is distinct from v_next;

  if exists(
    select 1 from english.daily_current d
    where d.user_id=p_user_id and d.quiz_date=v_today and d.question_id=p_question_id
      and lower(coalesce(d.status,''))<>'completed'
  )
  and english.daily_reason(p_user_id,p_question_id,v_today)=''
  and not english.daily_satisfied_elsewhere(p_user_id,p_question_id,v_today)
  and not exists(
    select 1 from english.attempts a
    where a.user_id=p_user_id and a.question_id=p_question_id
      and (a.attempted_at at time zone 'Asia/Kolkata')::date>=v_today
  ) then
    perform english.repair_daily_shortfall(p_user_id,v_today,120);
  end if;

  return v_next;
end;
$$;

revoke all on function english.sync_question_review_due(uuid,text) from public,anon,authenticated;

create or replace function english.recompute_question_state(p_user_id uuid,p_question_id text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare
  p record; q english.questions%rowtype; old english.question_state%rowtype;
  v_marked boolean; v_mastered boolean; v_mastered_on timestamptz;
  v_repeat timestamptz; v_recall integer; v_status text; v_next timestamptz;
  v_override timestamptz;
begin
  select * into q from english.questions where question_id=p_question_id;
  if not found then raise exception 'Question not found'; end if;
  select * into p from english.learning_profile(p_user_id,p_question_id);
  select * into old from english.question_state where user_id=p_user_id and question_id=p_question_id;
  v_repeat:=old.repeat_suppressed_until;
  v_recall:=coalesce(old.recall_check_count,0);

  select case when se.action='STAR' then true else false end into v_marked
  from english.star_events se
  where se.user_id=p_user_id and se.question_id=p_question_id
  order by se.event_at desc,se.id desc limit 1;
  if not found then v_marked:=coalesce(old.last_marked,false); end if;

  select bool_or(me.active and me.restored_on is null),
         max(me.mastered_on) filter(where me.active and me.restored_on is null)
  into v_mastered,v_mastered_on
  from english.mastery_events me
  where me.user_id=p_user_id and me.question_id=p_question_id;
  v_mastered:=coalesce(v_mastered,coalesce(old.mastered,false));
  if v_mastered and v_mastered_on is null then v_mastered_on:=old.mastered_on; end if;
  if not v_mastered then v_mastered_on:=null; v_repeat:=null; end if;
  v_status:=case when v_mastered then 'Mastered' else p.state end;
  v_override:=english.active_review_override_due(p_user_id,p_question_id);
  v_next:=case
    when v_mastered then null
    when p.next_review is null then v_override
    when v_override is null then p.next_review
    else least(p.next_review,v_override)
  end;

  insert into english.question_state(
    user_id,question_id,attempts,correct,wrong,accuracy,marked_count,avg_time,
    last_attempt,last_result,last_time,last_marked,correct_streak,status,next_review,
    mastered,mastered_on,repeat_suppressed_until,recall_check_count,updated_at
  ) values(
    p_user_id,p_question_id,p.attempts,p.correct,p.wrong,p.accuracy,p.marked_count,p.avg_time,
    p.last_attempt,p.last_result,p.last_time,v_marked,p.correct_streak,v_status,v_next,
    v_mastered,v_mastered_on,v_repeat,v_recall,now()
  )
  on conflict(user_id,question_id) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,accuracy=excluded.accuracy,
    marked_count=excluded.marked_count,avg_time=excluded.avg_time,last_attempt=excluded.last_attempt,
    last_result=excluded.last_result,last_time=excluded.last_time,last_marked=excluded.last_marked,
    correct_streak=excluded.correct_streak,status=excluded.status,next_review=excluded.next_review,
    mastered=excluded.mastered,mastered_on=excluded.mastered_on,
    repeat_suppressed_until=excluded.repeat_suppressed_until,
    recall_check_count=excluded.recall_check_count,updated_at=excluded.updated_at;

  return jsonb_build_object('question_id',p_question_id,'attempts',p.attempts,'correct',p.correct,'wrong',p.wrong,
    'status',v_status,'next_review',v_next,'base_next_review',p.next_review,'review_override_due',v_override,
    'mastered',v_mastered,'starred',v_marked,'correct_streak',p.correct_streak);
end;
$$;

create or replace function english.review_due_signal_sync_trigger()
returns trigger
language plpgsql security definer
set search_path=pg_catalog,english
as $$
begin
  perform english.sync_question_review_due(new.user_id,new.question_id);
  return new;
end;
$$;
revoke all on function english.review_due_signal_sync_trigger() from public,anon,authenticated;

drop trigger if exists zz_english_guess_review_due_sync on english.learner_confidence_signals;
create trigger zz_english_guess_review_due_sync
after update of resolved_at on english.learner_confidence_signals
for each row
when (old.resolved_at is distinct from new.resolved_at)
execute function english.review_due_signal_sync_trigger();

drop trigger if exists zz_english_context_review_due_sync on english.learner_context_notes;
create trigger zz_english_context_review_due_sync
after update of ai_status,diagnosis on english.learner_context_notes
for each row
execute function english.review_due_signal_sync_trigger();

drop trigger if exists zz_english_route_review_due_sync on english.learning_route_state;
create trigger zz_english_route_review_due_sync
after insert or update of route,metadata on english.learning_route_state
for each row
execute function english.review_due_signal_sync_trigger();

create or replace function english.repair_daily_shortfall(p_user_id uuid,p_batch_date date,p_target integer default 120)
returns integer
language plpgsql security definer
set search_path=pg_catalog,english,auth
as $$
declare
  v_target integer:=greatest(1,least(120,coalesce(p_target,120)));
  v_before integer:=0;
  v_after integer:=0;
begin
  perform pg_advisory_xact_lock(hashtextextended('english.daily.'||p_user_id::text,0));
  select total into v_before from english.daily_effective_counts(p_user_id,p_batch_date,v_target);
  v_before:=coalesce(v_before,0);

  delete from english.daily_current d
  where d.user_id=p_user_id and d.quiz_date=p_batch_date
    and lower(coalesce(d.status,''))<>'completed'
    and english.daily_reason(p_user_id,d.question_id,p_batch_date)=''
    and not english.daily_satisfied_elsewhere(p_user_id,d.question_id,p_batch_date)
    and not exists(
      select 1 from english.attempts a
      where a.user_id=p_user_id and a.question_id=d.question_id
        and (a.attempted_at at time zone 'Asia/Kolkata')::date>=p_batch_date
    );

  perform english.create_daily_core_20260905(p_user_id,p_batch_date,v_target);
  perform english.rebalance_daily_targeted(p_user_id,p_batch_date,v_target);
  perform english.rebalance_daily_category_diversity(p_user_id,p_batch_date,v_target);

  update english.daily_current
  set sequence=sequence+1000
  where user_id=p_user_id and quiz_date=p_batch_date;
  with ranked as (
    select question_id,row_number() over(order by sequence,question_id)::int seq
    from english.daily_current
    where user_id=p_user_id and quiz_date=p_batch_date
  )
  update english.daily_current d
  set sequence=r.seq
  from ranked r
  where d.user_id=p_user_id and d.quiz_date=p_batch_date and d.question_id=r.question_id;

  select total into v_after from english.daily_effective_counts(p_user_id,p_batch_date,v_target);
  return greatest(0,coalesce(v_after,0)-v_before);
end;
$$;

create or replace function public.english_get_intelligence_health()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id),
profiles as (
 select qs.question_id,qs.attempts stored_attempts,qs.status stored_status,qs.next_review stored_next,qs.mastered,
        p.attempts calc_attempts,p.state calc_state,p.next_review calc_next,
        english.active_review_override_due(uid.id,qs.question_id) review_override
 from english.question_state qs cross join uid cross join lateral english.learning_profile(uid.id,qs.question_id) p
 where qs.user_id=uid.id
), expected as (
 select *,case
   when mastered then null::timestamptz
   when calc_next is null then review_override
   when review_override is null then calc_next
   else least(calc_next,review_override)
 end expected_next
 from profiles
),pc as (
 select count(*)::int state_rows,
  count(*) filter(where stored_attempts<>calc_attempts)::int attempt_count_mismatch,
  count(*) filter(where stored_status is distinct from(case when mastered then 'Mastered' else calc_state end))::int derived_status_mismatch,
  count(*) filter(where stored_next is distinct from expected_next)::int next_review_mismatch,
  count(*) filter(where review_override is not null and (calc_next is null or review_override<calc_next))::int intentional_review_overrides
 from expected
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
 'version',3,
 'counts',jsonb_build_object('activeQuestions',c.active_questions,'attempts',c.attempts,'stateRows',pc.state_rows),
 'learning',jsonb_build_object('attemptCountMismatch',pc.attempt_count_mismatch,'statusMismatch',pc.derived_status_mismatch,'nextReviewMismatch',pc.next_review_mismatch,'intentionalReviewOverrides',pc.intentional_review_overrides),
 'flags',jsonb_build_object('starredStateMismatch',sc.starred_state_mismatch,'difficultMasteredRows',i.difficult_mastered_rows),
 'integrity',jsonb_build_object('orphanAttempts',i.orphan_attempts,'orphanStateRows',i.orphan_state_rows,'duplicateAttemptIds',i.duplicate_attempt_ids,'invalidSavedLinks',i.invalid_saved_links,'invisibleAttempts',i.invisible_attempts,'invisibleStateRows',i.invisible_state_rows,'invisibleDailyRows',i.invisible_daily_rows,'generatedWithoutOwner',i.private_set_membership_violations),
 'daily',jsonb_build_object('stored',d.stored,'completed',d.completed,'actionableRemaining',cur.remaining,'suppressed',greatest(0,d.stored-d.completed-cur.remaining),'missingSelectionMetadata',dm.missing_selection_metadata,'targetIsMaximum',true)
) end
from pc cross join sc cross join d cross join cur cross join dm cross join integrity i cross join counts c;
$$;

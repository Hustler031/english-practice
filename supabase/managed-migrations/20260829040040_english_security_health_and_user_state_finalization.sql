create or replace function english.recompute_question_state(p_user_id uuid,p_question_id text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,english,auth as $$
declare
  p record; q english.questions%rowtype; old english.question_state%rowtype;
  v_marked boolean; v_mastered boolean; v_mastered_on timestamptz;
  v_repeat timestamptz; v_recall integer; v_status text; v_next timestamptz;
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
  v_next:=case when v_mastered then null else p.next_review end;

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

  -- User learning state lives only in english.question_state. Do not mutate the shared
  -- canonical question row; that would leak one user's progress into another user's content.
  return jsonb_build_object('question_id',p_question_id,'attempts',p.attempts,'correct',p.correct,'wrong',p.wrong,
    'status',v_status,'next_review',v_next,'mastered',v_mastered,'starred',v_marked,'correct_streak',p.correct_streak);
end;
$$;

create or replace function public.english_get_intelligence_health()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id),
profiles as (
  select qs.question_id,qs.attempts stored_attempts,qs.status stored_status,qs.next_review stored_next,qs.mastered,
         p.attempts calc_attempts,p.state calc_state,p.next_review calc_next
  from english.question_state qs
  cross join uid
  cross join lateral english.learning_profile(uid.id,qs.question_id) p
  where qs.user_id=uid.id
), pc as (
  select count(*)::int state_rows,
    count(*) filter(where stored_attempts<>calc_attempts)::int attempt_count_mismatch,
    count(*) filter(where stored_status is distinct from (case when mastered then 'Mastered' else calc_state end))::int derived_status_mismatch,
    count(*) filter(where stored_next is distinct from (case when mastered then null::timestamptz else calc_next end))::int next_review_mismatch
  from profiles
), latest_star as (
  select distinct on (e.question_id) e.question_id,(e.action='STAR') expected_starred
  from english.star_events e cross join uid where e.user_id=uid.id
  order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
), sc as (
  select count(*) filter(where qs.last_marked is distinct from ls.expected_starred)::int starred_state_mismatch
  from latest_star ls cross join uid join english.question_state qs on qs.user_id=uid.id and qs.question_id=ls.question_id
), d as (
  select count(*)::int stored,
         count(*) filter(where lower(coalesce(status,''))='completed')::int completed
  from english.daily_current cross join uid where user_id=uid.id
), cur as (
  select count(*) filter(where lower(coalesce(status,''))<>'completed')::int remaining
  from uid cross join lateral english.current_daily_items(uid.id)
), dm as (
  select count(*) filter(where cardinality(selection_signals)=0 or selection_snapshot='{}'::jsonb)::int missing_selection_metadata
  from english.daily_current cross join uid where user_id=uid.id
), integrity as (
  select
    (select count(*) from english.attempts a left join english.questions q on q.question_id=a.question_id cross join uid where a.user_id=uid.id and q.question_id is null)::int orphan_attempts,
    (select count(*) from english.question_state s left join english.questions q on q.question_id=s.question_id cross join uid where s.user_id=uid.id and q.question_id is null)::int orphan_state_rows,
    (select count(*) from (select attempt_id from english.attempts cross join uid where user_id=uid.id group by attempt_id having count(*)>1) z)::int duplicate_attempt_ids,
    (select count(*) from english.saved_items si cross join uid left join english.questions q on q.question_id=si.practice_question_id where si.user_id=uid.id and nullif(btrim(si.practice_question_id),'') is not null and q.question_id is null)::int invalid_saved_links,
    (select count(*) from english.difficult_state ds cross join uid join english.question_state qs on qs.user_id=uid.id and qs.question_id=ds.question_id where ds.user_id=uid.id and ds.difficult and qs.mastered)::int difficult_mastered_rows
), counts as (
  select (select count(*) from english.questions where active)::int active_questions,
         (select count(*) from english.attempts cross join uid where user_id=uid.id)::int attempts
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else
 jsonb_build_object(
  'ok',(pc.attempt_count_mismatch=0 and pc.derived_status_mismatch=0 and pc.next_review_mismatch=0 and sc.starred_state_mismatch=0
        and i.orphan_attempts=0 and i.orphan_state_rows=0 and i.duplicate_attempt_ids=0 and i.invalid_saved_links=0 and dm.missing_selection_metadata=0),
  'version',1,
  'counts',jsonb_build_object('activeQuestions',c.active_questions,'attempts',c.attempts,'stateRows',pc.state_rows),
  'learning',jsonb_build_object('attemptCountMismatch',pc.attempt_count_mismatch,'statusMismatch',pc.derived_status_mismatch,'nextReviewMismatch',pc.next_review_mismatch),
  'flags',jsonb_build_object('starredStateMismatch',sc.starred_state_mismatch,'difficultMasteredRows',i.difficult_mastered_rows),
  'integrity',jsonb_build_object('orphanAttempts',i.orphan_attempts,'orphanStateRows',i.orphan_state_rows,'duplicateAttemptIds',i.duplicate_attempt_ids,'invalidSavedLinks',i.invalid_saved_links),
  'daily',jsonb_build_object('stored',d.stored,'completed',d.completed,'actionableRemaining',cur.remaining,
      'suppressed',greatest(0,d.stored-d.completed-cur.remaining),'missingSelectionMetadata',dm.missing_selection_metadata,'targetIsMaximum',true)
 ) end
from pc cross join sc cross join d cross join cur cross join dm cross join integrity i cross join counts c;
$$;

create or replace function public.english_reconcile_intelligence()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); repaired jsonb; health jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  repaired:=english.reconcile_learning_state(uid);
  health:=public.english_get_intelligence_health();
  return health || jsonb_build_object('reconciled',repaired);
end;
$$;

-- Browser writes go through validated SECURITY DEFINER RPCs only.
revoke insert,update,delete on all tables in schema english from authenticated,anon;

-- Public RPC surface is authenticated-only; remove legacy/default execute exposure.
do $$
declare r record;
begin
  for r in
    select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.prokind='f' and n.nspname='public' and p.proname like 'english_%'
  loop
    execute format('revoke execute on function %I.%I(%s) from public',r.nspname,r.proname,r.args);
    execute format('revoke execute on function %I.%I(%s) from anon',r.nspname,r.proname,r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated',r.nspname,r.proname,r.args);
    execute format('grant execute on function %I.%I(%s) to service_role',r.nspname,r.proname,r.args);
  end loop;
end $$;

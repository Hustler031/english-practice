-- Pre-deployment Sprint hardening.
-- 1) 45+ readiness is based only on full 25-question SSC Standard Sprints.
-- 2) Practice modes keep their true maximum marks (15Q=30, 10Q=20).
-- 3) Completed review exposes the learner's selected option for auditable mistake review.
-- 4) Explicitly exited in-progress Sprints can be marked abandoned.

create or replace function public.english_get_sprint_session(p_session_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with s as (
  select * from english.sprint_sessions
  where session_id=p_session_id and user_id=auth.uid()
), i as (
  select x.*,a.selected_key
  from english.sprint_items x
  join s on s.session_id=x.session_id
  left join english.sprint_answers a
    on a.session_id=x.session_id and a.position=x.position and a.user_id=auth.uid()
  order by x.position
)
select case
 when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found')
 else jsonb_build_object(
   'ok',true,
   'sessionId',(select session_id from s),
   'mode',(select mode from s),
   'status',(select status from s),
   'startedAt',(select started_at from s),
   'questionCount',(select question_count from s),
   'durationLimitSeconds',900,
   'items',coalesce((
      select jsonb_agg(
        case when (select status from s)='completed' then
          jsonb_build_object(
            'position',position,'category',category,'questionType',question_type,
            'question',question,'options',options,'selectedKey',selected_key,
            'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,
            'canonicalQuestionId',canonical_question_id
          )
        else
          jsonb_build_object(
            'position',position,'category',category,'questionType',question_type,
            'question',question,'options',options
          )
        end
        order by position
      ) from i
   ),'[]'::jsonb),
   'result',case when (select status from s)='completed' then
      jsonb_build_object(
        'score',(select score from s),
        'maxMarks',(select question_count*2 from s),
        'correct',(select correct_count from s),
        'wrong',(select wrong_count from s),
        'unanswered',(select unanswered_count from s),
        'accuracy',(select accuracy from s),
        'durationSeconds',(select duration_seconds from s),
        'analysis',(select analysis from s)
      )
    else null end
 )
end;
$$;

create or replace function public.english_abandon_sprint(p_session_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare
  uid uuid:=auth.uid();
  current_status text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select status into current_status
  from english.sprint_sessions
  where session_id=p_session_id and user_id=uid
  for update;
  if not found then raise exception 'Sprint not found'; end if;

  if current_status='in_progress' then
    update english.sprint_sessions
       set status='abandoned'
     where session_id=p_session_id and user_id=uid and status='in_progress';
    current_status:='abandoned';
  end if;

  return jsonb_build_object('ok',true,'sessionId',p_session_id,'status',current_status);
end $$;

create or replace function public.english_get_exam_preparation()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (
  select auth.uid() id
), settings as (
  select coalesce(e.target_date,(now() at time zone 'Asia/Kolkata')::date+30) target_date,
         coalesce(e.goal_marks,45) goal_marks
  from uid left join english.exam_settings e on e.user_id=uid.id
), hist_all as (
  select s.*,row_number() over(order by completed_at desc,session_id desc) rn
  from english.sprint_sessions s cross join uid
  where s.user_id=uid.id and s.status='completed'
), standard_hist as (
  select s.*,row_number() over(order by completed_at desc,session_id desc) rn
  from english.sprint_sessions s cross join uid
  where s.user_id=uid.id and s.status='completed' and s.mode='standard'
), five as (
  select * from standard_hist where rn<=5
), streak as (
  select case when count(*)=0 then 0
    else coalesce(min(rn) filter(where score<(select goal_marks from settings))-1,count(*))::int
  end n
  from standard_hist
), miss_all as (
  select a.*,i.category,i.canonical_question_id,s.completed_at,s.mode
  from english.sprint_answers a
  join english.sprint_items i on i.session_id=a.session_id and i.position=a.position
  join english.sprint_sessions s on s.session_id=a.session_id
  cross join uid
  where a.user_id=uid.id and s.status='completed' and not a.correct
), miss_standard as (
  select * from miss_all where mode='standard'
), category as (
  select category,count(*)::int wrong,max(completed_at) last_at
  from miss_all
  group by category
  order by wrong desc,last_at desc
  limit 5
), top_two as (
  select category,wrong,last_at from category order by wrong desc,last_at desc limit 2
), traps as (
  select coalesce(nullif(confused_with,''),diagnosis) trap,count(*)::int n,max(created_at) last_at
  from english.sprint_answers a cross join uid
  where a.user_id=uid.id and nullif(coalesce(confused_with,diagnosis),'') is not null
  group by 1 order by n desc,last_at desc limit 5
), sprint_targeted as (
  select count(distinct question_id)::int n
  from english.learning_route_events e cross join uid
  where e.user_id=uid.id and e.origin='Sprint' and e.to_route='targeted'
), sprint_recovered as (
  select count(distinct e.question_id)::int n
  from english.learning_route_events e cross join uid
  where e.user_id=uid.id and e.origin='Sprint' and e.to_route='targeted'
    and exists(
      select 1 from english.learning_route_state r
      where r.user_id=uid.id and r.question_id=e.question_id and r.route<>'targeted'
    )
), route as (
  select public.english_get_learning_route_overview() j
), intelligence as (
  select public.english_get_central_intelligence() j
)
select case
 when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'targetDate',(select target_date from settings),
   'daysLeft',greatest(0,(select target_date from settings)-(now() at time zone 'Asia/Kolkata')::date),
   'goalMarks',(select goal_marks from settings),
   'standard',jsonb_build_object('questions',25,'minutes',15,'marks',50,'wrongPenalty',-.5,'readingComprehension',false),
   'readiness',jsonb_build_object(
     'lastSprint',(select score from standard_hist where rn=1),
     'fiveSprintAverage',(select round(avg(score),2) from five),
     'best',(select max(score) from standard_hist),
     'lowest',(select min(score) from standard_hist),
     'accuracy',(select round(avg(accuracy),1) from five),
     'timeSeconds',(select round(avg(duration_seconds))::int from five),
     'goalStreak',(select n from streak),
     'knownButMissed',(
       select count(*) from miss_standard m
       where m.canonical_question_id is not null and exists(
         select 1 from english.learning_route_state r
         where r.user_id=(select id from uid) and r.question_id=m.canonical_question_id and r.route='fast_track'
       )
     ),
     'targetedMissed',(
       select count(*) from miss_standard m
       where m.canonical_question_id is not null and exists(
         select 1 from english.learning_route_state r
         where r.user_id=(select id from uid) and r.question_id=m.canonical_question_id and r.route='targeted'
       )
     ),
     'preventableMarksLost',(
       select coalesce(round(count(*) filter(where diagnosis in ('Careless','Misread','Time Pressure'))*2.5,1),0)
       from miss_standard
     )
   ),
   'weaknesses',coalesce((
     select jsonb_agg(jsonb_build_object('category',category,'wrong',wrong) order by wrong desc,last_at desc)
     from category
   ),'[]'::jsonb),
   'traps',coalesce((
     select jsonb_agg(jsonb_build_object('trap',trap,'count',n) order by n desc,last_at desc)
     from traps
   ),'[]'::jsonb),
   'recentSprints',coalesce((
     select jsonb_agg(jsonb_build_object(
       'sessionId',session_id,'mode',mode,'score',score,
       'maxMarks',question_count*2,'questionCount',question_count,
       'correct',correct_count,'wrong',wrong_count,'unanswered',unanswered_count,
       'accuracy',accuracy,'durationSeconds',duration_seconds,'completedAt',completed_at
     ) order by completed_at desc)
     from hist_all where rn<=5
   ),'[]'::jsonb),
   'targetedFromSprints',jsonb_build_object(
     'needLearning',(select n from sprint_targeted),
     'recovered',(select n from sprint_recovered)
   ),
   'todayPlan',jsonb_build_object(
     'targetedRevision',coalesce((
       select (j->'queues'->>'persistentWeak')::int+(j->'queues'->>'weak')::int+(j->'queues'->>'fragile')::int
       from intelligence
     ),0),
     'fastTrackReady',coalesce((select (j->'fastTrack'->>'readyToVerify')::int from route),0),
     'sprintQuestions',25,
     'weaknessDrill',coalesce((select string_agg(category,' + ' order by wrong desc,last_at desc) from top_two),'Current weak areas')
   )
 )
end;
$$;

revoke execute on function public.english_get_sprint_session(uuid) from public,anon;
revoke execute on function public.english_abandon_sprint(uuid) from public,anon;
revoke execute on function public.english_get_exam_preparation() from public,anon;
grant execute on function public.english_get_sprint_session(uuid) to authenticated,service_role;
grant execute on function public.english_abandon_sprint(uuid) to authenticated,service_role;
grant execute on function public.english_get_exam_preparation() to authenticated,service_role;

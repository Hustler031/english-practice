-- Follow-up hardening for Sprint scoring and readiness aggregation.

create or replace function public.english_finish_sprint(p_session_id uuid,p_answers jsonb,p_duration_seconds integer)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare
 uid uuid:=auth.uid();
 s english.sprint_sessions%rowtype;
 i record;
 a jsonb;
 selected text;
 t numeric;
 v_correct integer:=0;
 v_wrong integer:=0;
 v_unanswered integer:=0;
 v_score numeric:=0;
 v_accuracy numeric:=0;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.sprint_sessions where session_id=p_session_id and user_id=uid for update;
 if not found then raise exception 'Sprint not found'; end if;
 if s.status='completed' then return public.english_get_sprint_session(p_session_id); end if;
 if jsonb_typeof(coalesce(p_answers,'[]'::jsonb))<>'array' then raise exception 'Answers must be an array'; end if;

 for i in select * from english.sprint_items where session_id=p_session_id order by position loop
   select value into a
   from jsonb_array_elements(p_answers) value
   where coalesce((value->>'position')::integer,0)=i.position
   limit 1;
   selected:=upper(coalesce(a->>'selectedKey',''));
   t:=least(900,greatest(0,coalesce((a->>'timeSeconds')::numeric,0)));
   if selected not in ('A','B','C','D') then
     selected:=null; v_unanswered:=v_unanswered+1;
   elsif selected=i.correct_key then
     v_correct:=v_correct+1;
   else
     v_wrong:=v_wrong+1;
   end if;
   insert into english.sprint_answers(session_id,position,user_id,selected_key,correct,time_seconds)
   values(p_session_id,i.position,uid,selected,coalesce(selected=i.correct_key,false),t)
   on conflict(session_id,position) do update set
     selected_key=excluded.selected_key,correct=excluded.correct,time_seconds=excluded.time_seconds;
 end loop;

 v_score:=v_correct*2-v_wrong*.5;
 v_accuracy:=case when v_correct+v_wrong>0 then round(v_correct*100.0/(v_correct+v_wrong),1) else 0 end;
 update english.sprint_sessions set
   status='completed',completed_at=now(),
   duration_seconds=least(900,greatest(0,coalesce(p_duration_seconds,0))),
   score=v_score,correct_count=v_correct,wrong_count=v_wrong,unanswered_count=v_unanswered,accuracy=v_accuracy
 where session_id=p_session_id and user_id=uid;

 -- Independent correct Sprint retrieval is evidence, but never direct mastery.
 update english.learning_route_state r set
   metadata=jsonb_set(
     coalesce(r.metadata,'{}'::jsonb),'{sprintCorrectEvidence}',
     to_jsonb(coalesce((r.metadata->>'sprintCorrectEvidence')::int,0)+1),true
   ),updated_at=now()
 from english.sprint_items si
 join english.sprint_answers sa on sa.session_id=si.session_id and sa.position=si.position
 where si.session_id=p_session_id and sa.correct and si.canonical_question_id is not null
   and r.user_id=uid and r.question_id=si.canonical_question_id;

 return public.english_get_sprint_session(p_session_id);
end $$;

create or replace function public.english_get_exam_preparation()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), settings as (
 select coalesce(e.target_date,(now() at time zone 'Asia/Kolkata')::date+30) target_date,coalesce(e.goal_marks,45) goal_marks
 from uid left join english.exam_settings e on e.user_id=uid.id
), hist as (
 select s.*,row_number() over(order by completed_at desc,session_id desc) rn
 from english.sprint_sessions s cross join uid where s.user_id=uid.id and s.status='completed'
), five as (select * from hist where rn<=5),
streak as (
 select coalesce(min(rn) filter(where score<(select goal_marks from settings))-1,count(*))::int n from hist
), miss as (
 select a.*,i.category,i.canonical_question_id,s.completed_at
 from english.sprint_answers a
 join english.sprint_items i on i.session_id=a.session_id and i.position=a.position
 join english.sprint_sessions s on s.session_id=a.session_id cross join uid
 where a.user_id=uid.id and s.status='completed' and not a.correct
), category as (
 select category,count(*)::int wrong,max(completed_at) last_at from miss group by category order by wrong desc,last_at desc limit 5
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
   and exists(select 1 from english.learning_route_state r where r.user_id=uid.id and r.question_id=e.question_id and r.route<>'targeted')
), route as (select public.english_get_learning_route_overview() j),
intelligence as (select public.english_get_central_intelligence() j)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'targetDate',(select target_date from settings),
 'daysLeft',greatest(0,(select target_date from settings)-(now() at time zone 'Asia/Kolkata')::date),
 'goalMarks',(select goal_marks from settings),
 'standard',jsonb_build_object('questions',25,'minutes',15,'marks',50,'wrongPenalty',-.5,'readingComprehension',false),
 'readiness',jsonb_build_object(
   'lastSprint',(select score from hist where rn=1),
   'fiveSprintAverage',(select round(avg(score),2) from five),
   'best',(select max(score) from hist),'lowest',(select min(score) from hist),
   'accuracy',(select round(avg(accuracy),1) from five),
   'timeSeconds',(select round(avg(duration_seconds))::int from five),
   'goalStreak',(select n from streak),
   'knownButMissed',(select count(*) from miss m where m.canonical_question_id is not null and exists(
      select 1 from english.learning_route_state r where r.user_id=(select id from uid) and r.question_id=m.canonical_question_id and r.route='fast_track')),
   'targetedMissed',(select count(*) from miss m where m.canonical_question_id is not null and exists(
      select 1 from english.learning_route_state r where r.user_id=(select id from uid) and r.question_id=m.canonical_question_id and r.route='targeted')),
   'preventableMarksLost',(select coalesce(round(count(*) filter(where diagnosis in ('Careless','Misread','Time Pressure'))*2.5,1),0) from miss)
 ),
 'weaknesses',coalesce((select jsonb_agg(jsonb_build_object('category',category,'wrong',wrong) order by wrong desc,last_at desc) from category),'[]'::jsonb),
 'traps',coalesce((select jsonb_agg(jsonb_build_object('trap',trap,'count',n) order by n desc,last_at desc) from traps),'[]'::jsonb),
 'recentSprints',coalesce((select jsonb_agg(jsonb_build_object(
   'sessionId',session_id,'mode',mode,'score',score,'correct',correct_count,'wrong',wrong_count,
   'unanswered',unanswered_count,'accuracy',accuracy,'durationSeconds',duration_seconds,'completedAt',completed_at
 ) order by completed_at desc) from hist where rn<=5),'[]'::jsonb),
 'targetedFromSprints',jsonb_build_object('needLearning',(select n from sprint_targeted),'recovered',(select n from sprint_recovered)),
 'todayPlan',jsonb_build_object(
   'targetedRevision',coalesce((select (j->'queues'->>'persistentWeak')::int+(j->'queues'->>'weak')::int+(j->'queues'->>'fragile')::int from intelligence),0),
   'fastTrackReady',coalesce((select (j->'fastTrack'->>'readyToVerify')::int from route),0),
   'sprintQuestions',25,
   'weaknessDrill',coalesce((select string_agg(category,' + ' order by wrong desc,last_at desc) from top_two),'Current weak areas')
 )
) end;
$$;

-- Five-day English Sprint report surface.
-- Completed Sprint evidence remains durable in the existing sprint tables; this only exposes a bounded recent review window.

create or replace function public.english_get_sprint_session(p_session_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with s as (
  select *,case
    when status='in_progress' then greatest(0,coalesce(remaining_seconds,900)-greatest(0,floor(extract(epoch from (now()-coalesce(runtime_updated_at,started_at))))::integer))
    else greatest(0,coalesce(remaining_seconds,900))
  end effective_remaining
  from english.sprint_sessions
  where session_id=p_session_id and user_id=auth.uid()
), i as (
  select x.*,a.selected_key,a.time_seconds,a.visited,a.marked_for_review,a.diagnosis,a.action,a.confused_with
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
   'completedAt',(select completed_at from s),
   'pausedAt',(select paused_at from s),
   'questionCount',(select question_count from s),
   'durationLimitSeconds',900,
   'remainingSeconds',(select effective_remaining from s),
   'currentPosition',least((select question_count from s),greatest(1,(select current_position from s))),
   'items',coalesce((
      select jsonb_agg(
        case when (select status from s)='completed' then
          jsonb_build_object(
            'position',position,'category',category,'questionType',question_type,
            'question',question,'options',options,'selectedKey',selected_key,
            'visited',coalesce(visited,false),'markedForReview',coalesce(marked_for_review,false),
            'timeSeconds',coalesce(time_seconds,0),
            'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,
            'canonicalQuestionId',canonical_question_id,
            'diagnosis',diagnosis,'action',action,'confusedWith',confused_with
          )
        else
          jsonb_build_object(
            'position',position,'category',category,'questionType',question_type,
            'question',question,'options',options,'selectedKey',selected_key,
            'visited',coalesce(visited,false),'markedForReview',coalesce(marked_for_review,false),
            'timeSeconds',coalesce(time_seconds,0)
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

create or replace function public.english_get_recent_sprint_reports(p_days integer default 5)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with cfg as (
  select least(7,greatest(1,coalesce(p_days,5)))::integer days
), cutoff as (
  select (((now() at time zone 'Asia/Kolkata')::date-(days-1))::timestamp at time zone 'Asia/Kolkata') since,days
  from cfg
), recent as (
  select s.*
  from english.sprint_sessions s,cfg,cutoff
  where s.user_id=auth.uid()
    and s.status='completed'
    and s.completed_at>=cutoff.since
  order by s.completed_at desc,s.session_id desc
  limit 50
)
select case
 when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'days',(select days from cfg),
   'items',coalesce((
     select jsonb_agg(jsonb_build_object(
       'sessionId',session_id,
       'mode',mode,
       'score',score,
       'maxMarks',question_count*2,
       'questionCount',question_count,
       'correct',correct_count,
       'wrong',wrong_count,
       'unanswered',unanswered_count,
       'accuracy',accuracy,
       'durationSeconds',duration_seconds,
       'completedAt',completed_at
     ) order by completed_at desc,session_id desc)
     from recent
   ),'[]'::jsonb)
 )
end;
$$;

revoke execute on function public.english_get_recent_sprint_reports(integer) from public,anon;
revoke execute on function public.english_get_sprint_session(uuid) from public,anon;
grant execute on function public.english_get_recent_sprint_reports(integer) to authenticated,service_role;
grant execute on function public.english_get_sprint_session(uuid) to authenticated,service_role;

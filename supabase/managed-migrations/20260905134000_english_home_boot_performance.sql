-- Keep the English Home boot path cheap and independent from the full Exam dashboard.
-- Home only needs days-left + goal-marks; the full exam RPC remains available on /english/exam.

create or replace function public.english_get_exam_home_summary()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as (select auth.uid() id), settings as (
  select coalesce(e.target_date,(now() at time zone 'Asia/Kolkata')::date+30) target_date,
         coalesce(e.goal_marks,45) goal_marks
  from uid
  left join english.exam_settings e on e.user_id=uid.id
)
select case
  when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required')
  else jsonb_build_object(
    'ok',true,
    'daysLeft',greatest(0,(select target_date from settings)-(now() at time zone 'Asia/Kolkata')::date),
    'goalMarks',(select goal_marks from settings)
  )
end;
$function$;

revoke execute on function public.english_get_exam_home_summary() from public,anon;
grant execute on function public.english_get_exam_home_summary() to authenticated,service_role;

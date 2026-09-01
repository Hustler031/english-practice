-- Keep Maths Home fast under cold-start warmup contention.
-- Home needs aggregate academic signals only; building the full 50-column _user_runtime
-- also computes Calculation rows, last-daily history, question payloads and other unused fields.
-- This preserves the existing Home metric semantics while narrowing the work to active academic rows.

create or replace function public.maths_get_home_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  day_ int:=maths._study_day();
  daily maths.sessions%rowtype;
  target_ int;
  done_ int;
  resume_ jsonb;
  config jsonb;
  overall_ jsonb;
  counts_ jsonb;
  new_window_days int;
begin
  config:=jsonb_build_object(
    'dailyTarget',coalesce(nullif(maths._setting('daily_chapter_size','25'),'')::int,25),
    'newQuota',coalesce(nullif(maths._setting('daily_new_quota','7'),'')::int,7),
    'difficultRotationDays',coalesce(nullif(maths._setting('difficult_rotation_days','3'),'')::int,3),
    'practiceMoreSize',coalesce(nullif(maths._setting('practice_more_size','20'),'')::int,20),
    'timezone',maths._setting('study_timezone','Asia/Kolkata')
  );
  new_window_days:=greatest(1,coalesce(nullif(maths._setting('new_content_window_days','60'),'')::int,60));

  select * into daily
  from maths.sessions s
  where s.user_id=uid
    and lower(coalesce(s.mode,''))='daily'
    and coalesce(nullif(s.params->>'planDay','')::int,0)=day_
  order by s.completed desc,s.updated_at desc nulls last
  limit 1;

  if daily.session_id is null then
    target_:=(config->>'dailyTarget')::int;
  else
    select count(*) into target_
    from maths.session_questions
    where session_id=daily.session_id;
  end if;

  done_:=case when daily.session_id is null then 0 else (
    select count(distinct a.question_id)
    from maths.attempts a
    where a.user_id=uid and a.session_id=daily.session_id
  ) end;

  select jsonb_build_object(
    'sessionId',s.session_id,
    'title',s.title,
    'mode',s.mode,
    'currentIndex',s.current_index,
    'target',(select count(*) from maths.session_questions sq where sq.session_id=s.session_id)
  )
  into resume_
  from maths.sessions s
  where s.user_id=uid and not s.completed
  order by s.updated_at desc nulls last
  limit 1;

  with academic_q as materialized (
    select rq.question_id,rq.chapter,rq.prompt,rq.added_at
    from maths.runtime_questions rq
    where rq.runtime_active and rq.academic_eligible
  ),
  ranked as (
    select
      a.question_id,a.result,a.response_sec,a.attempted_at,
      row_number() over(partition by a.question_id order by a.attempted_at desc,a.attempt_id desc) rn,
      count(*) over(partition by a.question_id) total_count
    from maths.attempts a
    join academic_q q on q.question_id=a.question_id
    where a.user_id=uid
  ),
  prof as (
    select
      question_id,
      max(total_count)::int total,
      count(*) filter(where rn<=5 and lower(result) in('correct','wrong'))::int graded,
      count(*) filter(where rn<=5 and lower(result)='correct')::numeric /
        nullif(count(*) filter(where rn<=5 and lower(result) in('correct','wrong')),0) accuracy,
      avg(response_sec) filter(where rn<=5 and coalesce(response_sec,0)>0) avg_sec,
      (array_agg(lower(coalesce(result,'')) order by rn) filter(where rn<=5))[1] last_result,
      greatest(0,coalesce(min(rn) filter(where rn<=5 and lower(coalesce(result,''))<>'wrong'),6)-1)::int wrong_streak
    from ranked
    where rn<=5
    group by question_id
  ),
  base as (
    select
      q.question_id,q.added_at,
      coalesce(st.attempts,0) state_attempts,
      coalesce(st.mastered,false) mastered,
      coalesce(st.marked,false) starred,
      coalesce(st.difficult,false) difficult,
      coalesce(p.total,0) profile_total,
      coalesce(p.graded,0) profile_graded,
      p.accuracy profile_accuracy,
      coalesce(p.avg_sec,0) profile_avg_sec,
      coalesce(p.last_result,'') profile_last_result,
      coalesce(p.wrong_streak,0) wrong_streak,
      case
        when maths._norm(q.chapter) in('geometry','coordinate geometry') or length(coalesce(q.prompt,''))>=220 then 45
        else 30
      end expected_sec
    from academic_q q
    left join maths.question_state st on st.user_id=uid and st.question_id=q.question_id
    left join prof p on p.question_id=q.question_id
  ),
  signals as materialized (
    select b.*,
      (not b.mastered and b.profile_graded>=2 and (
        b.wrong_streak>=2
        or (b.profile_graded>=3 and coalesce(b.profile_accuracy,1)<=.5)
        or (b.profile_total>=3 and b.profile_avg_sec>=b.expected_sec*1.5)
      )) hard_calc,
      (not b.mastered and b.profile_total>0 and (
        b.profile_last_result='wrong'
        or (b.profile_graded>=2 and coalesce(b.profile_accuracy,1)<.75)
        or b.profile_avg_sec>=b.expected_sec
      )) weak_calc
    from base b
  ),
  mx as (
    select max(added_at) max_added from signals where state_attempts=0
  )
  select
    (
      select maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak_calc),
        count(*) filter(where hard_calc),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      )
      from signals
    ),
    jsonb_build_object(
      'new',(
        select count(*)
        from signals a cross join mx
        where a.state_attempts=0 and (
          mx.max_added is null or a.added_at is null
          or a.added_at>=mx.max_added-((new_window_days||' days')::interval)
        )
      ),
      'starred',(select count(*) from signals where starred and not mastered),
      'concepts',(
        select count(*)
        from maths.concept_membership c
        join maths.runtime_questions cr on cr.question_id=c.question_id
        where c.user_id=uid and c.active and cr.runtime_active
          and not (cr.bank_calculation or cr.in_calc_set or upper(coalesce(cr.practice_bank,''))='CALCULATION_AI')
      ),
      'mocks',(select count(*) from maths.practice_set_items where set_id='MOCK_QUESTIONS'),
      'formulas',(select count(*) from maths.practice_set_items where set_id='MOCK_FORMULA_REVISION'),
      'calculation',0
    )
  into overall_,counts_;

  return jsonb_build_object(
    'ok',true,
    'studyDay',day_,
    'config',config,
    'daily',jsonb_build_object(
      'target',target_,
      'done',least(done_,target_),
      'remaining',greatest(0,target_-done_),
      'completed',coalesce(daily.completed,false),
      'sessionId',coalesce(daily.session_id,''),
      'composition',coalesce(daily.params->'dailyComposition','null'::jsonb)
    ),
    'resume',resume_,
    'overall',overall_,
    'counts',counts_
  );
end
$$;

grant execute on function public.maths_get_home_snapshot() to authenticated;

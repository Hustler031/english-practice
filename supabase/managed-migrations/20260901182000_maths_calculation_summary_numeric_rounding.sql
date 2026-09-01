-- Fix Calculation Speed report rounding after timed completion.
-- PostgreSQL percentile_cont returns double precision; two-argument round(value, digits)
-- requires numeric. Cast percentile outputs at source so report rendering remains safe.

create or replace function public.maths_get_calculation_summary(p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid();
  s maths.sessions%rowtype;
  attempted_ int; correct_ int; wrong_ int;
  med_ numeric; p75_ numeric; p90_ numeric; elapsed_ numeric; qpm_ numeric;
  skills_ jsonb;
begin
  select * into s
  from maths.sessions
  where session_id=p_session_id and user_id=uid and lower(coalesce(mode,''))='calculation_speed';
  if not found then raise exception 'Calculation session not found'; end if;

  elapsed_:=least(
    coalesce(nullif(s.params->>'durationSec','')::numeric,600),
    greatest(1,extract(epoch from (coalesce(nullif(s.params->>'finishedAt','')::timestamptz,now())-s.created_at)))
  );

  select
    count(*),
    count(*) filter(where result='correct'),
    count(*) filter(where result='wrong'),
    (percentile_cont(.5) within group(order by response_sec) filter(where response_sec>0))::numeric,
    (percentile_cont(.75) within group(order by response_sec) filter(where response_sec>0))::numeric,
    (percentile_cont(.90) within group(order by response_sec) filter(where response_sec>0))::numeric
  into attempted_,correct_,wrong_,med_,p75_,p90_
  from maths.attempts
  where user_id=uid and session_id=p_session_id and result in('correct','wrong');

  qpm_:=case when elapsed_>0 then round(coalesce(attempted_,0)/(elapsed_/60),2) else 0 end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'skill',skill,
    'attempted',n,
    'accuracy',round(100*correct::numeric/nullif(n,0),1),
    'medianSec',round(median_sec,1),
    'baselineSec',round(baseline_sec,1),
    'band',case
      when n>=3 and 100*correct::numeric/nullif(n,0)>=95 and median_sec<=baseline_sec*.8 then 'Automatic'
      when n>=3 and 100*correct::numeric/nullif(n,0)>=90 and median_sec<=baseline_sec then 'Strong'
      when n>=2 and 100*correct::numeric/nullif(n,0)>=80 then 'Almost there'
      else 'Needs work'
    end
  ) order by n desc,skill),'[]'::jsonb)
  into skills_
  from (
    select
      coalesce(nullif(q.topic,''),nullif(q.subtopic,''),'Mixed') skill,
      count(*) n,
      count(*) filter(where a.result='correct') correct,
      (percentile_cont(.5) within group(order by a.response_sec))::numeric median_sec,
      (percentile_cont(.5) within group(order by maths._baseline_sec(uid,a.question_id,a.attempted_at)))::numeric baseline_sec
    from maths.attempts a
    join maths.runtime_questions q on q.question_id=a.question_id
    where a.user_id=uid and a.session_id=p_session_id and a.result in('correct','wrong') and a.response_sec>0
    group by 1
  ) x;

  return jsonb_build_object(
    'ok',true,
    'sessionId',p_session_id,
    'attempted',coalesce(attempted_,0),
    'correct',coalesce(correct_,0),
    'wrong',coalesce(wrong_,0),
    'accuracy',case when attempted_>0 then round(100*correct_::numeric/attempted_,1) else 0 end,
    'qpm',coalesce(qpm_,0),
    'medianSec',round(coalesce(med_,0),1),
    'p75Sec',round(coalesce(p75_,0),1),
    'p90Sec',round(coalesce(p90_,0),1),
    'elapsedSec',round(coalesce(elapsed_,0),1),
    'skills',skills_
  );
end
$$;

grant execute on function public.maths_get_calculation_summary(text) to authenticated;

create or replace function public.maths_get_calculation_hub()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with c as materialized (
    select
      r.*,
      maths._calc_type(q) calc_type,
      coalesce(nullif(q.topic,''),nullif(q.subtopic,''),'Mixed') skill
    from maths._user_runtime(uid) r
    join maths.runtime_questions q using(question_id)
    where r.runtime_active
      and (r.bank_calculation or r.in_calc_set)
      and (maths._calc_type(q)<>'MEMORY' or maths._calc_recall_eligible(q))
  ),
  skill_perf as (
    select
      skill,
      count(*) total,
      count(*) filter(where calc_type='MEMORY') memory,
      count(*) filter(where calc_type='METHOD') methods,
      count(*) filter(where calc_type='DRILL') drills,
      count(*) filter(where profile_total>0) attempted,
      avg(profile_accuracy) filter(where profile_graded>0) accuracy,
      percentile_cont(.5) within group(order by nullif(last_response_sec,0)) median_sec,
      percentile_cont(.5) within group(order by expected_sec) baseline_sec,
      count(*) filter(where profile_last_result='wrong' or last_response_sec>expected_sec) leakage
    from c group by skill
  ),
  focus as (
    select skill,leakage from skill_perf order by leakage desc,skill limit 2
  )
  select jsonb_build_object(
    'ok',true,
    'total',count(*),
    'memory',count(*) filter(where calc_type='MEMORY'),
    'methods',count(*) filter(where calc_type='METHOD'),
    'drills',count(*) filter(where calc_type='DRILL'),
    'slow',count(*) filter(where last_response_sec>=8),
    'wrong',count(*) filter(where profile_last_result='wrong'),
    'durationSec',600,
    'skills',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'skill',skill,
          'total',total,
          'memory',memory,
          'methods',methods,
          'drills',drills,
          'attempted',attempted,
          'accuracy',case when accuracy is null then null else round((100*accuracy)::numeric,1) end,
          'medianSec',round(coalesce(median_sec,0)::numeric,1),
          'baselineSec',round(coalesce(baseline_sec,0)::numeric,1),
          'band',case
            when attempted>=3 and coalesce(accuracy,0)>=.95 and coalesce(median_sec,999)<=coalesce(baseline_sec,30)*.8 then 'Automatic'
            when attempted>=3 and coalesce(accuracy,0)>=.90 and coalesce(median_sec,999)<=coalesce(baseline_sec,30) then 'Strong'
            when attempted>=2 and coalesce(accuracy,0)>=.80 then 'Almost there'
            else 'Needs work'
          end
        )
        order by leakage desc,skill
      )
      from skill_perf
    ),'[]'::jsonb),
    'todayFocus',coalesce((select jsonb_agg(skill order by leakage desc,skill) from focus),'[]'::jsonb)
  ) into body
  from c;

  return body;
end
$$;

notify pgrst,'reload schema';

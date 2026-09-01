create or replace function maths._metric_json(
  p_total bigint,
  p_attempted bigint,
  p_wrong bigint,
  p_weak bigint,
  p_hard bigint,
  p_starred bigint,
  p_difficult bigint,
  p_mastered bigint
) returns jsonb
language sql
immutable
set search_path to 'pg_catalog','public','maths'
as $$
  select jsonb_build_object(
    'total', p_total,
    'attempted', p_attempted,
    'unseen', greatest(0::bigint, p_total - p_attempted),
    'coverage', case when p_total=0 then 0 else round(100.0 * p_attempted / p_total, 1) end,
    'wrong', p_wrong,
    'weak', p_weak,
    'hard', p_hard,
    'starred', p_starred,
    'difficult', p_difficult,
    'mastered', p_mastered
  )
$$;

create or replace function public.maths_get_mocks_hub()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with r as materialized (
    select * from maths._user_runtime(uid)
    where runtime_active and in_mock
  ),
  overall as (
    select maths._metric_json(
      count(*),
      count(*) filter(where state_attempts>0),
      count(*) filter(where profile_last_result='wrong'),
      count(*) filter(where weak),
      count(*) filter(where hard),
      count(*) filter(where starred),
      count(*) filter(where difficult),
      count(*) filter(where mastered)
    ) metric
    from r
  ),
  chapters as (
    select chapter,
      count(*) filter(where profile_last_result='wrong') wrong_count,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from r
    group by chapter
  )
  select jsonb_build_object(
    'ok',true,
    'setId','MOCK_QUESTIONS',
    'overall',(select metric from overall),
    'chapters',coalesce((
      select jsonb_agg(jsonb_build_object('chapter',chapter,'metric',metric) order by wrong_count desc,chapter)
      from chapters
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_get_chapters_hub()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb; zero_metric jsonb:=maths._metric_json(0,0,0,0,0,0,0,0);
begin
  with r as materialized (
    select * from maths._user_runtime(uid) where academic_eligible
  ),
  chapter_metrics as (
    select chapter,group_key,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from r group by chapter,group_key
  ),
  group_metrics as (
    select group_key,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from r group by group_key
  )
  select jsonb_build_object(
    'ok',true,
    'groups',jsonb_build_array(
      jsonb_build_object('key','advanced','label','Advanced','metric',coalesce((select metric from group_metrics where group_key='advanced'),zero_metric)),
      jsonb_build_object('key','arithmetic','label','Arithmetic','metric',coalesce((select metric from group_metrics where group_key='arithmetic'),zero_metric)),
      jsonb_build_object('key','misc','label','MISC','metric',coalesce((select metric from group_metrics where group_key='misc'),zero_metric))
    ),
    'chapters',coalesce((
      select jsonb_agg(
        jsonb_build_object('chapter',chapter,'group',group_key,'metric',metric)
        order by case group_key when 'advanced' then 1 when 'arithmetic' then 2 else 3 end,chapter
      )
      from chapter_metrics
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_get_progress()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb; zero_metric jsonb:=maths._metric_json(0,0,0,0,0,0,0,0);
begin
  with r as materialized (
    select * from maths._user_runtime(uid) where academic_eligible
  ),
  overall as (
    select maths._metric_json(
      count(*),
      count(*) filter(where state_attempts>0),
      count(*) filter(where profile_last_result='wrong'),
      count(*) filter(where weak),
      count(*) filter(where hard),
      count(*) filter(where starred),
      count(*) filter(where difficult),
      count(*) filter(where mastered)
    ) metric from r
  ),
  group_metrics as (
    select group_key,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from r group by group_key
  ),
  chapter_metrics as (
    select chapter,group_key,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from r group by chapter,group_key
  )
  select jsonb_build_object(
    'ok',true,
    'overall',(select metric from overall),
    'advanced',coalesce((select metric from group_metrics where group_key='advanced'),zero_metric),
    'arithmetic',coalesce((select metric from group_metrics where group_key='arithmetic'),zero_metric),
    'misc',coalesce((select metric from group_metrics where group_key='misc'),zero_metric),
    'chapters',coalesce((
      select jsonb_agg(jsonb_build_object('chapter',chapter,'group',group_key,'metric',metric) order by chapter)
      from chapter_metrics
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_get_chapter(p_chapter text,p_topic text default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with r as materialized (
    select * from maths._user_runtime(uid)
    where academic_eligible and maths._norm(chapter)=maths._norm(p_chapter)
  ),
  selected as (
    select * from r
    where p_topic is null
       or maths._norm(major_topic)=maths._norm(p_topic)
       or maths._norm(topic)=maths._norm(p_topic)
  ),
  selected_metric as (
    select maths._metric_json(
      count(*),
      count(*) filter(where state_attempts>0),
      count(*) filter(where profile_last_result='wrong'),
      count(*) filter(where weak),
      count(*) filter(where hard),
      count(*) filter(where starred),
      count(*) filter(where difficult),
      count(*) filter(where mastered)
    ) metric from selected
  ),
  topic_metrics as (
    select major_topic,
      case major_topic
        when 'Lines & Angles' then 1
        when 'Triangle' then 2
        when 'Circle' then 3
        when 'Quadrilateral & Polygon' then 4
        when 'Quadrilateral' then 2
        when 'Polygon' then 4
        when 'Paths / Composite 2D' then 5
        when 'Cuboid & Cube' then 1
        when 'Cylinder' then 2
        when 'Cone & Frustum' then 3
        when 'Sphere & Hemisphere' then 4
        when 'Prism & Pyramid' then 5
        when 'Composite Solids' then 6
        when 'Profit & Loss' then 1
        when 'Dishonest Sellers' then 2
        when 'Discount' then 3
        else 99
      end ord,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from r group by major_topic
  )
  select jsonb_build_object(
    'ok',true,
    'chapter',p_chapter,
    'topic',p_topic,
    'metric',(select metric from selected_metric),
    'topics',coalesce((
      select jsonb_agg(jsonb_build_object('name',major_topic,'metric',metric) order by ord,major_topic)
      from topic_metrics
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_get_concepts_hub()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with c as materialized (
    select r.*
    from maths._user_runtime(uid) r
    join maths.concept_membership m
      on m.user_id=uid and m.question_id=r.question_id and m.active
    where r.runtime_active
  ),
  overall as (
    select maths._metric_json(
      count(*),
      count(*) filter(where state_attempts>0),
      count(*) filter(where profile_last_result='wrong'),
      count(*) filter(where weak),
      count(*) filter(where hard),
      count(*) filter(where starred),
      count(*) filter(where difficult),
      count(*) filter(where mastered)
    ) metric from c
  ),
  topic_metrics as (
    select chapter,major_topic,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from c group by chapter,major_topic
  ),
  chapter_metrics as (
    select chapter,
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) metric
    from c group by chapter
  )
  select jsonb_build_object(
    'ok',true,
    'metric',(select metric from overall),
    'chapters',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'chapter',cm.chapter,
          'metric',cm.metric,
          'topics',coalesce((
            select jsonb_agg(jsonb_build_object('name',tm.major_topic,'metric',tm.metric) order by tm.major_topic)
            from topic_metrics tm where tm.chapter=cm.chapter
          ),'[]'::jsonb)
        )
        order by cm.chapter
      )
      from chapter_metrics cm
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_get_formula_hub()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with r as materialized (
    select * from maths._user_runtime(uid)
    where runtime_active and in_formula_revision
  ),
  overall as (
    select (
      maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      )
      || jsonb_build_object(
        'wrong',count(*) filter(where last_state_result='wrong'),
        'weak',count(*) filter(where last_state_result='wrong')
      )
    ) metric,
    count(*) filter(where state_attempts=0 or last_state_result='wrong' or difficult) due
    from r
  ),
  chapters as (
    select chapter,
      (
        maths._metric_json(
          count(*),
          count(*) filter(where state_attempts>0),
          count(*) filter(where profile_last_result='wrong'),
          count(*) filter(where weak),
          count(*) filter(where hard),
          count(*) filter(where starred),
          count(*) filter(where difficult),
          count(*) filter(where mastered)
        )
        || jsonb_build_object(
          'wrong',count(*) filter(where last_state_result='wrong'),
          'weak',count(*) filter(where last_state_result='wrong')
        )
      ) metric
    from r group by chapter
  )
  select jsonb_build_object(
    'ok',true,
    'setId','MOCK_FORMULA_REVISION',
    'overall',(select metric from overall),
    'due',(select due from overall),
    'chapters',coalesce((
      select jsonb_agg(jsonb_build_object('chapter',chapter,'metric',metric) order by chapter)
      from chapters
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_get_home_snapshot()
returns jsonb
language plpgsql
stable security definer
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
    select count(*) into target_ from maths.session_questions where session_id=daily.session_id;
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
  ) into resume_
  from maths.sessions s
  where s.user_id=uid and not s.completed
  order by s.updated_at desc nulls last
  limit 1;

  with r as materialized (
    select * from maths._user_runtime(uid)
  ),
  academic as materialized (
    select * from r where academic_eligible
  ),
  mx as (
    select max(added_at) max_added from academic where state_attempts=0
  )
  select
    (
      select maths._metric_json(
        count(*),
        count(*) filter(where state_attempts>0),
        count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),
        count(*) filter(where hard),
        count(*) filter(where starred),
        count(*) filter(where difficult),
        count(*) filter(where mastered)
      ) from academic
    ),
    jsonb_build_object(
      'new',(
        select count(*)
        from academic a cross join mx
        where a.state_attempts=0
          and (
            mx.max_added is null
            or a.added_at is null
            or a.added_at >= mx.max_added - ((new_window_days||' days')::interval)
          )
      ),
      'starred',(select count(*) from academic where starred and not mastered),
      'concepts',(select count(*) from maths.concept_membership c where c.user_id=uid and c.active),
      'mocks',(select count(*) from maths.practice_set_items where set_id='MOCK_QUESTIONS'),
      'formulas',(select count(*) from maths.practice_set_items where set_id='MOCK_FORMULA_REVISION'),
      'calculation',(select count(*) from r where runtime_active and (bank_calculation or in_calc_set))
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

notify pgrst,'reload schema';

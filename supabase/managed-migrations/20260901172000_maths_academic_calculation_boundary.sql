-- Maths Exam Prep academic/calculation boundary.
-- Keeps historical evidence intact while removing Calculation from normal academic learning surfaces.

create table if not exists maths.exam_prep_config(
  singleton boolean primary key default true check(singleton),
  start_date date not null,
  plan_days integer not null default 30 check(plan_days between 1 and 120),
  updated_at timestamptz not null default now()
);
revoke all on table maths.exam_prep_config from anon, authenticated;
insert into maths.exam_prep_config(singleton,start_date,plan_days,updated_at)
values(true,date '2026-09-01',30,now())
on conflict(singleton) do update
set start_date=excluded.start_date,plan_days=excluded.plan_days,updated_at=now();

create or replace function maths._exam_prep_state()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  start_ date;
  days_ integer;
  today_ date:=(current_timestamp at time zone 'Asia/Kolkata')::date;
  day_ integer;
begin
  select start_date,plan_days into start_,days_ from maths.exam_prep_config where singleton limit 1;
  start_:=coalesce(start_,today_);
  days_:=greatest(1,coalesce(days_,30));
  day_:=greatest(1,today_-start_+1);
  return jsonb_build_object(
    'startDate',start_::text,
    'planDays',days_,
    'day',day_,
    'daysLeft',greatest(0,days_-day_+1),
    'today',today_::text
  );
end
$$;

create or replace function public.maths_get_exam_prep_state()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); state_ jsonb;
begin
  state_:=maths._exam_prep_state();
  return jsonb_build_object('ok',true)||state_;
end
$$;
grant execute on function public.maths_get_exam_prep_state() to authenticated;

-- Repair-first Daily remains intact, but repair candidates must belong to the academic runtime.
create or replace function maths._select_daily_ids_v45(
  p_uid uuid,p_day integer,p_size integer,p_exclude text[] default array[]::text[]
)
returns text[]
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  repairs text[]:=array[]::text[];
  rest text[]:=array[]::text[];
  repair_limit int;
begin
  repair_limit:=greatest(1,least(6,ceil(greatest(1,p_size)*.24)::int));
  repairs:=maths._repair_candidate_ids(p_uid,repair_limit*3,null);
  repairs:=array(
    select x
    from unnest(coalesce(repairs,array[]::text[])) x
    join maths._user_runtime(p_uid) r on r.question_id=x
    where r.runtime_active and r.academic_eligible
      and not x=any(coalesce(p_exclude,array[]::text[]))
    limit repair_limit
  );
  rest:=maths._select_daily_ids(
    p_uid,p_day,
    greatest(0,p_size-coalesce(array_length(repairs,1),0)),
    coalesce(p_exclude,array[]::text[])||coalesce(repairs,array[]::text[])
  );
  return coalesce(repairs,array[]::text[])||coalesce(rest,array[]::text[]);
end
$$;

-- Calculation cards are not Academic Concepts. Preserve rows as inactive history instead of deleting them.
update maths.concept_membership m
set active=false
where m.active
  and exists(
    select 1 from maths.runtime_questions r
    where r.question_id=m.question_id
      and (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI')
  );

create or replace function public.maths_set_concept(p_question_id text,p_value boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); q maths.runtime_questions%rowtype; calc_ boolean;
begin
  select * into q from maths.runtime_questions where question_id=p_question_id and runtime_active;
  if not found then raise exception 'Question is missing or inactive'; end if;
  calc_:=coalesce(q.bank_calculation,false) or coalesce(q.in_calc_set,false) or upper(coalesce(q.practice_bank,''))='CALCULATION_AI';
  if p_value and calc_ then raise exception 'Calculation training is separate from Academic Concepts'; end if;
  insert into maths.concept_membership(question_id,added_at,study_day,chapter,topic,session_id,active,user_id)
  values(p_question_id,now(),maths._study_day(),q.chapter,q.topic,null,p_value,uid)
  on conflict(user_id,question_id) do update
  set active=excluded.active,chapter=excluded.chapter,topic=excluded.topic;
  return jsonb_build_object('ok',true,'questionId',p_question_id,'inConcept',p_value);
end
$$;

create or replace function public.maths_get_concepts_hub()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with c as materialized (
    select r.*
    from maths._user_runtime(uid) r
    join maths.concept_membership m on m.user_id=uid and m.question_id=r.question_id and m.active
    where r.runtime_active
      and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI')
  ),
  overall as (
    select maths._metric_json(
      count(*),count(*) filter(where state_attempts>0),count(*) filter(where profile_last_result='wrong'),
      count(*) filter(where weak),count(*) filter(where hard),count(*) filter(where starred),
      count(*) filter(where difficult),count(*) filter(where mastered)
    ) metric from c
  ),
  topic_metrics as (
    select chapter,major_topic,
      maths._metric_json(
        count(*),count(*) filter(where state_attempts>0),count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),count(*) filter(where hard),count(*) filter(where starred),
        count(*) filter(where difficult),count(*) filter(where mastered)
      ) metric
    from c group by chapter,major_topic
  ),
  chapter_metrics as (
    select chapter,
      maths._metric_json(
        count(*),count(*) filter(where state_attempts>0),count(*) filter(where profile_last_result='wrong'),
        count(*) filter(where weak),count(*) filter(where hard),count(*) filter(where starred),
        count(*) filter(where difficult),count(*) filter(where mastered)
      ) metric
    from c group by chapter
  )
  select jsonb_build_object(
    'ok',true,
    'metric',(select metric from overall),
    'chapters',coalesce((
      select jsonb_agg(jsonb_build_object(
        'chapter',cm.chapter,'metric',cm.metric,
        'topics',coalesce((select jsonb_agg(jsonb_build_object('name',tm.major_topic,'metric',tm.metric) order by tm.major_topic)
                           from topic_metrics tm where tm.chapter=cm.chapter),'[]'::jsonb)
      ) order by cm.chapter)
      from chapter_metrics cm
    ),'[]'::jsonb)
  ) into body;
  return body;
end
$$;

create or replace function public.maths_start_concepts(
  p_kind text default 'random',p_chapter text default null,p_topic text default null,p_count integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); base text[]; ids text[];
begin
  select coalesce(array_agg(r.question_id),array[]::text[]) into base
  from maths._user_runtime(uid) r
  join maths.concept_membership c on c.user_id=uid and c.question_id=r.question_id and c.active
  where r.runtime_active
    and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI')
    and (p_chapter is null or maths._norm(r.chapter)=maths._norm(p_chapter))
    and (p_topic is null or maths._norm(r.major_topic)=maths._norm(p_topic));
  ids:=maths._select_by_kind(uid,base,p_kind,p_count);
  return maths._start_session(uid,ids,'concept_saved','Concepts · '||coalesce(p_topic,p_chapter,'All')||' · '||initcap(p_kind),
    jsonb_build_object('scope','concept_saved','kind',p_kind,'chapter',p_chapter,'majorTopic',p_topic),false);
end
$$;

create or replace function public.maths_get_demand_hub()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); sets jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'setId',s.set_id,'name',s.set_name,'description',coalesce(s.description,''),'status',s.status,
    'count',(select count(*) from maths.practice_set_items i where i.set_id=s.set_id),
    'specialist',s.set_id in('MOCK_QUESTIONS','MOCK_FORMULA_REVISION')
  ) order by s.set_name),'[]'::jsonb)
  into sets
  from maths.practice_sets s
  where s.user_id=uid and lower(coalesce(s.status,'active'))<>'inactive' and s.set_id<>'CALC_TRAINING';
  return jsonb_build_object('ok',true,'sets',sets);
end
$$;

create or replace function public.maths_get_ondemand_hub()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); d jsonb; generated_ int; concepts_ int;
begin
  d:=public.maths_get_demand_hub();
  select count(*) into generated_
  from maths._user_runtime(uid) r
  where r.runtime_active and r.bank_generated and upper(coalesce(r.practice_bank,''))<>'CALCULATION_AI';
  select count(*) into concepts_
  from maths.concept_membership c
  join maths.runtime_questions r on r.question_id=c.question_id
  where c.user_id=uid and c.active and r.runtime_active
    and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI');
  return jsonb_build_object(
    'ok',true,'calculation',0,
    'mocks',(select count(*) from maths.practice_set_items where set_id='MOCK_QUESTIONS'),
    'formulas',(select count(*) from maths.practice_set_items where set_id='MOCK_FORMULA_REVISION'),
    'concepts',coalesce(concepts_,0),'generated',coalesce(generated_,0),'demandSets',d->'sets'
  );
end
$$;

create or replace function public.maths_get_home_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid(); day_ int:=maths._study_day(); daily maths.sessions%rowtype;
  target_ int; done_ int; resume_ jsonb; config jsonb; overall_ jsonb; counts_ jsonb; new_window_days int;
begin
  config:=jsonb_build_object(
    'dailyTarget',coalesce(nullif(maths._setting('daily_chapter_size','25'),'')::int,25),
    'newQuota',coalesce(nullif(maths._setting('daily_new_quota','7'),'')::int,7),
    'difficultRotationDays',coalesce(nullif(maths._setting('difficult_rotation_days','3'),'')::int,3),
    'practiceMoreSize',coalesce(nullif(maths._setting('practice_more_size','20'),'')::int,20),
    'timezone',maths._setting('study_timezone','Asia/Kolkata')
  );
  new_window_days:=greatest(1,coalesce(nullif(maths._setting('new_content_window_days','60'),'')::int,60));
  select * into daily from maths.sessions s
  where s.user_id=uid and lower(coalesce(s.mode,''))='daily'
    and coalesce(nullif(s.params->>'planDay','')::int,0)=day_
  order by s.completed desc,s.updated_at desc nulls last limit 1;
  if daily.session_id is null then target_:=(config->>'dailyTarget')::int;
  else select count(*) into target_ from maths.session_questions where session_id=daily.session_id; end if;
  done_:=case when daily.session_id is null then 0 else (
    select count(distinct a.question_id) from maths.attempts a where a.user_id=uid and a.session_id=daily.session_id
  ) end;
  select jsonb_build_object('sessionId',s.session_id,'title',s.title,'mode',s.mode,'currentIndex',s.current_index,
    'target',(select count(*) from maths.session_questions sq where sq.session_id=s.session_id))
  into resume_ from maths.sessions s where s.user_id=uid and not s.completed
  order by s.updated_at desc nulls last limit 1;
  with r as materialized(select * from maths._user_runtime(uid)),
  academic as materialized(select * from r where academic_eligible),
  mx as(select max(added_at) max_added from academic where state_attempts=0)
  select
    (select maths._metric_json(
      count(*),count(*) filter(where state_attempts>0),count(*) filter(where profile_last_result='wrong'),
      count(*) filter(where weak),count(*) filter(where hard),count(*) filter(where starred),
      count(*) filter(where difficult),count(*) filter(where mastered)) from academic),
    jsonb_build_object(
      'new',(select count(*) from academic a cross join mx where a.state_attempts=0 and (
        mx.max_added is null or a.added_at is null or a.added_at>=mx.max_added-((new_window_days||' days')::interval))),
      'starred',(select count(*) from academic where starred and not mastered),
      'concepts',(select count(*) from maths.concept_membership c join maths.runtime_questions cr on cr.question_id=c.question_id
                  where c.user_id=uid and c.active and cr.runtime_active
                    and not (cr.bank_calculation or cr.in_calc_set or upper(coalesce(cr.practice_bank,''))='CALCULATION_AI')),
      'mocks',(select count(*) from maths.practice_set_items where set_id='MOCK_QUESTIONS'),
      'formulas',(select count(*) from maths.practice_set_items where set_id='MOCK_FORMULA_REVISION'),
      'calculation',0
    )
  into overall_,counts_;
  return jsonb_build_object(
    'ok',true,'studyDay',day_,'config',config,
    'daily',jsonb_build_object('target',target_,'done',least(done_,target_),'remaining',greatest(0,target_-done_),
      'completed',coalesce(daily.completed,false),'sessionId',coalesce(daily.session_id,''),
      'composition',coalesce(daily.params->'dailyComposition','null'::jsonb)),
    'resume',resume_,'overall',overall_,'counts',counts_
  );
end
$$;

-- Academic readiness ignores Calculation-training evidence. CAL may still be diagnosed from an academic Sprint miss.
create or replace function public.maths_get_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  uid uuid:=maths._require_uid(); state_ jsonb:=maths._exam_prep_state(); day_ int; phase_ int;
  graded_ int; correct_ int; clean_ int; knowledge_ numeric; performance_ numeric; reasons_ jsonb; diagnosis_ int;
  p0_ int; due_ int; persistent_ int; cold_ int; sprint_ jsonb; top_reason text; recommendations jsonb;
begin
  day_:=greatest(1,coalesce((state_->>'day')::int,1));
  phase_:=case when day_<=7 then 1 when day_<=15 then 2 when day_<=23 then 3 else 4 end;
  with recent as (
    select e.*
    from maths.performance_evidence e
    join maths.runtime_questions r on r.question_id=e.question_id
    left join maths.sessions s on s.session_id=e.session_id
    where e.user_id=uid and e.created_at>=now()-interval '30 days' and e.correctness in('correct','wrong')
      and lower(coalesce(s.mode,''))<>'calculation_speed'
      and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI')
  )
  select count(*),count(*) filter(where correctness='correct'),count(*) filter(where correctness='correct' and not slow_correct),
         count(*) filter(where correctness='wrong' and final_reason is null)
  into graded_,correct_,clean_,diagnosis_ from recent;
  knowledge_:=case when graded_>0 then round(100*correct_::numeric/graded_,1) else 0 end;
  performance_:=case when graded_>0 then round(100*clean_::numeric/graded_,1) else 0 end;

  select coalesce(jsonb_object_agg(reason,n),'{}'::jsonb),(array_agg(reason order by n desc,reason))[1]
  into reasons_,top_reason
  from (
    select e.final_reason reason,count(*) n
    from maths.performance_evidence e
    join maths.runtime_questions r on r.question_id=e.question_id
    left join maths.sessions s on s.session_id=e.session_id
    where e.user_id=uid and e.created_at>=now()-interval '14 days'
      and (e.correctness='wrong' or e.slow_correct) and e.final_reason is not null
      and lower(coalesce(s.mode,''))<>'calculation_speed'
      and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI')
    group by e.final_reason
  ) x;

  with rq as (
    select q.*,
      case
        when q.question_id is not null then exists(select 1 from maths.runtime_questions r where r.question_id=q.question_id and r.runtime_active and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI'))
        when q.scope_type='family' then exists(select 1 from maths.question_families f join maths.runtime_questions r on r.question_id=f.question_id where f.family_id=q.scope_id and f.active and r.runtime_active and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI'))
        when q.scope_type='concept' then exists(select 1 from maths.question_concepts c join maths.runtime_questions r on r.question_id=c.question_id where c.concept_id=q.scope_id and c.active and r.runtime_active and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI'))
        else true end academic_scope
    from maths.repair_queue q where q.user_id=uid
  )
  select count(*) filter(where priority='P0' and status in('open','waiting_confirmation') and academic_scope),
         count(*) filter(where due_at<=now() and status in('open','waiting_confirmation') and academic_scope)
  into p0_,due_ from rq;

  select count(distinct fs.family_id) into persistent_
  from maths.family_state fs
  where fs.user_id=uid and fs.persistent_weak and exists(
    select 1 from maths.question_families f join maths.runtime_questions r on r.question_id=f.question_id
    where f.family_id=fs.family_id and f.active and r.runtime_active
      and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI'));
  select count(distinct fs.family_id) into cold_
  from maths.family_state fs
  where fs.user_id=uid and fs.cold_confirmed and exists(
    select 1 from maths.question_families f join maths.runtime_questions r on r.question_id=f.question_id
    where f.family_id=fs.family_id and f.active and r.runtime_active
      and not (r.bank_calculation or r.in_calc_set or upper(coalesce(r.practice_bank,''))='CALCULATION_AI'));

  sprint_:=maths._sprint_stability(uid);
  recommendations:=jsonb_build_array(
    jsonb_build_object('kind','repair','label',greatest(3,least(5,coalesce(due_,0)))||' Repairs','href','/maths/repair',
      'priority',case when coalesce(p0_,0)>0 or coalesce(due_,0)>0 then 1 else 4 end),
    jsonb_build_object('kind','sprint','label','25Q Section Sprint','href','/maths/exam',
      'priority',case when phase_>=3 then 1 else 3 end),
    jsonb_build_object('kind','approach','label','Approach Scan','href','/maths/approach',
      'priority',case when coalesce((reasons_->>'APP')::int,0)>0 or persistent_>0 then 2 else 4 end)
  );
  return jsonb_build_object(
    'ok',true,'studyDay',maths._study_day(),'examDay',day_,'daysLeft',coalesce((state_->>'daysLeft')::int,0),'planDays',coalesce((state_->>'planDays')::int,30),
    'phase',phase_,'phaseLabel',case phase_ when 1 then 'Diagnosis + leakage removal' when 2 then 'Speed conversion' when 3 then 'Exam transfer' else 'Score stabilization' end,
    'knowledge',jsonb_build_object('score',knowledge_,'graded',coalesce(graded_,0),'correct',coalesce(correct_,0),'coldConfirmedFamilies',coalesce(cold_,0)),
    'performance',jsonb_build_object('score',performance_,'cleanCorrect',coalesce(clean_,0),'slowOrWrong',greatest(0,coalesce(graded_,0)-coalesce(clean_,0))),
    'repair',jsonb_build_object('p0',coalesce(p0_,0),'due',coalesce(due_,0),'persistentFamilies',coalesce(persistent_,0),'diagnosisPending',coalesce(diagnosis_,0)),
    'leakage',coalesce(reasons_,'{}'::jsonb),'biggestLeak',top_reason,'sprint',sprint_,'recommendations',recommendations
  );
end
$$;

grant execute on function public.maths_get_readiness() to authenticated;
grant execute on function public.maths_get_home_snapshot() to authenticated;
grant execute on function public.maths_get_concepts_hub() to authenticated;
grant execute on function public.maths_start_concepts(text,text,text,integer) to authenticated;
grant execute on function public.maths_set_concept(text,boolean) to authenticated;
grant execute on function public.maths_get_demand_hub() to authenticated;
grant execute on function public.maths_get_ondemand_hub() to authenticated;

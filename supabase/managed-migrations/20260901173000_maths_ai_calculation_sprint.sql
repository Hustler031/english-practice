-- Isolated AI-quality Calculation Sprint for Maths Exam Prep.
-- Generated calculation items remain outside Academic banks/Concepts/Daily selection.

create table if not exists maths.generated_calculation_meta(
  question_id text primary key references maths.questions(question_id) on delete cascade,
  skill text not null,
  pattern_key text not null,
  expected_sec numeric not null check(expected_sec between 3 and 60),
  quality_score numeric not null check(quality_score between 0 and 1),
  trap_tested text not null default '',
  verification text not null default '',
  generation_id uuid not null,
  created_at timestamptz not null default now()
);
revoke all on table maths.generated_calculation_meta from anon,authenticated;

create table if not exists maths.calculation_ai_usage(
  usage_id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  request_group uuid not null,
  request_type text not null,
  model text not null,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  reasoning_tokens integer not null default 0,
  total_tokens integer not null default 0,
  response_id text,
  session_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists calculation_ai_usage_user_created_idx on maths.calculation_ai_usage(user_id,created_at desc);
revoke all on table maths.calculation_ai_usage from anon,authenticated;

create or replace function public.maths_log_calculation_ai_usage(
  p_request_group uuid,p_request_type text,p_model text,p_input_tokens integer default 0,
  p_output_tokens integer default 0,p_reasoning_tokens integer default 0,p_total_tokens integer default 0,
  p_response_id text default null,p_session_id text default null,p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid();
begin
  insert into maths.calculation_ai_usage(user_id,request_group,request_type,model,input_tokens,output_tokens,reasoning_tokens,total_tokens,response_id,session_id,metadata)
  values(uid,p_request_group,coalesce(p_request_type,'unknown'),coalesce(p_model,'unknown'),greatest(0,coalesce(p_input_tokens,0)),greatest(0,coalesce(p_output_tokens,0)),greatest(0,coalesce(p_reasoning_tokens,0)),greatest(0,coalesce(p_total_tokens,0)),p_response_id,p_session_id,coalesce(p_metadata,'{}'::jsonb));
  return jsonb_build_object('ok',true);
end;
$$;
grant execute on function public.maths_log_calculation_ai_usage(uuid,text,text,integer,integer,integer,integer,text,text,jsonb) to authenticated;

create or replace function maths._baseline_sec(p_uid uuid,p_question_id text,p_before timestamptz default now())
returns numeric
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  family_ text; chapter_ text; fallback_ numeric:=30; n_ int; med_ numeric; generated_expected numeric;
begin
  select expected_sec into generated_expected from maths.generated_calculation_meta where question_id=p_question_id;
  if generated_expected is not null then return greatest(3,generated_expected); end if;

  select q.template_group,q.chapter,
         case when maths._norm(q.chapter) in ('geometry','coordinate geometry') or length(coalesce(q.prompt,''))>=220 then 45 else 30 end
  into family_,chapter_,fallback_
  from maths.runtime_questions q where q.question_id=p_question_id;

  select count(*),percentile_cont(.5) within group(order by response_sec)
  into n_,med_ from (
    select a.response_sec from maths.attempts a
    where a.user_id=p_uid and a.question_id=p_question_id and a.attempted_at<p_before and a.response_sec>0
      and lower(coalesce(a.result,'')) in('correct','wrong')
    order by a.attempted_at desc limit 12
  ) x;
  if n_>=3 and med_ is not null then return greatest(3,med_); end if;

  if nullif(btrim(family_),'') is not null then
    select count(*),percentile_cont(.5) within group(order by response_sec)
    into n_,med_ from (
      select a.response_sec from maths.attempts a join maths.runtime_questions q on q.question_id=a.question_id
      where a.user_id=p_uid and q.template_group=family_ and a.attempted_at<p_before and a.response_sec>0
        and lower(coalesce(a.result,'')) in('correct','wrong')
      order by a.attempted_at desc limit 40
    ) x;
    if n_>=5 and med_ is not null then return greatest(3,med_); end if;
  end if;

  select count(*),percentile_cont(.5) within group(order by response_sec)
  into n_,med_ from (
    select a.response_sec from maths.attempts a join maths.runtime_questions q on q.question_id=a.question_id
    where a.user_id=p_uid and maths._norm(q.chapter)=maths._norm(chapter_) and a.attempted_at<p_before and a.response_sec>0
      and lower(coalesce(a.result,'')) in('correct','wrong')
    order by a.attempted_at desc limit 60
  ) x;
  if n_>=8 and med_ is not null then return greatest(3,med_); end if;
  return fallback_;
end;
$$;

create or replace function maths._calculation_ids(p_uid uuid,p_count integer,p_skill text default null)
returns text[]
language sql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
with c as (
  select r.question_id,coalesce(nullif(q.topic,''),nullif(q.subtopic,''),'Mixed') skill,
         case when r.profile_last_result='wrong' then 70 else 0 end
         +case when r.last_response_sec>greatest(6,r.expected_sec*.35) then 35 else 0 end
         +case when upper(coalesce(q.practice_bank,''))='CALCULATION_AI' then 18 else 0 end
         +coalesce((select 20*count(*) from maths.performance_evidence e
                    where e.user_id=p_uid and e.question_id=r.question_id and e.created_at>=now()-interval '14 days'
                      and (e.final_reason='CAL' or e.slow_correct)),0) score,
         row_number() over(partition by coalesce(nullif(q.topic,''),nullif(q.subtopic,''),'Mixed')
                           order by (r.profile_last_result='wrong') desc,r.last_response_sec desc,random()) skill_rank
  from maths._user_runtime(p_uid) r join maths.runtime_questions q using(question_id)
  where r.runtime_active
    and (r.bank_calculation or r.in_calc_set or upper(coalesce(q.practice_bank,''))='CALCULATION_AI')
    and (upper(coalesce(q.practice_bank,''))='CALCULATION_AI' or maths._calc_type(q) in('METHOD','DRILL'))
    and (p_skill is null or maths._norm(coalesce(q.topic,q.subtopic,'Mixed'))=maths._norm(p_skill))
)
select coalesce(array_agg(question_id order by skill_rank,score desc,random()),array[]::text[])
from (select * from c order by skill_rank,score desc,random() limit greatest(1,least(coalesce(p_count,30),100))) x
$$;

create or replace function public.maths_get_calculation_hub()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); body jsonb;
begin
  with c as materialized (
    select r.*,maths._calc_type(q) calc_type,coalesce(nullif(q.topic,''),nullif(q.subtopic,''),'Mixed') skill,
           upper(coalesce(q.practice_bank,''))='CALCULATION_AI' ai_generated
    from maths._user_runtime(uid) r join maths.runtime_questions q using(question_id)
    where r.runtime_active
      and (r.bank_calculation or r.in_calc_set or upper(coalesce(q.practice_bank,''))='CALCULATION_AI')
      and (upper(coalesce(q.practice_bank,''))='CALCULATION_AI' or maths._calc_type(q)<>'MEMORY' or maths._calc_recall_eligible(q))
  ),
  skill_perf as (
    select skill,count(*) total,count(*) filter(where calc_type='MEMORY' and not ai_generated) memory,
      count(*) filter(where calc_type='METHOD' and not ai_generated) methods,
      count(*) filter(where calc_type='DRILL' or ai_generated) drills,
      count(*) filter(where ai_generated) ai,
      count(*) filter(where profile_total>0) attempted,
      avg(profile_accuracy) filter(where profile_graded>0) accuracy,
      percentile_cont(.5) within group(order by nullif(last_response_sec,0)) median_sec,
      percentile_cont(.5) within group(order by expected_sec) baseline_sec,
      count(*) filter(where profile_last_result='wrong' or last_response_sec>expected_sec) leakage
    from c group by skill
  ),
  focus as(select skill,leakage from skill_perf order by leakage desc,skill limit 2)
  select jsonb_build_object(
    'ok',true,'total',count(*),'memory',count(*) filter(where calc_type='MEMORY' and not ai_generated),
    'methods',count(*) filter(where calc_type='METHOD' and not ai_generated),'drills',count(*) filter(where calc_type='DRILL' or ai_generated),
    'aiGenerated',count(*) filter(where ai_generated),'slow',count(*) filter(where last_response_sec>=8),'wrong',count(*) filter(where profile_last_result='wrong'),
    'durationSec',600,
    'skills',coalesce((select jsonb_agg(jsonb_build_object(
      'skill',skill,'total',total,'memory',memory,'methods',methods,'drills',drills,'aiGenerated',ai,'attempted',attempted,
      'accuracy',case when accuracy is null then null else round((100*accuracy)::numeric,1) end,
      'medianSec',round(coalesce(median_sec,0)::numeric,1),'baselineSec',round(coalesce(baseline_sec,0)::numeric,1),
      'band',case
        when attempted>=3 and coalesce(accuracy,0)>=.95 and coalesce(median_sec,999)<=coalesce(baseline_sec,30)*.8 then 'Automatic'
        when attempted>=3 and coalesce(accuracy,0)>=.90 and coalesce(median_sec,999)<=coalesce(baseline_sec,30) then 'Strong'
        when attempted>=2 and coalesce(accuracy,0)>=.80 then 'Almost there' else 'Needs work' end
    ) order by leakage desc,skill) from skill_perf),'[]'::jsonb),
    'todayFocus',coalesce((select jsonb_agg(skill order by leakage desc,skill) from focus),'[]'::jsonb)
  ) into body from c;
  return body;
end;
$$;
grant execute on function public.maths_get_calculation_hub() to authenticated;

create or replace function public.maths_get_calculation_generation_context(p_session_id text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); seeds jsonb; recent jsonb; skills jsonb; state_ jsonb:=maths._exam_prep_state();
begin
  if p_session_id is not null and not exists(select 1 from maths.sessions where session_id=p_session_id and user_id=uid) then
    raise exception 'Calculation session not found';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'questionId',x.question_id,'skill',x.topic,'prompt',x.prompt,'answer',x.answer,'difficulty',x.difficulty,
    'template',x.template_group,'type',maths._calc_type(x)
  )),'[]'::jsonb) into seeds
  from (
    select q.* from maths.runtime_questions q
    where q.runtime_active and (q.bank_calculation or q.in_calc_set)
      and maths._calc_type(q) in('METHOD','DRILL')
      and upper(coalesce(q.practice_bank,''))<>'CALCULATION_AI'
    order by random() limit 28
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object('prompt',q.prompt,'pattern',m.pattern_key,'skill',m.skill) order by s.created_at desc),'[]'::jsonb)
  into recent
  from maths.sessions s join maths.session_questions sq on sq.session_id=s.session_id
  join maths.runtime_questions q on q.question_id=sq.question_id
  left join maths.generated_calculation_meta m on m.question_id=q.question_id
  where s.user_id=uid and lower(coalesce(s.mode,''))='calculation_speed'
    and upper(coalesce(q.practice_bank,''))='CALCULATION_AI' and s.created_at>=now()-interval '7 days'
  limit 100;

  skills:=public.maths_get_calculation_hub()->'skills';
  return jsonb_build_object(
    'ok',true,'examDay',coalesce((state_->>'day')::int,1),'durationSec',600,
    'objective','SSC arithmetic automaticity used inside real exam solving; calculation-only, not chapter concept practice',
    'skills',skills,'seedPatterns',seeds,'recentGenerated',recent,
    'qualityContract',jsonb_build_object('minQuality',0.90,'fourOptions',true,'oneDefensibleAnswer',true,'noPYQClaim',true,'moderateHardOnly',true)
  );
end;
$$;
grant execute on function public.maths_get_calculation_generation_context(text) to authenticated;

create or replace function maths._insert_ai_calculation_item(p_item jsonb,p_generation_id uuid)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare
  qid text:='CAI_'||replace(gen_random_uuid()::text,'-','');
  skill_ text;
  pattern_ text;
  correct_ text;
  oa text;
  ob text;
  oc text;
  od text;
  answer_ text;
  expected_ numeric;
  quality_ numeric;
  expected_answer_ text;
  option_count_ integer;
begin
  if p_item is null or jsonb_typeof(p_item)<>'object' then
    raise exception 'Invalid generated calculation item';
  end if;
  if jsonb_typeof(p_item->'options')<>'array' or jsonb_array_length(p_item->'options')<>4 then
    raise exception 'Generated calculation item must have four options';
  end if;

  skill_:=nullif(btrim(p_item->>'skill'),'');
  pattern_:=nullif(btrim(p_item->>'patternKey'),'');
  correct_:=upper(coalesce(p_item->>'correctKey',''));
  answer_:=nullif(btrim(p_item->>'answerText'),'');
  expected_:=coalesce(nullif(p_item->>'expectedSec','')::numeric,0);
  quality_:=coalesce(nullif(p_item->>'qualityScore','')::numeric,0);

  if skill_ is null or pattern_ is null or nullif(btrim(p_item->>'question'),'') is null then
    raise exception 'Generated calculation item is incomplete';
  end if;
  if correct_ not in('A','B','C','D') then
    raise exception 'Generated calculation correct key is invalid';
  end if;
  if expected_<3 or expected_>60 or quality_<.90 then
    raise exception 'Generated calculation quality contract failed';
  end if;

  select
    max(o->>'text') filter(where upper(o->>'key')='A'),
    max(o->>'text') filter(where upper(o->>'key')='B'),
    max(o->>'text') filter(where upper(o->>'key')='C'),
    max(o->>'text') filter(where upper(o->>'key')='D'),
    count(distinct o->>'text')
  into oa,ob,oc,od,option_count_
  from jsonb_array_elements(p_item->'options') o;

  if oa is null or ob is null or oc is null or od is null or option_count_<>4 then
    raise exception 'Generated calculation options are invalid';
  end if;

  expected_answer_:=case correct_
    when 'A' then oa
    when 'B' then ob
    when 'C' then oc
    else od
  end;
  if answer_ is null or answer_<>expected_answer_ then
    raise exception 'Generated calculation answer does not match correct option';
  end if;

  insert into maths.questions(
    question_id,chapter,topic,subtopic,card_type,prompt,answer,explanation,memory_cue,difficulty,
    status,answer_mode,option_a,option_b,option_c,option_d,correct_option,template_group,variant_types,
    rotation_tier,practice_bank,added_at,generated
  ) values(
    qid,'Calculation Training',skill_,pattern_,'DRILL',p_item->>'question',answer_,p_item->>'explanation',coalesce(p_item->>'trapTested',''),
    coalesce(nullif(p_item->>'difficulty',''),'Hard'),'active','MCQ',oa,ob,oc,od,correct_,
    'CALC_AI_'||upper(trim(both '_' from regexp_replace(pattern_,'[^A-Za-z0-9]+','_','g'))),'AI_CALC','ExamPrep','CALCULATION_AI',now(),true
  );
  insert into maths.generated_calculation_meta(question_id,skill,pattern_key,expected_sec,quality_score,trap_tested,verification,generation_id)
  values(qid,skill_,pattern_,expected_,quality_,coalesce(p_item->>'trapTested',''),coalesce(p_item->>'verification',''),p_generation_id);
  return qid;
end;
$$;

create or replace function public.maths_create_ai_calculation_session(p_items jsonb,p_generation_id uuid default gen_random_uuid())
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); ids text[]:=array[]::text[]; item jsonb; qid text; state_ jsonb:=maths._exam_prep_state(); active_id text;
begin
  perform pg_advisory_xact_lock(hashtext(uid::text||':timed-exam-start'));
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<20 or jsonb_array_length(p_items)>50 then
    raise exception 'AI Calculation Sprint requires 20 to 50 quality-checked items';
  end if;
  select session_id into active_id from maths.sessions
  where user_id=uid and not completed and (
    lower(coalesce(mode,''))='section_sprint' or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
  ) order by updated_at desc nulls last,created_at desc limit 1;
  if active_id is not null then raise exception 'A timed Maths session is already active'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    qid:=maths._insert_ai_calculation_item(item,p_generation_id); ids:=array_append(ids,qid);
  end loop;
  return maths._start_session(uid,ids,'calculation_speed','10-Min SSC Calculation Sprint',jsonb_build_object(
    'mode','timed','durationSec',600,'calculationTimed',true,'aiGenerated',true,'qualityControlled',true,
    'refillBatch',16,'examPrep',true,'examPrepDay',coalesce((state_->>'day')::int,1),'generationId',p_generation_id::text
  ),false);
end;
$$;
grant execute on function public.maths_create_ai_calculation_session(jsonb,uuid) to authenticated;

create or replace function public.maths_append_ai_calculation_items(p_session_id text,p_items jsonb,p_generation_id uuid default gen_random_uuid())
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); s maths.sessions%rowtype; item jsonb; qid text; ids text[]:=array[]::text[]; pos_ int; rendered jsonb;
begin
  perform pg_advisory_xact_lock(hashtext(uid::text||':'||p_session_id||':ai-calc-refill'));
  select * into s from maths.sessions where session_id=p_session_id and user_id=uid and lower(coalesce(mode,''))='calculation_speed';
  if not found or coalesce(s.params->>'aiGenerated','false')<>'true' or coalesce(s.params->>'calculationTimed','false')<>'true' then
    raise exception 'AI Calculation Sprint not found';
  end if;
  if s.completed then return maths._get_session(uid,p_session_id); end if;
  if nullif(s.params->>'deadlineAt','') is not null and (s.params->>'deadlineAt')::timestamptz<=now() then return maths._get_session(uid,p_session_id); end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<5 or jsonb_array_length(p_items)>30 then raise exception 'AI Calculation refill requires 5 to 30 items'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    qid:=maths._insert_ai_calculation_item(item,p_generation_id); ids:=array_append(ids,qid);
  end loop;
  select coalesce(max(position),-1)+1 into pos_ from maths.session_questions where session_id=p_session_id;
  foreach qid in array ids loop
    insert into maths.session_questions(session_id,question_id,position) values(p_session_id,qid,pos_); pos_:=pos_+1;
  end loop;
  rendered:=maths._render_questions(uid,ids,false);
  update maths.sessions set rendered_questions=coalesce(rendered_questions,'[]'::jsonb)||rendered,updated_at=now()
  where session_id=p_session_id and user_id=uid;
  return maths._get_session(uid,p_session_id);
end;
$$;
grant execute on function public.maths_append_ai_calculation_items(text,jsonb,uuid) to authenticated;

create or replace function public.maths_refill_calculation_session(p_session_id text,p_count integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); s maths.sessions%rowtype; existing text[]; ids text[]; qid text; pos_ int; rendered jsonb;
begin
  perform pg_advisory_xact_lock(hashtext(uid::text||':'||p_session_id||':calc-refill'));
  select * into s from maths.sessions where session_id=p_session_id and user_id=uid and lower(coalesce(mode,''))='calculation_speed';
  if not found or coalesce((s.params->>'calculationTimed')::boolean,false)=false then raise exception 'Timed calculation session not found'; end if;
  if s.completed or coalesce(s.params->>'aiGenerated','false')='true' then return maths._get_session(uid,p_session_id); end if;
  select coalesce(array_agg(question_id),array[]::text[]) into existing from maths.session_questions where session_id=p_session_id;
  ids:=array(select x from unnest(maths._calculation_ids(uid,greatest(30,least(coalesce(p_count,20)*3,100)),nullif(s.params->>'skill',''))) x
             where not x=any(existing) limit greatest(1,least(coalesce(p_count,20),40)));
  if coalesce(array_length(ids,1),0)=0 then return maths._get_session(uid,p_session_id); end if;
  select coalesce(max(position),-1)+1 into pos_ from maths.session_questions where session_id=p_session_id;
  foreach qid in array ids loop insert into maths.session_questions(session_id,question_id,position) values(p_session_id,qid,pos_); pos_:=pos_+1; end loop;
  rendered:=maths._render_questions(uid,ids,false);
  update maths.sessions set rendered_questions=coalesce(rendered_questions,'[]'::jsonb)||rendered,updated_at=now() where session_id=p_session_id and user_id=uid;
  return maths._get_session(uid,p_session_id);
end;
$$;

create or replace function public.maths_abandon_exam_session(p_session_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); s maths.sessions%rowtype;
begin
  select * into s from maths.sessions where session_id=p_session_id and user_id=uid;
  if not found then raise exception 'Timed session not found'; end if;
  if not (lower(coalesce(s.mode,''))='section_sprint' or (lower(coalesce(s.mode,''))='calculation_speed' and coalesce(s.params->>'calculationTimed','false')='true')) then
    raise exception 'Only timed Exam Prep sessions can be abandoned';
  end if;
  update maths.sessions set completed=true,updated_at=now(),params=coalesce(params,'{}'::jsonb)||jsonb_build_object('abandoned',true,'abandonedAt',now()::text,'finishedAt',now()::text)
  where session_id=p_session_id and user_id=uid;
  return jsonb_build_object('ok',true,'abandoned',true,'sessionId',p_session_id);
end;
$$;
grant execute on function public.maths_abandon_exam_session(text) to authenticated;

create or replace function public.maths_get_active_exam_session()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); s maths.sessions%rowtype; total_ int; remaining_ numeric;
begin
  select * into s from maths.sessions
  where user_id=uid and not completed and (
    lower(coalesce(mode,''))='section_sprint' or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
  ) order by updated_at desc nulls last,created_at desc limit 1;
  if not found then return jsonb_build_object('ok',true,'active',false); end if;
  select count(*) into total_ from maths.session_questions where session_id=s.session_id;
  remaining_:=case when nullif(s.params->>'deadlineAt','') is not null then greatest(0,extract(epoch from ((s.params->>'deadlineAt')::timestamptz-now()))) else null end;
  return jsonb_build_object(
    'ok',true,'active',true,'sessionId',s.session_id,'mode',s.mode,'title',s.title,
    'track',case when lower(coalesce(s.mode,''))='section_sprint' then 'academic' else 'calculation' end,
    'currentIndex',greatest(0,least(s.current_index,greatest(0,total_-1))),'target',total_,'remainingSeconds',remaining_,
    'expired',coalesce(remaining_<=0,false),'aiGenerated',coalesce(s.params->>'aiGenerated','false')='true',
    'review',coalesce(s.params->'examReview','[]'::jsonb),'visited',coalesce(s.params->'examVisited','[]'::jsonb)
  );
end;
$$;
grant execute on function public.maths_get_active_exam_session() to authenticated;

create or replace function public.maths_start_sprint(p_diagnostic boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare uid uuid:=maths._require_uid(); ids text[]; active_id text; state_ jsonb:=maths._exam_prep_state();
begin
  perform pg_advisory_xact_lock(hashtext(uid::text||':timed-exam-start'));
  update maths.sessions set completed=true,updated_at=now(),params=jsonb_set(coalesce(params,'{}'::jsonb),'{finishedAt}',to_jsonb(now()::text),true)
  where user_id=uid and not completed and (
    lower(coalesce(mode,''))='section_sprint' or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
  ) and nullif(params->>'deadlineAt','') is not null and (params->>'deadlineAt')::timestamptz<=now();
  select session_id into active_id from maths.sessions where user_id=uid and not completed and (
    lower(coalesce(mode,''))='section_sprint' or (lower(coalesce(mode,''))='calculation_speed' and coalesce(params->>'calculationTimed','false')='true')
  ) order by updated_at desc nulls last,created_at desc limit 1;
  if active_id is not null then return maths._get_session(uid,active_id); end if;
  ids:=maths._sprint_ids(uid,25);
  return maths._start_session(uid,ids,'section_sprint','SSC Maths Section Sprint',jsonb_build_object(
    'durationSec',900,'questionCount',25,'marksCorrect',2,'marksWrong',-.5,'selectionCapture',coalesce(p_diagnostic,false),
    'examMode',true,'examPrep',true,'examPrepDay',coalesce((state_->>'day')::int,1),'academicOnly',true,
    'freshnessPolicy','served_or_attempted','coolingHours',48
  ),false);
end;
$$;
grant execute on function public.maths_start_sprint(boolean) to authenticated;

create or replace function maths._sprint_stability(p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','maths'
as $$
declare out_ jsonb;
begin
  with last_sprints as (
    select s.session_id,s.created_at,maths._session_score(p_uid,s.session_id) score,
      (select count(*) from maths.attempts a where a.user_id=p_uid and a.session_id=s.session_id) attempted,
      (select avg(a.response_sec) from maths.attempts a where a.user_id=p_uid and a.session_id=s.session_id and a.response_sec>0) avg_sec
    from maths.sessions s
    where s.user_id=p_uid and lower(coalesce(s.mode,''))='section_sprint' and s.completed
      and coalesce(s.params->>'examPrep','false')='true' and coalesce(s.params->>'abandoned','false')<>'true'
    order by s.updated_at desc limit 10
  )
  select jsonb_build_object(
    'count',count(*),'best',max(score),'median',round(percentile_cont(.5) within group(order by score)::numeric,2),
    'badDayFloor',round(percentile_cont(.2) within group(order by score)::numeric,2),
    'range',case when count(*)>0 then jsonb_build_array(min(score),max(score)) else '[]'::jsonb end,
    'variance',round(coalesce(var_pop(score),0),2),'attemptedAvg',round(avg(attempted),1),'avgSec',round(avg(avg_sec),1),
    'scores',coalesce(jsonb_agg(jsonb_build_object('score',score,'at',created_at) order by created_at),'[]'::jsonb)
  ) into out_ from last_sprints;
  return coalesce(out_,jsonb_build_object('count',0));
end;
$$;

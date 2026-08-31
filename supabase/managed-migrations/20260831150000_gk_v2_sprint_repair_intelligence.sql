-- GK V2 Section Sprint diagnostic evidence -> intelligent repair loop.
-- Forward-only. Raw Sprint answers remain isolated in gk.exam_answers; adaptive
-- Attempts / Exposures / QuestionState are never written by Sprint finalization or analysis.

begin;

alter table gk.exam_sessions
  add column if not exists source_kind text not null default 'EXAM_MIXED',
  add column if not exists analysis_generated_at timestamptz null,
  add column if not exists analysis_meta jsonb not null default '{}'::jsonb;

create table if not exists gk.exam_diagnostics(
  diagnostic_id text primary key,
  session_id text not null references gk.exam_sessions(session_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_key text not null,
  concept_id text null,
  subject text not null default '',
  topic text not null default '',
  question_ids jsonb not null default '[]'::jsonb,
  wrong_count integer not null default 0,
  unattempted_count integer not null default 0,
  slow_count integer not null default 0,
  slow_wrong_count integer not null default 0,
  fast_wrong_count integer not null default 0,
  historical_wrong_count integer not null default 0,
  current_learning_state text not null default 'New',
  retention_attempts integer not null default 0,
  retention_correct integer not null default 0,
  unconfirmed_guess boolean not null default false,
  due boolean not null default false,
  teacher_pyq boolean not null default false,
  repeated_concept_loss boolean not null default false,
  priority_score integer not null default 0,
  recommendation_reason text not null default '',
  generated_at timestamptz not null default now(),
  repair_started_at timestamptz null,
  repair_completed_at timestamptz null,
  unique(session_id,concept_key)
);

create index if not exists gk_exam_diagnostics_user_session_idx
  on gk.exam_diagnostics(user_id,session_id,priority_score desc);
create index if not exists gk_exam_diagnostics_user_concept_idx
  on gk.exam_diagnostics(user_id,concept_id,generated_at desc);

alter table gk.exam_diagnostics enable row level security;
drop policy if exists gk_exam_diagnostics_owner on gk.exam_diagnostics;
create policy gk_exam_diagnostics_owner on gk.exam_diagnostics
  for select to authenticated using(user_id=auth.uid());

revoke all on gk.exam_diagnostics from public,anon,authenticated;
grant select on gk.exam_diagnostics to authenticated;

-- Preserve the original one-argument starter. The two-argument overload adds a
-- source dimension without breaking old callers or creating a second exam engine.
create or replace function public.gk_start_section_sprint(p_count integer,p_source text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  n integer:=greatest(1,least(50,coalesce(p_count,25)));
  source_kind text:=case upper(coalesce(nullif(btrim(p_source),''),'EXAM_MIXED'))
    when 'TEACHER_PYQ' then 'TEACHER_PYQ' else 'EXAM_MIXED' end;
  sid text;
  qs jsonb:='[]'::jsonb;
  actual_n integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  if source_kind='TEACHER_PYQ' then
    with pool as(
      select distinct q.question_id
      from gk.questions q
      join gk.question_source_memberships m on m.question_id=q.question_id
      join gk.content_series cs on cs.series_id=m.series_id
      where q.active
        and upper(coalesce(q.content_lane,'MAIN'))='MAIN'
        and cs.active
        and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ')
    ), picked as(
      select question_id,random() r from pool order by r limit n
    )
    select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,question_id) order by r),'[]'::jsonb)
      into qs from picked;
  else
    qs:=coalesce(public.gk_get_batch('random',n,'MAIN',null,null,null,null,null,null,null),'[]'::jsonb);
  end if;

  actual_n:=jsonb_array_length(qs);
  if actual_n=0 then
    return jsonb_build_object('ok',false,'error','No eligible unique questions are available for this Sprint source','sourceKind',source_kind,'actualCount',0);
  end if;

  sid:='gk-sprint-'||substr(md5(uid::text||clock_timestamp()::text||random()::text),1,24);
  insert into gk.exam_sessions(session_id,user_id,mode,question_ids,duration_seconds,source_kind)
  values(
    sid,uid,'SECTION_SPRINT',
    coalesce((select jsonb_agg(v->>'id') from jsonb_array_elements(qs) v),'[]'::jsonb),
    900,source_kind
  );

  return jsonb_build_object(
    'ok',true,'sessionId',sid,'durationSeconds',900,'startedAt',now(),
    'questions',qs,'sourceKind',source_kind,'actualCount',actual_n
  );
end;
$$;

revoke all on function public.gk_start_section_sprint(integer,text) from public,anon;
grant execute on function public.gk_start_section_sprint(integer,text) to authenticated;

-- Keep score saving independent from diagnostics. Repeated Finish returns the
-- immutable stored score and never converts exam answers into adaptive Attempts.
create or replace function public.gk_finish_section_sprint(p_session_id text,p_answers jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  item record;
  total integer;
  correct_n integer;
  wrong_n integer;
  attempted_n integer;
  result_json jsonb;
  already_complete boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select completed,result into already_complete,result_json
  from gk.exam_sessions
  where session_id=p_session_id and user_id=uid;

  if not found then raise exception 'Sprint not found'; end if;
  if already_complete and result_json is not null then
    return jsonb_build_object('ok',true,'sessionId',p_session_id,'result',result_json,'learningHistoryChanged',false,'deduped',true);
  end if;

  for item in select key question_id,value answer from jsonb_each(coalesce(p_answers,'{}'::jsonb)) loop
    if exists(
      select 1
      from gk.exam_sessions s,
           jsonb_array_elements_text(s.question_ids) as ids(question_id)
      where s.session_id=p_session_id and s.user_id=uid and ids.question_id=item.question_id
    ) then
      insert into gk.exam_answers(session_id,question_id,selected_option,is_correct,response_ms)
      select p_session_id,q.question_id,upper(nullif(item.answer->>'selected','')),
             upper(nullif(item.answer->>'selected',''))=upper(coalesce(q.correct_option,'')),
             greatest(0,coalesce((item.answer->>'responseMs')::integer,0))
      from gk.questions q
      where q.question_id=item.question_id and q.active
      on conflict(session_id,question_id) do nothing;
    end if;
  end loop;

  select jsonb_array_length(question_ids) into total
  from gk.exam_sessions
  where session_id=p_session_id and user_id=uid;

  select count(*) filter(where is_correct),count(*) filter(where is_correct is false),count(*)
  into correct_n,wrong_n,attempted_n
  from gk.exam_answers a
  where a.session_id=p_session_id
    and exists(select 1 from gk.exam_sessions s where s.session_id=a.session_id and s.user_id=uid);

  result_json:=jsonb_build_object(
    'total',total,'attempted',attempted_n,
    'score',round((correct_n*2.0-wrong_n*0.5)::numeric,2),'maxScore',total*2,
    'correct',correct_n,'wrong',wrong_n,'unattempted',greatest(0,total-attempted_n),
    'accuracy',case when attempted_n=0 then 0 else round(correct_n*100.0/attempted_n,1) end,
    'averageTimeMs',coalesce((
      select round(avg(response_ms))::integer from gk.exam_answers
      where session_id=p_session_id and response_ms>0
    ),0),
    'marksLostWrong',round((wrong_n*0.5)::numeric,2),
    'marksLostUnattempted',greatest(0,total-attempted_n)*2
  );

  update gk.exam_sessions
  set completed=true,completed_at=coalesce(completed_at,now()),result=result_json
  where session_id=p_session_id and user_id=uid;

  return jsonb_build_object('ok',true,'sessionId',p_session_id,'result',result_json,'learningHistoryChanged',false,'deduped',false);
end;
$$;

revoke all on function public.gk_finish_section_sprint(text,jsonb) from public,anon;
grant execute on function public.gk_finish_section_sprint(text,jsonb) to authenticated;

create or replace function public.gk_get_section_sprint_analysis(p_session_id text)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with s as(
  select * from gk.exam_sessions
  where session_id=p_session_id and user_id=auth.uid()
), thresholds as(
  select
    coalesce((select (analysis_meta->>'slowMs')::integer from s),30000) slow_ms,
    coalesce((select (analysis_meta->>'fastMs')::integer from s),6000) fast_ms
), p as(
  select * from gk.learning_profiles_v2(auth.uid())
), qrows as(
  select ids.ord,q.question_id,gk.canonical_subject(q.subject) subject,
         coalesce(nullif(q.topic,''),'General') topic,q.concept_id,
         a.selected_option,a.is_correct,a.response_ms,
         p.learning_state,p.unconfirmed_guess,p.due
  from s
  cross join lateral jsonb_array_elements_text(s.question_ids) with ordinality ids(question_id,ord)
  join gk.questions q on q.question_id=ids.question_id
  left join gk.exam_answers a on a.session_id=p_session_id and a.question_id=q.question_id
  left join p on p.question_id=q.question_id
), classified as(
  select q.*,
    case
      when selected_option is null then 'Unattempted'
      when is_correct and response_ms>=(select slow_ms from thresholds) then 'Slow Correct'
      when is_correct then 'Correct'
      when response_ms>=(select slow_ms from thresholds) then 'Slow Wrong'
      when response_ms>0 and response_ms<=(select fast_ms from thresholds) then 'Fast Wrong'
      else 'Wrong'
    end classification,
    coalesce(learning_state,'New') in('Persistent Weak','Weak','Fragile') repeat_weakness
  from qrows q
), subjects as(
  select subject,count(*)::integer total,
    count(*) filter(where selected_option is not null)::integer attempted,
    count(*) filter(where is_correct)::integer correct,
    count(*) filter(where is_correct is false)::integer wrong,
    count(*) filter(where selected_option is null)::integer unattempted,
    case when count(*) filter(where selected_option is not null)=0 then 0
      else round(count(*) filter(where is_correct)*100.0/nullif(count(*) filter(where selected_option is not null),0),1) end accuracy,
    round((count(*) filter(where is_correct is false)*0.5 + count(*) filter(where selected_option is null)*2.0)::numeric,2) marks_lost,
    count(distinct coalesce(nullif(concept_id,''),'Q:'||question_id))
      filter(where is_correct is false or selected_option is null)::integer concepts_needing_repair
  from classified group by subject
), issues as(
  select jsonb_build_object(
    'questionId',question_id,'subject',subject,'topic',topic,'conceptId',concept_id,
    'classification',classification,'responseMs',coalesce(response_ms,0),
    'repeatWeakness',repeat_weakness,'existingUnresolvedGuess',coalesce(unconfirmed_guess,false),
    'existingState',coalesce(learning_state,'New')
  ) row_json,ord
  from classified where classification<>'Correct'
), repairs as(
  select jsonb_build_object(
    'conceptKey',d.concept_key,'conceptId',d.concept_id,'subject',d.subject,'topic',d.topic,
    'questionIds',d.question_ids,'wrong',d.wrong_count,'unattempted',d.unattempted_count,
    'slow',d.slow_count,'fastWrong',d.fast_wrong_count,'existingState',d.current_learning_state,
    'retentionAttempts',d.retention_attempts,'retentionCorrect',d.retention_correct,
    'teacherPyq',d.teacher_pyq,'priorityScore',d.priority_score,'reason',d.recommendation_reason
  ) row_json,d.priority_score,d.subject,d.topic
  from gk.exam_diagnostics d
  where d.session_id=p_session_id and d.user_id=auth.uid()
)
select case
  when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
  when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found')
  else jsonb_build_object(
    'ok',true,'sessionId',p_session_id,
    'sourceKind',(select source_kind from s),
    'analysisReady',(select analysis_generated_at is not null from s),
    'generatedAt',(select analysis_generated_at from s),
    'result',(select result from s),
    'timeSignals',jsonb_build_object(
      'slowMs',(select slow_ms from thresholds),'fastMs',(select fast_ms from thresholds),
      'slowLabel','time-heavy response','fastWrongLabel','fast incorrect response'
    ),
    'marksLost',jsonb_build_object(
      'wrong',coalesce(((select result from s)->>'marksLostWrong')::numeric,0),
      'unattempted',coalesce(((select result from s)->>'marksLostUnattempted')::numeric,0)
    ),
    'questionIssues',coalesce((select jsonb_agg(row_json order by ord) from issues),'[]'::jsonb),
    'subjects',coalesce((select jsonb_agg(
      jsonb_build_object(
        'subject',subject,'total',total,'attempted',attempted,'correct',correct,'wrong',wrong,
        'unattempted',unattempted,'accuracy',accuracy,'marksLost',marks_lost,
        'conceptsNeedingRepair',concepts_needing_repair
      ) order by marks_lost desc,subject
    ) from subjects),'[]'::jsonb),
    'repairs',coalesce((select jsonb_agg(row_json order by priority_score desc,subject,topic) from repairs),'[]'::jsonb)
  )
end;
$$;

revoke all on function public.gk_get_section_sprint_analysis(text) from public,anon;
grant execute on function public.gk_get_section_sprint_analysis(text) to authenticated;

-- Analysis is a second idempotent mutation after score saving. If it fails, the
-- completed Sprint score remains durable and can be re-opened independently.
create or replace function public.gk_analyze_section_sprint(p_session_id text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  completed_now boolean;
  generated timestamptz;
  timed_n integer:=0;
  median_ms numeric:=15000;
  slow_ms integer:=30000;
  fast_ms integer:=6000;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select completed,analysis_generated_at into completed_now,generated
  from gk.exam_sessions
  where session_id=p_session_id and user_id=uid;

  if not found then raise exception 'Sprint not found'; end if;
  if not completed_now then raise exception 'Sprint must be completed before analysis'; end if;
  if generated is not null then return public.gk_get_section_sprint_analysis(p_session_id); end if;

  select count(*) filter(where response_ms>0),
         percentile_cont(0.5) within group(order by response_ms) filter(where response_ms>0)
  into timed_n,median_ms
  from gk.exam_answers
  where session_id=p_session_id;

  median_ms:=coalesce(median_ms,15000);
  if timed_n>=5 then
    slow_ms:=greatest(20000,round(median_ms*1.6)::integer);
    fast_ms:=least(8000,greatest(2500,round(median_ms*0.55)::integer));
  end if;

  with prof as(
    select * from gk.learning_profiles_v2(uid)
  ), raw as(
    select q.question_id,gk.canonical_subject(q.subject) subject,
           coalesce(nullif(q.topic,''),'General') topic,q.concept_id,
           coalesce(nullif(q.concept_id,''),'Q:'||q.question_id) concept_key,
           a.selected_option,a.is_correct,coalesce(a.response_ms,0) response_ms,
           coalesce(p.learning_state,'New') learning_state,
           coalesce(p.wrong,0) historical_wrong,
           coalesce(p.retention_attempts,0) retention_attempts,
           coalesce(p.retention_correct,0) retention_correct,
           coalesce(p.unconfirmed_guess,false) unconfirmed_guess,
           coalesce(p.due,false) due,
           exists(
             select 1 from gk.question_source_memberships m
             join gk.content_series cs on cs.series_id=m.series_id
             where m.question_id=q.question_id and cs.active
               and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ')
           ) teacher_pyq
    from gk.exam_sessions s
    cross join lateral jsonb_array_elements_text(s.question_ids) ids(question_id)
    join gk.questions q on q.question_id=ids.question_id
    left join gk.exam_answers a on a.session_id=s.session_id and a.question_id=q.question_id
    left join prof p on p.question_id=q.question_id
    where s.session_id=p_session_id and s.user_id=uid
  ), losses as(
    select *,
      (is_correct is false) wrong_now,
      (selected_option is null) unattempted_now,
      (selected_option is not null and response_ms>=slow_ms) slow_now,
      (is_correct is false and response_ms>=slow_ms) slow_wrong_now,
      (is_correct is false and response_ms>0 and response_ms<=fast_ms) fast_wrong_now
    from raw
  ), grouped as(
    select concept_key,max(concept_id) concept_id,max(subject) subject,max(topic) topic,
      jsonb_agg(question_id order by question_id)
        filter(where wrong_now or unattempted_now) question_ids,
      count(*) filter(where wrong_now)::integer wrong_count,
      count(*) filter(where unattempted_now)::integer unattempted_count,
      count(*) filter(where slow_now)::integer slow_count,
      count(*) filter(where slow_wrong_now)::integer slow_wrong_count,
      count(*) filter(where fast_wrong_now)::integer fast_wrong_count,
      sum(historical_wrong)::integer historical_wrong_count,
      sum(retention_attempts)::integer retention_attempts,
      sum(retention_correct)::integer retention_correct,
      bool_or(unconfirmed_guess) unconfirmed_guess,
      bool_or(due) due,bool_or(teacher_pyq) teacher_pyq,
      max(case learning_state
        when 'Persistent Weak' then 7 when 'Weak' then 6 when 'Fragile' then 5
        when 'Learning' then 4 when 'Strong' then 3 when 'Proven Mastered' then 2 else 1 end) state_rank
    from losses
    group by concept_key
    having count(*) filter(where wrong_now or unattempted_now)>0
  ), scored as(
    select g.*,
      case state_rank when 7 then 'Persistent Weak' when 6 then 'Weak' when 5 then 'Fragile'
        when 4 then 'Learning' when 3 then 'Strong' when 2 then 'Proven Mastered' else 'New' end current_state,
      (wrong_count*5 + unattempted_count*3 + slow_wrong_count*2 + fast_wrong_count
       + greatest(wrong_count+unattempted_count-1,0)*4
       + case state_rank when 7 then 7 when 6 then 5 when 5 then 3 else 0 end
       + case when unconfirmed_guess then 2 else 0 end
       + case when due then 1 else 0 end
       + case when teacher_pyq then 2 else 0 end
       + least(3,historical_wrong_count))::integer priority_score
    from grouped g
  )
  insert into gk.exam_diagnostics(
    diagnostic_id,session_id,user_id,concept_key,concept_id,subject,topic,question_ids,
    wrong_count,unattempted_count,slow_count,slow_wrong_count,fast_wrong_count,historical_wrong_count,
    current_learning_state,retention_attempts,retention_correct,unconfirmed_guess,due,teacher_pyq,
    repeated_concept_loss,priority_score,recommendation_reason
  )
  select
    'gk-diag-'||substr(md5(p_session_id||'|'||concept_key),1,24),
    p_session_id,uid,concept_key,concept_id,subject,topic,coalesce(question_ids,'[]'::jsonb),
    wrong_count,unattempted_count,slow_count,slow_wrong_count,fast_wrong_count,historical_wrong_count,
    current_state,retention_attempts,retention_correct,unconfirmed_guess,due,teacher_pyq,
    (wrong_count+unattempted_count)>1,priority_score,
    concat_ws(' + ',
      case when wrong_count>0 then wrong_count||' Sprint error'||case when wrong_count=1 then '' else 's' end end,
      case when unattempted_count>0 then unattempted_count||' unattempted' end,
      case when slow_wrong_count>0 then slow_wrong_count||' slow incorrect response'||case when slow_wrong_count=1 then '' else 's' end end,
      case when current_state in('Persistent Weak','Weak','Fragile') then 'existing '||current_state||' state' end,
      case when unconfirmed_guess then 'unresolved guess evidence' end,
      case when due then 'due review' end,
      case when teacher_pyq then 'Teacher PYQ available' end,
      case when historical_wrong_count>=2 then 'repeated historical misses' end
    )
  from scored
  on conflict(session_id,concept_key) do nothing;

  update gk.exam_sessions
  set analysis_generated_at=coalesce(analysis_generated_at,now()),
      analysis_meta=jsonb_build_object(
        'timedAnswers',timed_n,'medianMs',round(median_ms)::integer,
        'slowMs',slow_ms,'fastMs',fast_ms,
        'thresholdMethod',case when timed_n>=5 then 'own-response-median' else 'conservative-defaults' end
      )
  where session_id=p_session_id and user_id=uid;

  return public.gk_get_section_sprint_analysis(p_session_id);
end;
$$;

revoke all on function public.gk_analyze_section_sprint(text) from public,anon;
grant execute on function public.gk_analyze_section_sprint(text) to authenticated;

-- Smart Repair is read-only selection. Once these questions enter the existing
-- /gk/quiz runner, normal gk_record_exposure + gk_submit_answer mutate the one
-- authoritative adaptive learning system.
create or replace function public.gk_get_sprint_repair_batch(
  p_exam_session_id text,
  p_concept_key text default null,
  p_count integer default 12
)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
owned as(
  select session_id from gk.exam_sessions
  where session_id=p_exam_session_id and user_id=(select uid from u) and completed
), d as(
  select *
  from gk.exam_diagnostics
  where session_id=p_exam_session_id and user_id=(select uid from u)
    and (nullif(btrim(coalesce(p_concept_key,'')),'') is null or concept_key=p_concept_key)
  order by priority_score desc,subject,topic
  limit case when nullif(btrim(coalesce(p_concept_key,'')),'') is null then 4 else 1 end
), candidates as(
  select d.concept_key,d.priority_score,q.question_id,q.content_lane,
    exists(
      select 1 from gk.question_source_memberships m
      join gk.content_series cs on cs.series_id=m.series_id
      where m.question_id=q.question_id and cs.active
        and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ')
    ) teacher_pyq,
    coalesce(d.question_ids,'[]'::jsonb) ? q.question_id is_failed
  from d
  join gk.questions q on q.active and (
    (d.concept_id is not null and q.concept_id=d.concept_id)
    or (d.concept_id is null and coalesce(d.question_ids,'[]'::jsonb) ? q.question_id)
  )
), ranked as(
  select c.*,
    row_number() over(partition by concept_key order by
      case
        when not is_failed and teacher_pyq and upper(coalesce(content_lane,'MAIN'))='MAIN' then 1
        when not is_failed and upper(coalesce(content_lane,'MAIN'))='MAIN' then 2
        when is_failed and upper(coalesce(content_lane,'MAIN'))='MAIN' then 3
        when upper(coalesce(content_lane,''))='RAPID' then 4
        else 5
      end,question_id
    ) concept_rank,
    row_number() over(partition by concept_key,is_failed order by question_id) failed_rank
  from candidates c
), picked as(
  select * from ranked
  where (not is_failed or failed_rank=1) and concept_rank<=5
  order by priority_score desc,concept_rank,question_id
  limit greatest(1,least(40,coalesce(p_count,12)))
)
select case
  when (select uid from u) is null then '[]'::jsonb
  when not exists(select 1 from owned) then '[]'::jsonb
  else coalesce((select jsonb_agg(gk.question_payload_v2_read((select uid from u),question_id)
                                  order by priority_score desc,concept_rank,question_id) from picked),'[]'::jsonb)
end;
$$;

revoke all on function public.gk_get_sprint_repair_batch(text,text,integer) from public,anon;
grant execute on function public.gk_get_sprint_repair_batch(text,text,integer) to authenticated;

-- Re-open Sprint sessions with immutable score and source identity. Analysis remains
-- separate so a temporary diagnostic failure never hides the result.
create or replace function public.gk_get_section_sprint_session(p_session_id text)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with s as(
  select * from gk.exam_sessions where session_id=p_session_id and user_id=auth.uid()
), q as(
  select e.ord,gk.question_payload_v2_read(auth.uid(),e.question_id) payload
  from s,jsonb_array_elements_text(s.question_ids) with ordinality e(question_id,ord)
), a as(
  select a.* from gk.exam_answers a
  where a.session_id=p_session_id
    and exists(select 1 from s where s.session_id=a.session_id)
)
select case
  when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
  when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found')
  else jsonb_build_object(
    'ok',true,'sessionId',p_session_id,
    'durationSeconds',(select duration_seconds from s),
    'startedAt',(select started_at from s),
    'completed',(select completed from s),
    'sourceKind',(select source_kind from s),
    'result',(select result from s),
    'analysisReady',(select analysis_generated_at is not null from s),
    'questions',coalesce((select jsonb_agg(payload order by ord) from q),'[]'::jsonb),
    'answers',coalesce((select jsonb_object_agg(question_id,jsonb_build_object(
      'selected',selected_option,'correct',is_correct,'responseMs',response_ms
    )) from a),'{}'::jsonb)
  )
end;
$$;

revoke all on function public.gk_get_section_sprint_session(text) from public,anon;
grant execute on function public.gk_get_section_sprint_session(text) to authenticated;

-- Evidence confidence is additive to retention accuracy. Small samples can still be
-- inspected, but they no longer automatically dominate the Strongest recommendation.
create or replace function public.gk_get_intelligence_dashboard()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
p as(select * from gk.learning_profiles_v2((select uid from u))),
base as(
 select q.question_id,gk.canonical_subject(q.subject) subject,coalesce(nullif(q.topic,''),'General') topic,q.concept_id,
        p.attempts,p.learning_state st,p.retention_attempts,p.retention_correct,
        greatest(p.exposure_count,case when p.attempts>0 then 1 else 0 end) exposure_count,
        p.unconfirmed_guess,p.due,p.next_review,p.last_attempt,p.first_attempt_correct,
        exists(select 1 from gk.question_source_memberships m join gk.content_series cs on cs.series_id=m.series_id
               where m.question_id=q.question_id and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ')) teacher_pyq
 from gk.questions q join p on p.question_id=q.question_id where q.active
), top as(
 select count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
  count(*) filter(where st='Persistent Weak')::int persistent_weak,
  count(*) filter(where st in('Persistent Weak','Weak','Fragile'))::int weak_burden,
  count(*) filter(where st='Proven Mastered')::int proven,
  count(*) filter(where unconfirmed_guess)::int unresolved_guesses,
  count(*) filter(where due)::int due,
  coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention
 from base
), subject_rows0 as(
 select subject,count(*)::int total,count(*) filter(where exposure_count>0)::int seen,
  count(*) filter(where exposure_count=0)::int unseen,
  count(*) filter(where st='Persistent Weak')::int "persistentWeak",
  count(*) filter(where st='Weak')::int weak,count(*) filter(where st='Fragile')::int fragile,
  count(*) filter(where st='Proven Mastered')::int mastered,
  count(*) filter(where unconfirmed_guess)::int guessed,
  count(*) filter(where teacher_pyq and exposure_count=0)::int "unseenHighYield",
  sum(attempts)::int "attemptCount",sum(retention_attempts)::int "retentionAttemptCount",
  coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention,
  coalesce(round(count(*) filter(where exposure_count>0)*100.0/nullif(count(*),0),1),0) coverage,
  (count(*) filter(where st='Persistent Weak')*5 + count(*) filter(where st='Weak')*3
   + count(*) filter(where st='Fragile')*2 + count(*) filter(where unconfirmed_guess)*2)::int attention_score
 from base group by subject
), subject_rows as(
 select s.*,
   case
     when seen<5 or ("attemptCount"<5 and "retentionAttemptCount"<3) then 'Limited evidence'
     when "attemptCount"<20 or "retentionAttemptCount"<8 then 'Developing evidence'
     else 'Reliable evidence'
   end "evidenceConfidence",
   case
     when seen<5 or ("attemptCount"<5 and "retentionAttemptCount"<3) then 1
     when "attemptCount"<20 or "retentionAttemptCount"<8 then 2 else 3
   end evidence_rank
 from subject_rows0 s
), series_rows as(
 select cs.series_id "seriesId",cs.series_kind "seriesKind",cs.title,
  count(distinct m.question_id)::int total,
  count(distinct m.question_id) filter(where p.exposure_count>0 or p.attempts>0)::int exposed,
  count(distinct m.question_id) filter(where p.learning_state in('Persistent Weak','Weak','Fragile'))::int weak,
  count(distinct m.question_id) filter(where p.learning_state='Proven Mastered')::int mastered,
  coalesce(round(count(distinct m.question_id) filter(where p.exposure_count>0 or p.attempts>0)*100.0/nullif(count(distinct m.question_id),0),1),0) completion,
  coalesce(round(sum(p.retention_correct)*100.0/nullif(sum(p.retention_attempts),0),1),0) retention
 from gk.content_series cs join gk.question_source_memberships m on m.series_id=cs.series_id
 join p on p.question_id=m.question_id
 where cs.active and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ','CURRENT_AFFAIRS')
 group by cs.series_id,cs.series_kind,cs.title
), teacher_top as(
 select count(distinct m.question_id)::int total,
        count(distinct m.question_id) filter(where p.exposure_count>0 or p.attempts>0)::int exposed
 from gk.content_series cs
 join gk.question_source_memberships m on m.series_id=cs.series_id
 join p on p.question_id=m.question_id
 where cs.active and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ','CURRENT_AFFAIRS')
), weekly as(
 select count(distinct e.question_id)::int facts_seen
 from gk.exposures e where e.user_id=(select uid from u) and e.exposed_at>=now()-interval '7 days'
), weak_resolved as(
 select count(distinct a.question_id)::int resolved
 from gk.attempts a join base b on b.question_id=a.question_id
 where a.user_id=(select uid from u) and a.attempted_at>=now()-interval '7 days'
   and b.st in('Strong','Proven Mastered')
   and exists(select 1 from gk.attempts old where old.user_id=a.user_id and old.question_id=a.question_id
              and old.attempted_at<a.attempted_at and old.learning_state in('Persistent Weak','Weak','Fragile'))
), score as(
 select t.*,
  coalesce(round(case when t.total=0 then 0 else
    0.45*t.retention + 0.30*(t.exposed*100.0/t.total) + 0.25*(t.proven*100.0/t.total) end,1),0) readiness,
  coalesce(round(t.exposed*100.0/nullif(t.total,0),1),0) exposure_pct,
  coalesce(round(t.proven*100.0/nullif(t.total,0),1),0) proven_pct,
  coalesce((select round(tt.exposed*100.0/nullif(tt.total,0),1) from teacher_top tt),0) teacher_completion
 from top t
), confidence_floor as(
 select coalesce(max(evidence_rank),1) max_rank from subject_rows where seen>0
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'overview',(select jsonb_build_object(
   'readiness',readiness,'retention',retention,'bankExposure',exposure_pct,'provenKnowledge',proven_pct,
   'weakBurden',weak_burden,'persistentWeak',persistent_weak,'unresolvedGuesses',unresolved_guesses,'due',due,
   'teacherContentCompletion',teacher_completion,'questionBankExposure',exposure_pct,'knowledgeRetention',retention
 ) from score),
 'needsAttention',(select coalesce(jsonb_agg(to_jsonb(x)-'evidence_rank' order by x.attention_score desc,x.subject),'[]'::jsonb)
                   from (select * from subject_rows order by attention_score desc,subject limit 4)x),
 'strongest',(select coalesce(jsonb_agg(to_jsonb(x)-'evidence_rank' order by x.evidence_rank desc,x.retention desc,x.coverage desc),'[]'::jsonb)
              from (select sr.* from subject_rows sr,confidence_floor cf
                    where sr.seen>0 and (sr.evidence_rank=cf.max_rank or cf.max_rank=1)
                    order by sr.evidence_rank desc,sr.retention desc,sr.coverage desc limit 3)x),
 'subjects',(select coalesce(jsonb_agg(to_jsonb(x)-'evidence_rank' order by x.attention_score desc,x.subject),'[]'::jsonb) from subject_rows x),
 'seriesProgress',(select coalesce(jsonb_agg(to_jsonb(x) order by case x."seriesKind" when 'TOPIC_PYQ' then 1 when 'MIXED_PYQ' then 2 else 3 end,x.title),'[]'::jsonb) from series_rows x),
 'thisWeek',jsonb_build_object('factsSeen',(select facts_seen from weekly),'weakResolved',(select resolved from weak_resolved),'unresolvedGuesses',(select unresolved_guesses from top))
) end;
$$;

revoke all on function public.gk_get_intelligence_dashboard() from public,anon;
grant execute on function public.gk_get_intelligence_dashboard() to authenticated;

commit;

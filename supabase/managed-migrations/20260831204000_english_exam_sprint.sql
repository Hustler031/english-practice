-- English V2 SSC Sprint / Exam Preparation evidence layer.
-- Sprint items live in sprint tables and are ephemeral with respect to english.questions.
-- Only a GPT item diagnosed as a genuine Targeted gap is promoted to the canonical bank.

create table if not exists english.exam_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  target_date date not null,
  goal_marks numeric not null default 45,
  updated_at timestamptz not null default now()
);

create table if not exists english.sprint_sessions (
  session_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mode text not null check (mode in ('standard','weakness','trap','mistakes')),
  status text not null default 'in_progress' check (status in ('in_progress','completed','abandoned')),
  question_count integer not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  duration_seconds integer,
  score numeric,
  correct_count integer,
  wrong_count integer,
  unanswered_count integer,
  accuracy numeric,
  blueprint jsonb not null default '{}'::jsonb,
  analysis jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists english.sprint_items (
  session_id uuid not null references english.sprint_sessions(session_id) on delete cascade,
  position integer not null,
  item_key text not null,
  canonical_question_id text references english.questions(question_id) on delete set null,
  source_type text not null check (source_type in ('SSC PYQ','Curated Bank','GPT Generated','GPT Variant of Known Concept')),
  category text not null,
  question_type text not null,
  question text not null,
  options jsonb not null,
  correct_key text not null check (correct_key in ('A','B','C','D')),
  explanation text not null,
  metadata jsonb not null default '{}'::jsonb,
  primary key(session_id,position),
  unique(session_id,item_key)
);

create table if not exists english.sprint_answers (
  session_id uuid not null references english.sprint_sessions(session_id) on delete cascade,
  position integer not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  selected_key text,
  correct boolean not null default false,
  time_seconds numeric not null default 0,
  diagnosis text,
  action text,
  confused_with text,
  created_at timestamptz not null default now(),
  primary key(session_id,position),
  foreign key(session_id,position) references english.sprint_items(session_id,position) on delete cascade
);

create index if not exists english_sprint_sessions_history_idx on english.sprint_sessions(user_id,status,completed_at desc);
create index if not exists english_sprint_answers_diagnosis_idx on english.sprint_answers(user_id,diagnosis,created_at desc);
create index if not exists english_sprint_items_canonical_idx on english.sprint_items(canonical_question_id);

alter table english.exam_settings enable row level security;
alter table english.sprint_sessions enable row level security;
alter table english.sprint_items enable row level security;
alter table english.sprint_answers enable row level security;
revoke all on english.exam_settings,english.sprint_sessions,english.sprint_items,english.sprint_answers from public,anon,authenticated;
grant all on english.exam_settings,english.sprint_sessions,english.sprint_items,english.sprint_answers to service_role;

insert into english.exam_settings(user_id,target_date,goal_marks)
select id,(now() at time zone 'Asia/Kolkata')::date+30,45 from auth.users
on conflict(user_id) do nothing;

create or replace function english.sprint_expected_count(p_mode text)
returns integer language sql immutable as $$
select case lower(coalesce(p_mode,'standard')) when 'standard' then 25 when 'weakness' then 15 when 'trap' then 15 when 'mistakes' then 10 else 0 end;
$$;

create or replace function english.sprint_allowed_type(p_type text)
returns boolean language sql immutable as $$
select nullif(btrim(coalesce(p_type,'')),'') is not null
 and lower(coalesce(p_type,'')) !~ '(reading[ -]?comprehension|comprehension|passage|cloze passage|rc\b)';
$$;

create or replace function english.sprint_validate_options(p_options jsonb,p_correct text)
returns boolean language sql immutable as $$
with o as (
 select upper(coalesce(x->>'key','')) k,btrim(coalesce(x->>'text','')) t from jsonb_array_elements(coalesce(p_options,'[]'::jsonb)) x
)
select jsonb_typeof(coalesce(p_options,'[]'::jsonb))='array'
 and jsonb_array_length(coalesce(p_options,'[]'::jsonb))=4
 and count(*)=4 and count(distinct k)=4 and count(distinct lower(t))=4
 and bool_and(k in ('A','B','C','D') and t<>'') and upper(coalesce(p_correct,'')) in ('A','B','C','D')
 and count(*) filter(where k=upper(coalesce(p_correct,'')))=1 from o;
$$;

create or replace function public.english_get_sprint_generation_context(p_mode text default 'standard')
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), mode as (select lower(coalesce(p_mode,'standard')) m),
pen as (
 select category,penalty,seen_count,weak_count,first_attempt_accuracy,retention_accuracy,row_number() over(order by penalty desc,category) rn
 from uid cross join lateral english.daily_category_penalties(uid.id)
), targeted as (
 select q.question_id,english.learning_category(q.topic) category,q.question,q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct) correct_key,q.explanation,q.question_type,
        coalesce(s.status,'New') state,coalesce(s.wrong,0) wrong,coalesce(d.difficult,false) difficult,
        row_number() over(order by case coalesce(s.status,'New') when 'Persistent Weak' then 7 when 'Weak' then 6 when 'Fragile' then 5 else 2 end desc,coalesce(s.wrong,0) desc,q.question_id) rn
 from english.questions q cross join uid
 left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id
 left join english.difficult_state d on d.user_id=uid.id and d.question_id=q.question_id
 left join english.learning_route_state r on r.user_id=uid.id and r.question_id=q.question_id
 where q.active and not coalesce(s.mastered,false) and (r.route='targeted' or s.status in ('Persistent Weak','Weak','Fragile') or coalesce(d.difficult,false))
), traps as (
 select coalesce(nullif(confused_with,''),diagnosis) trap,count(*)::int n,max(created_at) last_at
 from english.sprint_answers a cross join uid where a.user_id=uid.id and nullif(coalesce(confused_with,diagnosis),'') is not null group by 1 order by n desc,last_at desc limit 8
), previous as (
 select i.category,i.question_type,i.question,i.options,i.correct_key,i.explanation,i.canonical_question_id,a.diagnosis,a.confused_with,s.completed_at,
        row_number() over(order by s.completed_at desc,i.position) rn
 from english.sprint_answers a join english.sprint_items i on i.session_id=a.session_id and i.position=a.position
 join english.sprint_sessions s on s.session_id=a.session_id cross join uid
 where a.user_id=uid.id and not a.correct and s.status='completed'
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'mode',(select m from mode),'count',english.sprint_expected_count((select m from mode)),
 'rules',jsonb_build_object('minutes',15,'marks',50,'correctMarks',2,'wrongMarks',-.5,'readingComprehension',false),
 'blueprint',case (select m from mode)
   when 'standard' then jsonb_build_object('balanced',14,'weakness',7,'freshChallenge',4,'guidance','56% balanced SSC mix, 28% current weakness transfer, 16% fresh challenge')
   when 'weakness' then jsonb_build_object('weakness',12,'transfer',3,'guidance','Fresh variants around current genuine weaknesses; do not replay identical text')
   when 'trap' then jsonb_build_object('trap',12,'transfer',3,'guidance','Adversarial plausible distractors around repeated trap patterns')
   else jsonb_build_object('previousMistakes',8,'transfer',2,'guidance','Fresh variants of previous Sprint mistakes') end,
 'weakCategories',coalesce((select jsonb_agg(jsonb_build_object('category',category,'penalty',round(penalty,4),'seen',seen_count,'weak',weak_count,'firstAttemptAccuracy',first_attempt_accuracy,'retentionAccuracy',retention_accuracy) order by rn) from pen where rn<=6),'[]'::jsonb),
 'targetedSeeds',coalesce((select jsonb_agg(jsonb_build_object('canonicalQuestionId',question_id,'category',category,'question',question,'options',jsonb_build_array(jsonb_build_object('key','A','text',option_a),jsonb_build_object('key','B','text',option_b),jsonb_build_object('key','C','text',option_c),jsonb_build_object('key','D','text',option_d)),'correctKey',correct_key,'explanation',explanation,'questionType',question_type,'state',state,'wrong',wrong,'difficult',difficult) order by rn) from targeted where rn<=14),'[]'::jsonb),
 'trapProfile',coalesce((select jsonb_agg(jsonb_build_object('trap',trap,'count',n) order by n desc,last_at desc) from traps),'[]'::jsonb),
 'previousMistakes',coalesce((select jsonb_agg(jsonb_build_object('category',category,'questionType',question_type,'question',question,'options',options,'correctKey',correct_key,'explanation',explanation,'canonicalQuestionId',canonical_question_id,'diagnosis',diagnosis,'confusedWith',confused_with) order by rn) from previous where rn<=10),'[]'::jsonb),
 'allowedAreas',jsonb_build_array('Vocabulary','Synonym','Antonym','Idioms & Phrases','One Word Substitution','Phrasal Verbs','Fixed Preposition','Spelling','Error Detection','Grammar Usage','Sentence Improvement','Fill in the Blank','Voice','Narration')
) end;
$$;

create or replace function public.english_create_sprint_session(p_mode text,p_items jsonb,p_blueprint jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); m text:=lower(coalesce(p_mode,'standard')); expected integer; sid uuid; x jsonb; pos integer:=0; opts jsonb; ck text; st text; qt text; qs text; cat text; expl text; itemkey text; cq text; meta jsonb; quality numeric; ambiguous boolean;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 expected:=english.sprint_expected_count(m); if expected=0 then raise exception 'Unknown Sprint mode'; end if;
 if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' or jsonb_array_length(p_items)<>expected then raise exception 'Sprint requires exactly % questions',expected; end if;
 insert into english.sprint_sessions(user_id,mode,question_count,blueprint) values(uid,m,expected,coalesce(p_blueprint,'{}'::jsonb)) returning session_id into sid;
 for x in select value from jsonb_array_elements(p_items) loop
   pos:=pos+1; opts:=coalesce(x->'options','[]'::jsonb); ck:=upper(coalesce(x->>'correctKey','')); st:=coalesce(nullif(x->>'sourceType',''),'GPT Generated'); qt:=btrim(coalesce(x->>'questionType','')); qs:=btrim(coalesce(x->>'question','')); cat:=btrim(coalesce(x->>'category','English')); expl:=btrim(coalesce(x->>'explanation','')); itemkey:=coalesce(nullif(x->>'itemKey',''),'gpt-'||sid::text||'-'||pos); cq:=nullif(btrim(coalesce(x->>'canonicalQuestionId','')),''); meta:=coalesce(x->'metadata','{}'::jsonb); quality:=coalesce((x->>'qualityScore')::numeric,0); ambiguous:=coalesce((x->>'ambiguous')::boolean,true);
   if st not in ('SSC PYQ','Curated Bank','GPT Generated','GPT Variant of Known Concept') then raise exception 'Untruthful/unknown Sprint source label at %',pos; end if;
   if st='SSC PYQ' and coalesce(meta->>'verifiedPyq','false')<>'true' then raise exception 'GPT output cannot self-label as SSC PYQ'; end if;
   if qs='' or expl='' or not english.sprint_allowed_type(qt) or not english.sprint_validate_options(opts,ck) then raise exception 'Invalid Sprint item at %',pos; end if;
   if ambiguous or quality<0.80 then raise exception 'Ambiguous or low-confidence Sprint item at %',pos; end if;
   if cq is not null and not exists(select 1 from english.questions q where q.question_id=cq) then cq:=null; end if;
   insert into english.sprint_items(session_id,position,item_key,canonical_question_id,source_type,category,question_type,question,options,correct_key,explanation,metadata)
   values(sid,pos,itemkey,cq,st,cat,qt,qs,opts,ck,expl,meta||jsonb_build_object('qualityScore',quality));
 end loop;
 return public.english_get_sprint_session(sid);
exception when others then
 if sid is not null then delete from english.sprint_sessions where session_id=sid and user_id=uid; end if; raise;
end $$;

create or replace function public.english_get_sprint_session(p_session_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with s as (select * from english.sprint_sessions where session_id=p_session_id and user_id=auth.uid()),
i as (select x.* from english.sprint_items x join s on s.session_id=x.session_id order by x.position)
select case when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found') else jsonb_build_object(
 'ok',true,'sessionId',(select session_id from s),'mode',(select mode from s),'status',(select status from s),'startedAt',(select started_at from s),
 'questionCount',(select question_count from s),'durationLimitSeconds',900,
 'items',coalesce((select jsonb_agg(case when (select status from s)='completed' then
   jsonb_build_object('position',position,'category',category,'questionType',question_type,'question',question,'options',options,'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,'canonicalQuestionId',canonical_question_id)
  else jsonb_build_object('position',position,'category',category,'questionType',question_type,'question',question,'options',options) end order by position) from i),'[]'::jsonb),
 'result',case when (select status from s)='completed' then jsonb_build_object('score',(select score from s),'correct',(select correct_count from s),'wrong',(select wrong_count from s),'unanswered',(select unanswered_count from s),'accuracy',(select accuracy from s),'durationSeconds',(select duration_seconds from s),'analysis',(select analysis from s)) else null end
) end;
$$;

create or replace function public.english_finish_sprint(p_session_id uuid,p_answers jsonb,p_duration_seconds integer)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); s english.sprint_sessions%rowtype; i record; a jsonb; selected text; t numeric; c integer:=0; w integer:=0; u integer:=0; score numeric; total integer; acc numeric;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.sprint_sessions where session_id=p_session_id and user_id=uid for update;
 if not found then raise exception 'Sprint not found'; end if;
 if s.status='completed' then return public.english_get_sprint_session(p_session_id); end if;
 if jsonb_typeof(coalesce(p_answers,'[]'::jsonb))<>'array' then raise exception 'Answers must be an array'; end if;
 for i in select * from english.sprint_items where session_id=p_session_id order by position loop
   select value into a from jsonb_array_elements(p_answers) value where coalesce((value->>'position')::integer,0)=i.position limit 1;
   selected:=upper(coalesce(a->>'selectedKey','')); t:=least(900,greatest(0,coalesce((a->>'timeSeconds')::numeric,0)));
   if selected not in ('A','B','C','D') then selected:=null; u:=u+1;
   elsif selected=i.correct_key then c:=c+1;
   else w:=w+1; end if;
   insert into english.sprint_answers(session_id,position,user_id,selected_key,correct,time_seconds)
   values(p_session_id,i.position,uid,selected,coalesce(selected=i.correct_key,false),t)
   on conflict(session_id,position) do update set selected_key=excluded.selected_key,correct=excluded.correct,time_seconds=excluded.time_seconds;
 end loop;
 total:=c+w+u; score:=c*2-w*.5; acc:=case when c+w>0 then round(c*100.0/(c+w),1) else 0 end;
 update english.sprint_sessions set status='completed',completed_at=now(),duration_seconds=least(900,greatest(0,coalesce(p_duration_seconds,0))),score=score,correct_count=c,wrong_count=w,unanswered_count=u,accuracy=acc where session_id=p_session_id and user_id=uid;
 -- Correct variant evidence stays separate from question_state but is visible to Central Intelligence through route metadata.
 update english.learning_route_state r set metadata=jsonb_set(coalesce(r.metadata,'{}'::jsonb),'{sprintCorrectEvidence}',to_jsonb(coalesce((r.metadata->>'sprintCorrectEvidence')::int,0)+1),true),updated_at=now()
 from english.sprint_items si join english.sprint_answers sa on sa.session_id=si.session_id and sa.position=si.position
 where si.session_id=p_session_id and sa.correct and si.canonical_question_id is not null and r.user_id=uid and r.question_id=si.canonical_question_id;
 return public.english_get_sprint_session(p_session_id);
end $$;

create or replace function public.english_get_sprint_analysis_context(p_session_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with s as (select * from english.sprint_sessions where session_id=p_session_id and user_id=auth.uid() and status='completed'),
w as (
 select i.position,i.category,i.question_type,i.question,i.options,i.correct_key,i.explanation,i.source_type,i.canonical_question_id,a.selected_key,
   case when i.canonical_question_id is null then null else (select r.route from english.learning_route_state r where r.user_id=auth.uid() and r.question_id=i.canonical_question_id) end route,
   case when i.canonical_question_id is null then null else (select qs.status from english.question_state qs where qs.user_id=auth.uid() and qs.question_id=i.canonical_question_id) end learning_state
 from english.sprint_items i join english.sprint_answers a on a.session_id=i.session_id and a.position=i.position join s on s.session_id=i.session_id where not a.correct
)
select case when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Completed Sprint not found') else jsonb_build_object(
 'ok',true,'sessionId',p_session_id,'score',(select score from s),'durationSeconds',(select duration_seconds from s),
 'wrongItems',coalesce((select jsonb_agg(jsonb_build_object('position',position,'category',category,'questionType',question_type,'question',question,'options',options,'selectedKey',selected_key,'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,'canonicalQuestionId',canonical_question_id,'route',route,'learningState',learning_state) order by position) from w),'[]'::jsonb),
 'diagnosisLabels',jsonb_build_array('Knowledge Gap','Confusion','Rule Gap','Careless','Time Pressure','Misread','Distractor Trap'),
 'actions',jsonb_build_array('Targeted Mastery','Weakness Drill','Trap Practice','Execution Review','No Route Change')
) end;
$$;

create or replace function public.english_save_sprint_analysis(p_session_id uuid,p_analysis jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); x jsonb; pos integer; diag text; act text; confused text; i english.sprint_items%rowtype; qid text; source_qid text; n_targeted integer:=0;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid and s.status='completed') then raise exception 'Completed Sprint not found'; end if;
 if jsonb_typeof(coalesce(p_analysis,'[]'::jsonb))<>'array' then raise exception 'Analysis must be an array'; end if;
 for x in select value from jsonb_array_elements(p_analysis) value loop
   pos:=coalesce((x->>'position')::int,0);diag:=coalesce(x->>'diagnosis','');act:=coalesce(x->>'action','No Route Change');confused:=nullif(btrim(coalesce(x->>'confusedWith','')),'');
   if diag not in ('Knowledge Gap','Confusion','Rule Gap','Careless','Time Pressure','Misread','Distractor Trap') then raise exception 'Invalid diagnosis at %',pos; end if;
   if act not in ('Targeted Mastery','Weakness Drill','Trap Practice','Execution Review','No Route Change') then raise exception 'Invalid action at %',pos; end if;
   select * into i from english.sprint_items where session_id=p_session_id and position=pos; if not found then raise exception 'Sprint item not found'; end if;
   update english.sprint_answers set diagnosis=diag,action=act,confused_with=confused where session_id=p_session_id and position=pos and user_id=uid;
   if act='Targeted Mastery' and diag in ('Knowledge Gap','Confusion','Rule Gap','Distractor Trap') then
     qid:=i.canonical_question_id;
     if qid is null then
       qid:='GPTSSC_'||replace(substr(p_session_id::text,1,8),'-','')||'_'||lpad(pos::text,2,'0');
       if not exists(select 1 from english.questions q where q.question_id=qid) then
         insert into english.questions(question_id,topic,question,option_a,option_b,option_c,option_d,correct,explanation,question_type,source_file,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,active,created_at,updated_at)
         values(qid,i.category,i.question,i.options->0->>'text',i.options->1->>'text',i.options->2->>'text',i.options->3->>'text',i.correct_key,i.explanation,i.question_type,'GPT SSC Sprint',coalesce(i.metadata->>'conceptKey',qid),'Targeted','GPT Sprint','New','Active','SSC CGL Targeted Follow-up',true,now(),now());
       end if;
       update english.sprint_items set canonical_question_id=qid where session_id=p_session_id and position=pos;
     end if;
     perform english.route_to_targeted(uid,qid,'Sprint',diag||' detected under SSC Sprint'); n_targeted:=n_targeted+1;
   end if;
 end loop;
 update english.sprint_sessions set analysis=jsonb_build_object('diagnosedAt',now(),'items',p_analysis,'targetedAdded',n_targeted) where session_id=p_session_id and user_id=uid;
 return jsonb_build_object('ok',true,'targetedAdded',n_targeted,'analysis',p_analysis);
end $$;

create or replace function public.english_get_exam_preparation()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), settings as (
 select coalesce(e.target_date,(now() at time zone 'Asia/Kolkata')::date+30) target_date,coalesce(e.goal_marks,45) goal_marks from uid left join english.exam_settings e on e.user_id=uid.id
), hist as (
 select s.*,row_number() over(order by completed_at desc,session_id desc) rn from english.sprint_sessions s cross join uid where s.user_id=uid.id and s.status='completed'
), five as (select * from hist where rn<=5),
streak as (select coalesce(min(rn) filter(where score<(select goal_marks from settings))-1,count(*))::int n from hist),
miss as (
 select a.*,i.category,i.canonical_question_id,s.completed_at from english.sprint_answers a join english.sprint_items i on i.session_id=a.session_id and i.position=a.position join english.sprint_sessions s on s.session_id=a.session_id cross join uid where a.user_id=uid.id and s.status='completed' and not a.correct
), category as (
 select category,count(*)::int wrong,max(completed_at) last_at from miss group by category order by wrong desc,last_at desc limit 5
), traps as (
 select coalesce(nullif(confused_with,''),diagnosis) trap,count(*)::int n,max(created_at) last_at from english.sprint_answers a cross join uid where a.user_id=uid.id and nullif(coalesce(confused_with,diagnosis),'') is not null group by 1 order by n desc,last_at desc limit 5
), sprint_targeted as (
 select count(distinct question_id)::int n from english.learning_route_events e cross join uid where e.user_id=uid.id and e.origin='Sprint' and e.to_route='targeted'
), sprint_recovered as (
 select count(distinct e.question_id)::int n from english.learning_route_events e cross join uid where e.user_id=uid.id and e.origin='Sprint' and e.to_route='targeted' and exists(select 1 from english.learning_route_state r where r.user_id=uid.id and r.question_id=e.question_id and r.route<>'targeted')
), route as (
 select public.english_get_learning_route_overview() j
), intelligence as (select public.english_get_central_intelligence() j)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'targetDate',(select target_date from settings),'daysLeft',greatest(0,(select target_date from settings)-(now() at time zone 'Asia/Kolkata')::date),'goalMarks',(select goal_marks from settings),
 'standard',jsonb_build_object('questions',25,'minutes',15,'marks',50,'wrongPenalty',-.5,'readingComprehension',false),
 'readiness',jsonb_build_object(
   'lastSprint',(select score from hist where rn=1),'fiveSprintAverage',(select round(avg(score),2) from five),'best',(select max(score) from hist),'lowest',(select min(score) from hist),
   'accuracy',(select round(avg(accuracy),1) from five),'timeSeconds',(select round(avg(duration_seconds))::int from five),'goalStreak',(select n from streak),
   'knownButMissed',(select count(*) from miss m where m.canonical_question_id is not null and exists(select 1 from english.learning_route_state r where r.user_id=(select id from uid) and r.question_id=m.canonical_question_id and r.route='fast_track')),
   'targetedMissed',(select count(*) from miss m where m.canonical_question_id is not null and exists(select 1 from english.learning_route_state r where r.user_id=(select id from uid) and r.question_id=m.canonical_question_id and r.route='targeted')),
   'preventableMarksLost',(select coalesce(round(count(*) filter(where diagnosis in ('Careless','Misread','Time Pressure'))*2.5,1),0) from miss)
 ),
 'weaknesses',coalesce((select jsonb_agg(jsonb_build_object('category',category,'wrong',wrong) order by wrong desc,last_at desc) from category),'[]'::jsonb),
 'traps',coalesce((select jsonb_agg(jsonb_build_object('trap',trap,'count',n) order by n desc,last_at desc) from traps),'[]'::jsonb),
 'recentSprints',coalesce((select jsonb_agg(jsonb_build_object('sessionId',session_id,'mode',mode,'score',score,'correct',correct_count,'wrong',wrong_count,'unanswered',unanswered_count,'accuracy',accuracy,'durationSeconds',duration_seconds,'completedAt',completed_at) order by completed_at desc) from hist where rn<=5),'[]'::jsonb),
 'targetedFromSprints',jsonb_build_object('needLearning',(select n from sprint_targeted),'recovered',(select n from sprint_recovered)),
 'todayPlan',jsonb_build_object(
   'targetedRevision',coalesce((select (j->'queues'->>'persistentWeak')::int+(j->'queues'->>'weak')::int+(j->'queues'->>'fragile')::int from intelligence),0),
   'fastTrackReady',coalesce((select (j->'fastTrack'->>'readyToVerify')::int from route),0),'sprintQuestions',25,
   'weaknessDrill',coalesce((select string_agg(category,' + ' order by wrong desc,last_at desc) from category limit 2),'Current weak areas')
 )
) end;
$$;

revoke execute on function public.english_get_sprint_generation_context(text) from public,anon;
revoke execute on function public.english_create_sprint_session(text,jsonb,jsonb) from public,anon;
revoke execute on function public.english_get_sprint_session(uuid) from public,anon;
revoke execute on function public.english_finish_sprint(uuid,jsonb,integer) from public,anon;
revoke execute on function public.english_get_sprint_analysis_context(uuid) from public,anon;
revoke execute on function public.english_save_sprint_analysis(uuid,jsonb) from public,anon;
revoke execute on function public.english_get_exam_preparation() from public,anon;
grant execute on function public.english_get_sprint_generation_context(text) to authenticated,service_role;
grant execute on function public.english_create_sprint_session(text,jsonb,jsonb) to authenticated,service_role;
grant execute on function public.english_get_sprint_session(uuid) to authenticated,service_role;
grant execute on function public.english_finish_sprint(uuid,jsonb,integer) to authenticated,service_role;
grant execute on function public.english_get_sprint_analysis_context(uuid) to authenticated,service_role;
grant execute on function public.english_save_sprint_analysis(uuid,jsonb) to authenticated,service_role;
grant execute on function public.english_get_exam_preparation() to authenticated,service_role;

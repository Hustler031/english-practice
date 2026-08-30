-- GK V2 evidence/parity corrections found during final old-app comparison.
-- Additive only: preserve canonical questions/history, reconcile derived state from raw evidence,
-- restore legacy Starred "Earlier" behavior, and make displayed metrics evidence-correct.

-- Random modes call random(); the public selector must not claim STABLE semantics.
alter function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) volatile;

-- Central selector parity follow-up. Long Time No See intentionally remains the old GK
-- rotation pool (all eligible questions sorted oldest/never-seen first), not a hidden
-- 30-day eligibility filter. Missing legacy Starred dates are exposed as starred_earlier.
create or replace function public.gk_get_batch(
 p_mode text default 'smart',p_count integer default 20,p_lane text default 'MIXED',
 p_subject text default null,p_topic text default null,p_lecture_key text default null,p_library_key text default null,
 p_demand_id text default null,p_ca_months integer default null,p_ca_category text default null
) returns jsonb
language plpgsql
volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
 uid uuid:=auth.uid();
 mode_name text:=lower(btrim(coalesce(p_mode,'smart')));
 lane_name text:=upper(btrim(coalesce(p_lane,'MIXED')));
 n int:=greatest(1,least(100,coalesce(p_count,20)));
 age_from int:=null;
 age_to int:=null;
 out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if lane_name not in ('MAIN','RAPID','MIXED','ALL') then raise exception 'Invalid GK question style'; end if;
 if mode_name ~ '^starred_age_[0-9]+_[0-9]+$' then
   age_from:=split_part(mode_name,'_',3)::int;
   age_to:=split_part(mode_name,'_',4)::int;
 end if;

 with base as(
   select q.*,
     coalesce(s.learning_status,'New') st,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
     coalesce(s.retention_attempts,0) retention_attempts,coalesce(s.retention_accuracy,0) retention_accuracy,
     coalesce(s.difficult,false) difficult,coalesce(s.marked_review,false) starred,coalesce(s.unconfirmed_guess,false) unconfirmed_guess,
     s.starred_at,s.last_attempt,s.last_seen,s.next_review,
     coalesce(s.next_review<=now(),false) due,
     exists(select 1 from gk.exposures e where e.user_id=uid and e.question_id=q.question_id) exposed,
     (select max(a.attempted_at) from gk.attempts a where a.user_id=uid and a.question_id=q.question_id and (a.mode like 'starred_%' or a.mode='review')) starred_last_revision,
     case when s.starred_at is null then null else greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) end starred_age_days,
     case coalesce(s.learning_status,'New') when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700 when 'Learning' then 500 when 'New' then 300 when 'Strong' then 180 when 'Proven Mastered' then 20 else 0 end
       +case when coalesce(s.next_review<=now(),false) then 300 else 0 end
       +case when coalesce(s.difficult,false) then 180 else 0 end
       +case when coalesce(s.unconfirmed_guess,false) then 240 else 0 end
       +case when coalesce(s.marked_review,false) then 80 else 0 end
       +least(180,coalesce(floor(extract(epoch from(now()-s.last_attempt))/86400)*6,140))
       +case when q.subject='Current Affairs' and q.source_date is not null then greatest(0,120-(current_date-q.source_date)) else 0 end as priority
   from gk.questions q
   left join gk.question_state s on s.user_id=uid and s.question_id=q.question_id
   where q.active
     and (lane_name in ('MIXED','ALL') or upper(q.content_lane)=lane_name)
     and (p_subject is null or q.subject=p_subject)
     and (p_topic is null or q.topic=p_topic)
     and (p_lecture_key is null or q.lecture_key=p_lecture_key)
     and (p_library_key is null or q.library_key=p_library_key)
     and (p_ca_category is null or q.topic=p_ca_category)
     and (p_ca_months is null or p_ca_months<=0 or q.source_date>=((current_date-make_interval(months=>p_ca_months))::date))
     and (p_demand_id is null or exists(
       select 1 from gk.demand_sets d,jsonb_array_elements_text(coalesce(d.question_ids,'[]'::jsonb)) j(question_id)
       where d.demand_id=p_demand_id and d.active and (d.user_id is null or d.user_id=uid) and j.question_id=q.question_id
     ))
 ), eligible as(
   select * from base b where
     case
       when mode_name in ('new','unseen','new_v2','new_random') then not b.exposed
       when mode_name in ('weak','weak_practice') then b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name in ('persistent_weak','starred_persistent') then b.st='Persistent Weak' and (mode_name='persistent_weak' or b.starred)
       when mode_name in ('due','due_recall') then b.due
       when mode_name='difficult' then b.difficult
       when mode_name in ('starred','starred_smart') then b.starred
       when mode_name='starred_weak' then b.starred and b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name='starred_due' then b.starred and b.due
       when mode_name='starred_difficult' then b.starred and b.difficult
       when mode_name='starred_never' then b.starred and b.starred_last_revision is null
       when mode_name in ('starred_longest','starred_oldest','starred_random') then b.starred
       when mode_name='starred_earlier' then b.starred and b.starred_at is null
       when age_from is not null then b.starred and b.starred_age_days between age_from and age_to
       when mode_name in ('guessed','guessed_smart','guessed_random','guessed_oldest','guessed_recent') then b.unconfirmed_guess
       when mode_name='guessed_repeated' then b.unconfirmed_guess and coalesce((select s2.guessed_attempts from gk.question_state s2 where s2.user_id=uid and s2.question_id=b.question_id),0)>=2
       when mode_name='guessed_weak' then b.unconfirmed_guess and b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name='guessed_due' then b.unconfirmed_guess and b.due
       when mode_name in ('recall','recall_check') then b.exposed and b.st<>'Proven Mastered'
       when mode_name in ('daily','smart') then b.st<>'Proven Mastered'
       when mode_name like 'current_%' then b.subject='Current Affairs'
       else true
     end
 ), ranked as(
   select e.*,
     row_number() over(order by
       case when mode_name in ('random','new_random','starred_random','guessed_random','current_random') then random() else 0 end,
       case when mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen,to_timestamp(0))) else 0 end asc,
       case when mode_name in ('starred_longest','starred_oldest') then extract(epoch from coalesce(e.starred_last_revision,to_timestamp(0))) else 0 end asc,
       case when mode_name='guessed_oldest' then extract(epoch from coalesce((select s3.last_guess_at from gk.question_state s3 where s3.user_id=uid and s3.question_id=e.question_id),to_timestamp(0))) else 0 end asc,
       case when mode_name='guessed_recent' then extract(epoch from coalesce((select s4.last_guess_at from gk.question_state s4 where s4.user_id=uid and s4.question_id=e.question_id),to_timestamp(0))) else 0 end desc,
       case when mode_name='starred_smart' then e.priority+least(320,greatest(0,floor(extract(epoch from(now()-coalesce(e.starred_last_revision,e.starred_at,to_timestamp(0))))/86400)::int)*10) else e.priority end desc,
       e.priority desc,e.question_id
     ) ord
   from eligible e
 ), chosen as(select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(gk.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end;
$$;

-- Old Starred groups include rows whose legacy sheet predates starred_at as an
-- "Earlier" group. Never invent a date for those rows.
create or replace function public.gk_get_starred_hub()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), rows as(
 select s.question_id,s.learning_status,s.next_review,s.difficult,s.starred_at,s.unconfirmed_guess,
   case when s.starred_at is null then null else greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) end age,
   (select max(a.attempted_at) from gk.attempts a where a.user_id=u.uid and a.question_id=s.question_id and (a.mode like 'starred_%' or a.mode='review')) last_starred_revision
 from gk.question_state s cross join u where s.user_id=u.uid and s.marked_review
), exact_days as(
 select age,('Day '||(age+1)) label,age age_from,age age_to from generate_series(0,9) age
), later_bands as(
 select 10 age,'Days 11–20' label,10 age_from,19 age_to union all
 select 20,'Days 21–30',20,29 union all
 select start_age,('Days '||(start_age+1)||'–'||(start_age+30)),start_age,start_age+29
 from generate_series(30,greatest(30,coalesce((select max(age) from rows),30)),30) start_age
), dated_groups as(
 select d.label,d.age_from,d.age_to,count(r.question_id)::int count,
   count(*) filter(where r.learning_status='Persistent Weak')::int persistent_weak,
   count(*) filter(where r.learning_status in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where r.next_review<=now())::int due,
   count(*) filter(where r.difficult)::int difficult,
   count(*) filter(where r.learning_status not in ('Persistent Weak','Weak','Fragile') and not coalesce(r.next_review<=now(),false))::int healthy
 from (select * from exact_days union all select * from later_bands) d
 left join rows r on r.age between d.age_from and d.age_to group by d.age,d.label,d.age_from,d.age_to having count(r.question_id)>0
), earlier as(
 select 'Earlier'::text label,null::int age_from,null::int age_to,count(*)::int count,
   count(*) filter(where learning_status='Persistent Weak')::int persistent_weak,
   count(*) filter(where learning_status in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where next_review<=now())::int due,
   count(*) filter(where difficult)::int difficult,
   count(*) filter(where learning_status not in ('Persistent Weak','Weak','Fragile') and not coalesce(next_review<=now(),false))::int healthy
 from rows where starred_at is null having count(*)>0
), groups as(select * from dated_groups union all select * from earlier), summary as(
 select count(*)::int starred,
   count(*) filter(where learning_status in ('Persistent Weak','Weak','Fragile') or next_review<=now() or unconfirmed_guess)::int focus,
   count(*) filter(where difficult)::int difficult,count(*) filter(where learning_status='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,count(*) filter(where last_starred_revision is null)::int never_revised from rows
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'summary',(select to_jsonb(summary) from summary),
 'groups',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'ageFrom',age_from,'ageTo',age_to,'count',count,'health',jsonb_build_object('persistentWeak',persistent_weak,'weakFragile',weak_fragile,'due',due,'difficult',difficult,'healthy',healthy))
   order by case when age_to<=9 then 0 when age_from is not null then 1 else 2 end,
            case when age_to<=9 then -age_from else age_from end nulls last),'[]'::jsonb) from groups)
) end;
$$;

-- Match old On Demand counter semantics: Long Time No See reports never-seen count,
-- while its selectable pool remains all questions rotated by oldest lastSeen.
create or replace function public.gk_get_on_demand_hub()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), b as(
 select q.question_id,q.subject,q.topic,q.concept_id,coalesce(s.learning_status,'New') st,coalesce(s.unconfirmed_guess,false) guessed,
   coalesce(s.difficult,false) difficult,s.last_seen,coalesce(s.retention_accuracy,0) retention_accuracy
 from gk.questions q cross join u left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id where q.active
), concepts as(
 select coalesce(nullif(concept_id,''),coalesce(subject,'')||'|'||coalesce(topic,'General')) concept_id,coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*) filter(where st='Persistent Weak')::int persistent_weak,count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   coalesce(round(avg(retention_accuracy) filter(where retention_accuracy>0),1),0) retention_accuracy
 from b group by 1,2,3
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'stats',jsonb_build_object(
   'weak',(select count(*) from b where st in ('Persistent Weak','Weak','Fragile')),
   'guessed',(select count(*) from b where guessed),
   'difficult',(select count(*) from b where difficult),
   'longUnseen',(select count(*) from b where last_seen is null)
 ),
 'weakTopics',(select coalesce(jsonb_agg(to_jsonb(x) order by persistent_weak desc,weak desc,topic),'[]'::jsonb) from (select * from concepts where weak>0 limit 30)x),
 'myDemandSets',(select coalesce(jsonb_agg(jsonb_build_object('demandId',demand_id,'title',coalesce(title,demand_id),'kind',kind,'count',jsonb_array_length(coalesce(question_ids,'[]'::jsonb)),'lastUsed',last_used) order by coalesce(last_used,created_at) desc nulls last,demand_id),'[]'::jsonb) from gk.demand_sets d cross join u where d.active and (d.user_id is null or d.user_id=u.uid))
) end;
$$;

-- Home's First-Attempt Accuracy is first-attempt evidence, never cumulative accuracy.
create or replace function public.gk_get_home_snapshot()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
with u as(select auth.uid() uid), q as(select count(*)::int total,count(*) filter(where content_lane='MAIN')::int main,count(*) filter(where content_lane='RAPID')::int rapid from gk.questions where active),
s as(select count(*)::int attempted,count(*) filter(where learning_status='Persistent Weak')::int persistent_weak,count(*) filter(where learning_status='Weak')::int weak,
 count(*) filter(where learning_status='Fragile')::int fragile,count(*) filter(where learning_status='Strong')::int strong,count(*) filter(where learning_status='Proven Mastered')::int mastered,
 count(*) filter(where next_review<=now())::int due,count(*) filter(where marked_review)::int starred,count(*) filter(where difficult)::int difficult,count(*) filter(where unconfirmed_guess)::int guessed,
 coalesce(round(count(*) filter(where first_attempt_correct is true)*100.0/nullif(count(*) filter(where first_attempt_correct is not null),0),1),0) first_accuracy,
 coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention_accuracy
 from gk.question_state cross join u where user_id=u.uid), e as(select count(distinct question_id)::int exposed from gk.exposures cross join u where user_id=u.uid),
r as(select session_id,title,mode,position_index,current_index,updated_at from gk.sessions cross join u where user_id=u.uid and not completed order by updated_at desc nulls last,created_at desc limit 1)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object('ok',true,'summary',jsonb_build_object(
 'total',q.total,'eligibleTotal',q.total,'eligibleMain',q.main,'eligibleRapidRecall',q.rapid,'exposed',e.exposed,'bankExposure',case when q.total>0 then round(e.exposed*100.0/q.total,1) else 0 end,
 'persistentWeak',s.persistent_weak,'weak',s.weak,'fragile',s.fragile,'strong',s.strong,'provenMastered',s.mastered,'due',s.due,'starred',s.starred,'difficult',s.difficult,'guessed',s.guessed,
 'firstAttemptAccuracy',s.first_accuracy,'retentionAccuracy',s.retention_accuracy,'newQuestions',greatest(q.total-e.exposed,0)
),'resume',(select to_jsonb(r) from r)) from q,s,e;
$$;

-- Progress shape stays compatible with the React view but restores old GK evidence
-- semantics: nullable first-attempt evidence, concept-level PW KPI, historical guessed
-- health, Starred focus, and Difficult resolution.
create or replace function public.gk_get_progress()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
with u as(select auth.uid() uid), base as(
 select q.question_id,q.subject,q.topic,q.concept_id,q.lecture_key,q.source_label,q.source_date,q.library_key,
   coalesce(s.learning_status,'New') st,coalesce(s.attempts,0) attempts,coalesce(s.correct,0) correct,s.first_attempt_correct first_ok,
   coalesce(s.retention_attempts,0) ret_attempts,coalesce(s.retention_correct,0) ret_correct,coalesce(s.retention_accuracy,0) ret_accuracy,
   coalesce(s.marked_review,false) starred,s.starred_at,coalesce(s.difficult,false) difficult,coalesce(s.guessed_attempts,0) guessed_attempts,
   coalesce(s.unconfirmed_guess,false) guessed,coalesce(s.exposure_count,0) exposure_count,s.last_attempt,s.next_review
 from gk.questions q cross join u left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id where q.active
), subject_rows as(
 select coalesce(subject,'Unclassified') subject,count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,count(*) filter(where st='Proven Mastered')::int mastered,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) retentionAccuracy from base group by 1
), concepts as(
 select coalesce(nullif(concept_id,''),coalesce(subject,'')||'|'||coalesce(topic,'General')) conceptId,coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*)::int total,count(*) filter(where exposure_count>0)::int attempted,
   count(*) filter(where st='Persistent Weak')::int persistentWeak,count(*) filter(where st in ('Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,count(*) filter(where guessed)::int guessed,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) retentionAccuracy
 from base group by 1,2,3
), lectures as(
 select lecture_key,max(source_label) title,count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,count(*) filter(where st='Proven Mastered')::int mastered
 from base group by lecture_key
), ca as(
 select case when source_date>=current_date-interval '1 month' then '1 Month' when source_date>=current_date-interval '3 months' then '3 Months' when source_date>=current_date-interval '6 months' then '6 Months' else 'Older' end band,
   count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,count(*) filter(where guessed)::int guessed
 from base where subject='Current Affairs' group by 1
), top as(
 select count(*)::int total,count(*) filter(where exposure_count>0)::int exposed,count(*) filter(where st='Persistent Weak')::int persistentWeak,
   count(*) filter(where st='Weak')::int weak,count(*) filter(where st='Fragile')::int fragile,count(*) filter(where st='Strong')::int strong,count(*) filter(where st='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,count(*) filter(where starred)::int starred,count(*) filter(where difficult)::int difficult,count(*) filter(where guessed)::int guessed,
   coalesce(round(count(*) filter(where first_ok is true)*100.0/nullif(count(*) filter(where first_ok is not null),0),1),0) firstAccuracy,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) retentionAccuracy from base
), concept_top as(
 select count(*) filter(where persistentWeak>0)::int persistentWeakConcepts,count(*) filter(where weak>0 or persistentWeak>0)::int weakConcepts from concepts
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'overview',(select to_jsonb(top)||to_jsonb(concept_top) from top cross join concept_top),
 'knowledgeHealth',(select jsonb_build_array(
   jsonb_build_object('state','Persistent Weak','count',persistentWeak),jsonb_build_object('state','Weak','count',weak),jsonb_build_object('state','Fragile','count',fragile),
   jsonb_build_object('state','Strong','count',strong),jsonb_build_object('state','Proven Mastered','count',mastered)) from top),
 'subjectMastery',(select coalesce(jsonb_agg(to_jsonb(subject_rows) order by total desc,subject),'[]'::jsonb) from subject_rows),
 'weakConcepts',(select coalesce(jsonb_agg(to_jsonb(c) order by persistentWeak desc,weak desc,total desc),'[]'::jsonb) from (select * from concepts where persistentWeak+weak>0 limit 50)c),
 'currentAffairsHealth',(select coalesce(jsonb_agg(to_jsonb(ca) order by case band when '1 Month' then 1 when '3 Months' then 2 when '6 Months' then 3 else 4 end),'[]'::jsonb) from ca),
 'starredHealth',(select jsonb_build_object(
   'total',starred,
   'focus',(select count(*) from base where starred and (st in ('Persistent Weak','Weak','Fragile') or next_review<=now() or guessed)),
   'due',(select count(*) from base where starred and next_review<=now()),
   'difficult',(select count(*) from base where starred and difficult),
   'mastered',(select count(*) from base where starred and st='Proven Mastered')) from top),
 'guessedHealth',(select jsonb_build_object(
   'historicallyGuessed',(select count(*) from base where guessed_attempts>0),
   'unresolved',guessed,
   'repeated',(select count(*) from base where guessed and guessed_attempts>=2),
   'due',(select count(*) from base where guessed and next_review<=now())) from top),
 'difficultResolution',(select jsonb_build_object(
   'total',difficult,
   'resolvedStrong',(select count(*) from base where difficult and st in ('Strong','Proven Mastered')),
   'needsFocus',(select count(*) from base where difficult and (st in ('Persistent Weak','Weak','Fragile') or next_review<=now()))) from top),
 'lectureCoverage',(select coalesce(jsonb_agg(to_jsonb(lectures) order by case when total>0 then exposed::numeric/total else 0 end asc,title),'[]'::jsonb) from lectures)
); $$;

-- Rebuild the derived QuestionState cache from immutable/raw attempt + exposure
-- evidence. This preserves manual Star/Difficult/Flag fields because refresh_question_state
-- explicitly carries those forward; it only repairs evidence-derived fields.
do $$
declare r record;
begin
 for r in
   select distinct user_id,question_id from (
     select user_id,question_id from gk.attempts
     union all select user_id,question_id from gk.exposures
     union all select user_id,question_id from gk.question_state
   ) x
 loop
   perform gk.refresh_question_state(r.user_id,r.question_id);
 end loop;
end $$;

-- Newly created/replaced security-definer functions remain authenticated-only.
revoke execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) from public, anon;
revoke execute on function public.gk_get_starred_hub() from public, anon;
revoke execute on function public.gk_get_on_demand_hub() from public, anon;
revoke execute on function public.gk_get_home_snapshot() from public, anon;
revoke execute on function public.gk_get_progress() from public, anon;
grant execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) to authenticated;
grant execute on function public.gk_get_starred_hub() to authenticated;
grant execute on function public.gk_get_on_demand_hub() to authenticated;
grant execute on function public.gk_get_home_snapshot() to authenticated;
grant execute on function public.gk_get_progress() to authenticated;

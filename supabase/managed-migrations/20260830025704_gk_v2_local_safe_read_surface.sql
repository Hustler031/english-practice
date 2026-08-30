-- GK V2 localhost-safe read compatibility.
-- Read models only: no canonical content/history/state/session data is rewritten.
-- Localhost mutations remain intercepted by the React Local Safe layer.

create or replace function gk.derive_library_key(
  p_question_id text,
  p_source_label text,
  p_subject text
) returns text
language sql
immutable
set search_path=pg_catalog
as $$
  select case
    when lower(coalesce(p_source_label,'')) like '%nitto%' or upper(coalesce(p_question_id,'')) like 'NIT%' then 'nitto'
    when lower(coalesce(p_source_label,'')) like '%mixed%' then 'mixed'
    when lower(coalesce(p_source_label,'')) like '%pyq%'
      or upper(coalesce(p_question_id,'')) ~ '^POL[0-9]'
      or upper(coalesce(p_question_id,'')) ~ '^ECO' then 'subject-pyq'
    when nullif(btrim(coalesce(p_subject,'')),'') is not null
      and lower(coalesce(p_source_label,'')) like '%lecture%' then 'subject-pyq'
    else 'misc'
  end
$$;

create or replace function gk.question_payload_v2_read(
  p_user_id uuid,
  p_question_id text
) returns jsonb
language sql
stable security definer
set search_path=pg_catalog,gk,auth
as $$
with qrow as (
  select q.*
  from gk.questions q
  where q.question_id=p_question_id and q.active
), ev as (
  select count(*)::int exposure_count,min(exposed_at) first_seen,max(exposed_at) last_seen
  from gk.exposures
  where user_id=p_user_id and question_id=p_question_id
), first_attempt as (
  select is_correct
  from gk.attempts
  where user_id=p_user_id and question_id=p_question_id
  order by attempted_at,attempt_id
  limit 1
), recent_spaced as (
  select count(*) filter(where not is_correct)::int recent_spaced_failures
  from (
    select is_correct
    from gk.attempts
    where user_id=p_user_id and question_id=p_question_id and coalesce(is_spaced,false)
    order by attempted_at desc,attempt_id desc
    limit 3
  ) x
)
select to_jsonb(q)-'source_payload'
 || jsonb_build_object(
   'id',q.question_id,
   'question_id',q.question_id,
   'library_key',gk.derive_library_key(q.question_id,q.source_label,q.subject),
   'correctKey',upper(coalesce(q.correct_option,'')),
   'options',jsonb_build_array(
     jsonb_build_object('key','A','text',coalesce(q.option_a,'')),
     jsonb_build_object('key','B','text',coalesce(q.option_b,'')),
     jsonb_build_object('key','C','text',coalesce(q.option_c,'')),
     jsonb_build_object('key','D','text',coalesce(q.option_d,''))
   ),
   'state',jsonb_build_object(
     'attempts',coalesce(s.attempts,0),
     'correct',coalesce(s.correct,0),
     'wrong',coalesce(s.wrong,0),
     'accuracy',coalesce(s.accuracy,0),
     'status',coalesce(s.learning_status,'New'),
     'learningState',coalesce(s.learning_status,'New'),
     'firstAttemptCorrect',coalesce(s.first_attempt_correct,(select is_correct from first_attempt)),
     'retentionAttempts',coalesce(s.retention_attempts,0),
     'retentionCorrect',coalesce(s.retention_correct,0),
     'retentionWrong',coalesce(s.retention_wrong,0),
     'retentionAccuracy',case when coalesce(s.retention_attempts,0)>0
       then round(coalesce(s.retention_correct,0)*100.0/s.retention_attempts,1) else 0 end,
     'recentSpacedFailures',coalesce((select recent_spaced_failures from recent_spaced),0),
     'lastAttempt',s.last_attempt,
     'lastSpacedAttempt',s.last_spaced_attempt,
     'lastMeaningfulResult',coalesce(s.last_meaningful_result,''),
     'latestResult',coalesce(s.latest_result,''),
     'nextReview',s.next_review,
     'due',coalesce(s.next_review<=now(),false),
     'starred',coalesce(s.marked_review,false),
     'starredAt',s.starred_at,
     'difficult',coalesce(s.difficult,false),
     'guessedAttempts',coalesce(s.guessed_attempts,0),
     'unconfirmedGuess',coalesce(s.unconfirmed_guess,false),
     'lastGuessAt',s.last_guess_at,
     'confirmedUnguessedSpacedRecalls',coalesce(s.confirmed_unguessed_spaced_recalls,0),
     'exposureCount',coalesce((select exposure_count from ev),0),
     'firstSeen',(select first_seen from ev),
     'lastSeen',(select last_seen from ev),
     'flagged',coalesce(s.flag_active,false),
     'flagReason',coalesce(s.flag_reason,''),
     'note',coalesce(n.note,'')
   )
 )
from qrow q
left join gk.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
left join gk.user_notes n on n.user_id=p_user_id and n.question_id=q.question_id
$$;

create or replace function public.gk_get_batch(
 p_mode text default 'smart',
 p_count integer default 20,
 p_lane text default 'MIXED',
 p_subject text default null,
 p_topic text default null,
 p_lecture_key text default null,
 p_library_key text default null,
 p_demand_id text default null,
 p_ca_months integer default null,
 p_ca_category text default null
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

 with base as (
   select q.*,
     coalesce(s.learning_status,'New') st,
     coalesce(s.wrong,0) wrong,
     coalesce(s.difficult,false) difficult,
     coalesce(s.marked_review,false) starred,
     coalesce(s.unconfirmed_guess,false) unconfirmed_guess,
     coalesce(s.guessed_attempts,0) guessed_attempts,
     s.starred_at,s.last_attempt,s.next_review,s.last_guess_at,
     coalesce(s.next_review<=now(),false) due,
     exists(select 1 from gk.exposures e where e.user_id=uid and e.question_id=q.question_id) exposed,
     (select max(e.exposed_at) from gk.exposures e where e.user_id=uid and e.question_id=q.question_id) last_seen_evidence,
     (select max(a.attempted_at) from gk.attempts a
       where a.user_id=uid and a.question_id=q.question_id
         and (a.mode like 'starred_%' or a.mode='review')) starred_last_revision,
     case when s.starred_at is null then null else greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) end starred_age_days,
     case coalesce(s.learning_status,'New')
       when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700
       when 'Learning' then 500 when 'New' then 300 when 'Strong' then 180
       when 'Proven Mastered' then 20 else 0 end
       +case when coalesce(s.next_review<=now(),false) then 300 else 0 end
       +case when coalesce(s.difficult,false) then 180 else 0 end
       +case when coalesce(s.unconfirmed_guess,false) then 240 else 0 end
       +case when coalesce(s.marked_review,false) then 80 else 0 end
       +least(180,coalesce(floor(extract(epoch from(now()-s.last_attempt))/86400)::int*6,140))
       +case when q.subject='Current Affairs' and q.source_date is not null
          then greatest(0,120-(current_date-q.source_date)) else 0 end as priority
   from gk.questions q
   left join gk.question_state s on s.user_id=uid and s.question_id=q.question_id
   where q.active
     and (lane_name in ('MIXED','ALL') or upper(q.content_lane)=lane_name)
     and (p_subject is null or q.subject=p_subject)
     and (p_topic is null or q.topic=p_topic)
     and (p_lecture_key is null or q.lecture_key=p_lecture_key)
     and (p_library_key is null or gk.derive_library_key(q.question_id,q.source_label,q.subject)=p_library_key)
     and (p_ca_category is null or q.topic=p_ca_category)
     and (p_ca_months is null or p_ca_months<=0 or q.source_date>=((current_date-make_interval(months=>p_ca_months))::date))
     and (p_demand_id is null or exists(
       select 1 from gk.demand_sets d,
         jsonb_array_elements_text(coalesce(d.question_ids,'[]'::jsonb)) j(question_id)
       where d.demand_id=p_demand_id and d.active and j.question_id=q.question_id
     ))
 ), eligible as (
   select * from base b where
     case
       when mode_name in ('new','unseen','new_v2','new_random') then not b.exposed
       when mode_name in ('weak','weak_practice') then b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name='persistent_weak' then b.st='Persistent Weak'
       when mode_name='starred_persistent' then b.starred and b.st='Persistent Weak'
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
       when mode_name='guessed_repeated' then b.unconfirmed_guess and b.guessed_attempts>=2
       when mode_name='guessed_weak' then b.unconfirmed_guess and b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name='guessed_due' then b.unconfirmed_guess and b.due
       when mode_name in ('recall','recall_check') then b.exposed and b.st<>'Proven Mastered'
       when mode_name in ('daily','smart') then b.st<>'Proven Mastered'
       when mode_name like 'current_%' then b.subject='Current Affairs'
       else true
     end
 ), ranked as (
   select e.*,
     row_number() over(order by
       case when mode_name in ('random','new_random','starred_random','guessed_random','current_random') then random() else 0 end,
       case when mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen_evidence,to_timestamp(0))) else 0 end asc,
       case when mode_name in ('starred_longest','starred_oldest') then extract(epoch from coalesce(e.starred_last_revision,to_timestamp(0))) else 0 end asc,
       case when mode_name='guessed_oldest' then extract(epoch from coalesce(e.last_guess_at,to_timestamp(0))) else 0 end asc,
       case when mode_name='guessed_recent' then extract(epoch from coalesce(e.last_guess_at,to_timestamp(0))) else 0 end desc,
       case when mode_name='starred_smart'
         then e.priority+least(320,greatest(0,floor(extract(epoch from(now()-coalesce(e.starred_last_revision,e.starred_at,to_timestamp(0))))/86400)::int)*10)
         else e.priority end desc,
       e.priority desc,e.question_id
     ) ord
   from eligible e
 ), chosen as (
   select * from ranked order by ord limit n
 )
 select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,c.question_id) order by c.ord),'[]'::jsonb)
 into out from chosen c;
 return out;
end
$$;

create or replace function public.gk_get_catalog()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
qb as (
 select q.*,gk.derive_library_key(q.question_id,q.source_label,q.subject) library_key,
   exists(select 1 from gk.exposures e where e.user_id=u.uid and e.question_id=q.question_id) exposed,
   coalesce(s.learning_status,'New') st
 from gk.questions q cross join u
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active
), lectures as (
 select library_key,q.lecture_key,q.lecture_no,
   max(coalesce(nullif(q.source_label,''),l.title,'Lecture')) title,
   max(q.source_date) source_date,
   count(*)::int total,
   count(*) filter(where upper(q.content_lane)='MAIN')::int main,
   count(*) filter(where upper(q.content_lane)='RAPID')::int rapid,
   count(*) filter(where exposed)::int attempted,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak
 from qb q
 left join gk.lectures l on l.lecture_key=q.lecture_key
 where q.lecture_key is not null
 group by library_key,q.lecture_key,q.lecture_no
), libraries as (
 select x.key,x.title,x.icon,count(l.lecture_key)::int lectures,coalesce(sum(l.total),0)::int questions
 from (values
   ('subject-pyq','Subject-wise PYQ','▤'),
   ('mixed','Mixed PYQ','▦'),
   ('nitto','Nitto Series','⚡'),
   ('misc','MISC','◫')
 ) x(key,title,icon)
 left join lectures l on l.library_key=x.key
 group by x.key,x.title,x.icon
), topics as (
 select coalesce(nullif(btrim(q.subject),''),'Unclassified') subject,
   coalesce(nullif(btrim(q.topic),''),'General') topic,
   count(*)::int total,
   count(*) filter(where upper(q.content_lane)='MAIN')::int main,
   count(*) filter(where upper(q.content_lane)='RAPID')::int rapid,
   count(*) filter(where q.st in ('Persistent Weak','Weak','Fragile'))::int weak
 from qb q group by 1,2
), subjects as (
 select subject,sum(total)::int total,sum(main)::int main,sum(rapid)::int rapid,sum(weak)::int weak,
   jsonb_agg(jsonb_build_object(
     'topic',topic,'total',total,'main',main,'rapidRecall',rapid,'weak',weak
   ) order by total desc,topic) topics
 from topics group by subject
), ca as (
 select coalesce(nullif(btrim(topic),''),'General') category,count(*)::int count,
   min(source_date) "minDate",max(source_date) "maxDate"
 from qb where subject='Current Affairs' group by 1
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'libraries',(select jsonb_agg(to_jsonb(libraries)
      order by case key when 'subject-pyq' then 1 when 'mixed' then 2 when 'nitto' then 3 else 4 end) from libraries),
   'lectures',(select coalesce(jsonb_agg(jsonb_build_object(
      'libraryKey',library_key,'lectureKey',lecture_key,'lectureNo',lecture_no,'title',title,
      'sourceDate',source_date,'total',total,'main',main,'rapidRecall',rapid,'attempted',attempted,'weak',weak
   ) order by source_date,lecture_key),'[]'::jsonb) from lectures),
   'subjects',(select coalesce(jsonb_agg(jsonb_build_object(
      'subject',subject,'total',total,'main',main,'rapidRecall',rapid,'weak',weak,'topics',topics
   ) order by total desc,subject),'[]'::jsonb) from subjects),
   'currentAffairs',(select coalesce(jsonb_agg(to_jsonb(ca) order by count desc,category),'[]'::jsonb) from ca),
   'demandSets',(select coalesce(jsonb_agg(jsonb_build_object(
      'demandId',demand_id,'title',coalesce(title,demand_id),'kind',kind,
      'count',jsonb_array_length(coalesce(question_ids,'[]'::jsonb)),'lastUsed',last_used
   ) order by coalesce(last_used,created_at) desc nulls last,demand_id),'[]'::jsonb)
      from gk.demand_sets where active)
 ) end
$$;

create or replace function public.gk_get_concept_catalog(
 p_subject text default null,
 p_topic text default null
) returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), rows as (
 select q.concept_id,q.subject,q.topic,
   count(*)::int total,
   count(*) filter(where upper(q.content_lane)='MAIN')::int main,
   count(*) filter(where upper(q.content_lane)='RAPID')::int rapid,
   count(*) filter(where coalesce(s.learning_status,'New') in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where not exists(
      select 1 from gk.exposures e where e.user_id=u.uid and e.question_id=q.question_id
   ))::int unseen,
   count(*) filter(where coalesce(s.learning_status,'New')='Proven Mastered')::int mastered
 from gk.questions q cross join u
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active and nullif(btrim(q.concept_id),'') is not null
   and (p_subject is null or q.subject=p_subject)
   and (p_topic is null or q.topic=p_topic)
 group by q.concept_id,q.subject,q.topic
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'concepts',coalesce((select jsonb_agg(jsonb_build_object(
     'conceptId',concept_id,'subject',subject,'topic',topic,'total',total,
     'main',main,'rapidRecall',rapid,'weak',weak,'unseen',unseen,'mastered',mastered
   ) order by subject,topic,concept_id) from rows),'[]'::jsonb)
 ) end
$$;

create or replace function public.gk_get_concept_batch(
 p_concept_id text,
 p_lane text default 'MIXED',
 p_mode text default 'all',
 p_count integer default 20
) returns jsonb
language sql
volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), scopes as (
 select distinct q.subject,q.topic
 from gk.questions q
 where q.active and q.concept_id=p_concept_id
), expanded as (
 select x.item,x.ord
 from scopes s
 cross join lateral jsonb_array_elements(
   public.gk_get_batch(p_mode,100,p_lane,s.subject,s.topic,null,null,null,null,null)
 ) with ordinality x(item,ord)
), exact as (
 select item,min(ord)::bigint ord
 from expanded
 where item->>'concept_id'=p_concept_id
 group by item
 order by min(ord),item->>'id'
 limit greatest(1,least(100,coalesce(p_count,20)))
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else coalesce(jsonb_agg(item order by ord,item->>'id'),'[]'::jsonb) end
from exact
$$;

create or replace function public.gk_get_home_snapshot()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
q as (
 select count(*)::int total,
   count(*) filter(where upper(content_lane)='MAIN')::int main,
   count(*) filter(where upper(content_lane)='RAPID')::int rapid
 from gk.questions where active
), st as (
 select
   count(*) filter(where s.learning_status='Persistent Weak')::int persistent_weak,
   count(*) filter(where s.learning_status='Weak')::int weak,
   count(*) filter(where s.learning_status='Fragile')::int fragile,
   count(*) filter(where s.learning_status='Strong')::int strong,
   count(*) filter(where s.learning_status='Proven Mastered')::int mastered,
   count(*) filter(where s.next_review<=now())::int due,
   count(*) filter(where s.marked_review)::int starred,
   count(*) filter(where s.difficult)::int difficult,
   count(*) filter(where s.unconfirmed_guess)::int guessed,
   coalesce(round(sum(coalesce(s.retention_correct,0))*100.0/
      nullif(sum(coalesce(s.retention_attempts,0)),0),1),0) retention_accuracy
 from gk.questions q cross join u
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active
), e as (
 select count(distinct e.question_id)::int exposed
 from gk.exposures e cross join u
 join gk.questions q on q.question_id=e.question_id and q.active
 where e.user_id=u.uid
), fa as (
 select count(*)::int n,count(*) filter(where is_correct)::int correct
 from (
   select distinct on (a.question_id) a.question_id,a.is_correct
   from gk.attempts a cross join u
   join gk.questions q on q.question_id=a.question_id and q.active
   where a.user_id=u.uid
   order by a.question_id,a.attempted_at,a.attempt_id
 ) x
), r as (
 select session_id,title,mode,position_index,current_index,updated_at
 from gk.sessions cross join u
 where user_id=u.uid and not completed
 order by updated_at desc nulls last,created_at desc
 limit 1
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'summary',jsonb_build_object(
     'total',q.total,'eligibleTotal',q.total,'eligibleMain',q.main,'eligibleRapidRecall',q.rapid,
     'exposed',e.exposed,'bankExposure',case when q.total>0 then round(e.exposed*100.0/q.total,1) else 0 end,
     'persistentWeak',st.persistent_weak,'weak',st.weak,'fragile',st.fragile,'strong',st.strong,
     'provenMastered',st.mastered,'due',st.due,'starred',st.starred,'difficult',st.difficult,'guessed',st.guessed,
     'firstAttemptAccuracy',case when fa.n>0 then round(fa.correct*100.0/fa.n,1) else 0 end,
     'retentionAccuracy',st.retention_accuracy,'newQuestions',greatest(q.total-e.exposed,0)
   ),
   'resume',(select to_jsonb(r) from r)
 ) end
from q,st,e,fa
$$;

create or replace function public.gk_get_starred_hub()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), rows as (
 select s.question_id,s.learning_status,s.next_review,s.difficult,s.starred_at,s.unconfirmed_guess,
   case when s.starred_at is null then null
     else greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) end age,
   (select max(a.attempted_at) from gk.attempts a
      where a.user_id=u.uid and a.question_id=s.question_id
        and (a.mode like 'starred_%' or a.mode='review')) last_starred_revision
 from gk.question_state s cross join u
 join gk.questions q on q.question_id=s.question_id and q.active
 where s.user_id=u.uid and s.marked_review
), exact_days as (
 select age,('Day '||(age+1)) label,age age_from,age age_to from generate_series(0,9) age
), later_bands as (
 select 10 age,'Days 11–20' label,10 age_from,19 age_to union all
 select 20,'Days 21–30',20,29 union all
 select start_age,('Days '||(start_age+1)||'–'||(start_age+30)),start_age,start_age+29
 from generate_series(30,greatest(30,coalesce((select max(age) from rows),30)),30) start_age
), dated_groups as (
 select d.label,d.age_from,d.age_to,count(r.question_id)::int count,
   count(*) filter(where r.learning_status='Persistent Weak')::int persistent_weak,
   count(*) filter(where r.learning_status in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where r.next_review<=now())::int due,
   count(*) filter(where r.difficult)::int difficult,
   count(*) filter(where r.learning_status not in ('Persistent Weak','Weak','Fragile')
      and not coalesce(r.next_review<=now(),false))::int healthy
 from (select * from exact_days union all select * from later_bands) d
 left join rows r on r.age between d.age_from and d.age_to
 group by d.age,d.label,d.age_from,d.age_to
 having count(r.question_id)>0
), earlier as (
 select 'Earlier'::text label,null::int age_from,null::int age_to,count(*)::int count,
   count(*) filter(where learning_status='Persistent Weak')::int persistent_weak,
   count(*) filter(where learning_status in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where next_review<=now())::int due,
   count(*) filter(where difficult)::int difficult,
   count(*) filter(where learning_status not in ('Persistent Weak','Weak','Fragile')
      and not coalesce(next_review<=now(),false))::int healthy
 from rows where starred_at is null
 having count(*)>0
), groups as (
 select * from dated_groups union all select * from earlier
), summary as (
 select count(*)::int starred,
   count(*) filter(where learning_status in ('Persistent Weak','Weak','Fragile')
      or next_review<=now() or unconfirmed_guess)::int focus,
   count(*) filter(where difficult)::int difficult,
   count(*) filter(where learning_status='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,
   count(*) filter(where last_starred_revision is null)::int never_revised
 from rows
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'summary',(select to_jsonb(summary) from summary),
   'groups',(select coalesce(jsonb_agg(jsonb_build_object(
      'label',label,'ageFrom',age_from,'ageTo',age_to,'count',count,
      'health',jsonb_build_object(
        'persistentWeak',persistent_weak,'weakFragile',weak_fragile,'due',due,
        'difficult',difficult,'healthy',healthy
      )
   ) order by case when age_to<=9 then 0 when age_from is not null then 1 else 2 end,
      case when age_to<=9 then -age_from else age_from end nulls last),'[]'::jsonb) from groups)
 ) end
$$;

create or replace function public.gk_get_on_demand_hub()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), b as (
 select q.question_id,q.subject,q.topic,q.concept_id,
   coalesce(s.learning_status,'New') st,
   coalesce(s.unconfirmed_guess,false) guessed,
   coalesce(s.difficult,false) difficult,
   case when coalesce(s.retention_attempts,0)>0
      then round(coalesce(s.retention_correct,0)*100.0/s.retention_attempts,1) else 0 end retention_accuracy,
   exists(select 1 from gk.exposures e where e.user_id=u.uid and e.question_id=q.question_id) exposed
 from gk.questions q cross join u
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active
), concepts as (
 select coalesce(nullif(concept_id,''),coalesce(subject,'')||'|'||coalesce(topic,'General')) concept_id,
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*) filter(where st='Persistent Weak')::int persistent_weak,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   coalesce(round(avg(retention_accuracy) filter(where retention_accuracy>0),1),0) retention_accuracy
 from b group by 1,2,3
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'stats',jsonb_build_object(
     'weak',(select count(*) from b where st in ('Persistent Weak','Weak','Fragile')),
     'guessed',(select count(*) from b where guessed),
     'difficult',(select count(*) from b where difficult),
     'longUnseen',(select count(*) from b where not exposed)
   ),
   'weakTopics',(select coalesce(jsonb_agg(to_jsonb(x)
      order by persistent_weak desc,weak desc,topic),'[]'::jsonb)
      from (select * from concepts where weak>0 limit 30) x),
   'myDemandSets',(select coalesce(jsonb_agg(jsonb_build_object(
      'demandId',demand_id,'title',coalesce(title,demand_id),'kind',kind,
      'count',jsonb_array_length(coalesce(question_ids,'[]'::jsonb)),'lastUsed',last_used
   ) order by coalesce(last_used,created_at) desc nulls last,demand_id),'[]'::jsonb)
      from gk.demand_sets where active)
 ) end
$$;

create or replace function public.gk_get_progress()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), base as (
 select q.question_id,q.subject,q.topic,q.concept_id,q.lecture_key,q.source_label,q.source_date,
   coalesce(s.learning_status,'New') st,
   coalesce(s.retention_attempts,0) ret_attempts,
   coalesce(s.retention_correct,0) ret_correct,
   coalesce(s.marked_review,false) starred,
   coalesce(s.difficult,false) difficult,
   coalesce(s.guessed_attempts,0) guessed_attempts,
   coalesce(s.unconfirmed_guess,false) guessed,
   s.next_review,
   exists(select 1 from gk.exposures e where e.user_id=u.uid and e.question_id=q.question_id) exposed,
   (select a.is_correct from gk.attempts a
      where a.user_id=u.uid and a.question_id=q.question_id
      order by a.attempted_at,a.attempt_id limit 1) first_ok
 from gk.questions q cross join u
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active
), subject_rows as (
 select coalesce(subject,'Unclassified') subject,count(*)::int total,
   count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base group by 1
), concepts as (
 select coalesce(nullif(concept_id,''),coalesce(subject,'')||'|'||coalesce(topic,'General')) "conceptId",
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*)::int total,count(*) filter(where exposed)::int attempted,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st in ('Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,
   count(*) filter(where guessed)::int guessed,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base group by 1,2,3
), lectures as (
 select lecture_key,max(source_label) title,count(*)::int total,
   count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered
 from base where lecture_key is not null group by lecture_key
), ca as (
 select case
   when source_date>=current_date-interval '1 month' then '1 Month'
   when source_date>=current_date-interval '3 months' then '3 Months'
   when source_date>=current_date-interval '6 months' then '6 Months'
   else 'Older' end band,
   count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where guessed)::int guessed
 from base where subject='Current Affairs' group by 1
), top as (
 select count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st='Weak')::int weak,
   count(*) filter(where st='Fragile')::int fragile,
   count(*) filter(where st='Strong')::int strong,
   count(*) filter(where st='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,
   count(*) filter(where starred)::int starred,
   count(*) filter(where difficult)::int difficult,
   count(*) filter(where guessed)::int guessed,
   coalesce(round(count(*) filter(where first_ok is true)*100.0/
      nullif(count(*) filter(where first_ok is not null),0),1),0) "firstAccuracy",
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base
), concept_top as (
 select count(*) filter(where "persistentWeak">0)::int "persistentWeakConcepts",
   count(*) filter(where weak>0 or "persistentWeak">0)::int "weakConcepts"
 from concepts
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
   'ok',true,
   'overview',(select to_jsonb(top)||to_jsonb(concept_top) from top cross join concept_top),
   'knowledgeHealth',(select jsonb_build_array(
      jsonb_build_object('state','Persistent Weak','count',"persistentWeak"),
      jsonb_build_object('state','Weak','count',weak),
      jsonb_build_object('state','Fragile','count',fragile),
      jsonb_build_object('state','Strong','count',strong),
      jsonb_build_object('state','Proven Mastered','count',mastered)
   ) from top),
   'subjectMastery',(select coalesce(jsonb_agg(to_jsonb(subject_rows)
      order by total desc,subject),'[]'::jsonb) from subject_rows),
   'weakConcepts',(select coalesce(jsonb_agg(to_jsonb(c)
      order by "persistentWeak" desc,weak desc,total desc),'[]'::jsonb)
      from (select * from concepts where "persistentWeak"+weak>0 limit 50) c),
   'currentAffairsHealth',(select coalesce(jsonb_agg(to_jsonb(ca)
      order by case band when '1 Month' then 1 when '3 Months' then 2 when '6 Months' then 3 else 4 end),'[]'::jsonb) from ca),
   'starredHealth',(select jsonb_build_object(
      'total',starred,
      'focus',(select count(*) from base where starred and
         (st in ('Persistent Weak','Weak','Fragile') or next_review<=now() or guessed)),
      'due',(select count(*) from base where starred and next_review<=now()),
      'difficult',(select count(*) from base where starred and difficult),
      'mastered',(select count(*) from base where starred and st='Proven Mastered')
   ) from top),
   'guessedHealth',(select jsonb_build_object(
      'historicallyGuessed',(select count(*) from base where guessed_attempts>0),
      'unresolved',guessed,
      'repeated',(select count(*) from base where guessed and guessed_attempts>=2),
      'due',(select count(*) from base where guessed and next_review<=now())
   ) from top),
   'difficultResolution',(select jsonb_build_object(
      'total',difficult,
      'resolvedStrong',(select count(*) from base where difficult and st in ('Strong','Proven Mastered')),
      'needsFocus',(select count(*) from base where difficult and
         (st in ('Persistent Weak','Weak','Fragile') or next_review<=now()))
   ) from top),
   'lectureCoverage',(select coalesce(jsonb_agg(jsonb_build_object(
      'lecture_key',lecture_key,'title',title,'total',total,'exposed',exposed,'weak',weak,'mastered',mastered
   ) order by case when total>0 then exposed::numeric/total else 0 end asc,title),'[]'::jsonb) from lectures)
 ) end
$$;

create or replace function public.gk_get_question_intelligence(
 p_question_id text,
 p_session_id text default null
) returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), q as (
 select * from gk.questions where question_id=p_question_id and active
), payload as (
 select gk.question_payload_v2_read((select uid from u),p_question_id) p
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else coalesce((select p->'state' from payload),'{}'::jsonb)
   || jsonb_build_object(
     'ok',true,
     'questionId',q.question_id,'conceptId',q.concept_id,'subject',q.subject,'topic',q.topic,'lectureKey',q.lecture_key,
     'selectionReason',coalesce((
       select s.composition->'reasons'->>q.question_id
       from gk.sessions s
       where s.user_id=(select uid from u) and s.session_id=p_session_id
     ),''),
     'conceptHealth',(
       select jsonb_build_object(
         'total',count(*),
         'attempted',count(*) filter(where exists(
           select 1 from gk.exposures e
           where e.user_id=(select uid from u) and e.question_id=q2.question_id
         )),
         'weak',count(*) filter(where st.learning_status in ('Persistent Weak','Weak','Fragile')),
         'mastered',count(*) filter(where st.learning_status='Proven Mastered'),
         'guessed',count(*) filter(where st.unconfirmed_guess)
       )
       from gk.questions q2
       left join gk.question_state st
         on st.user_id=(select uid from u) and st.question_id=q2.question_id
       where q2.active and coalesce(q2.concept_id,'')=coalesce(q.concept_id,'')
     )
   ) end
from q
$$;

revoke execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) from public,anon;
revoke execute on function public.gk_get_catalog() from public,anon;
revoke execute on function public.gk_get_concept_catalog(text,text) from public,anon;
revoke execute on function public.gk_get_concept_batch(text,text,text,integer) from public,anon;
revoke execute on function public.gk_get_home_snapshot() from public,anon;
revoke execute on function public.gk_get_starred_hub() from public,anon;
revoke execute on function public.gk_get_on_demand_hub() from public,anon;
revoke execute on function public.gk_get_progress() from public,anon;
revoke execute on function public.gk_get_question_intelligence(text,text) from public,anon;

grant execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) to authenticated;
grant execute on function public.gk_get_catalog() to authenticated;
grant execute on function public.gk_get_concept_catalog(text,text) to authenticated;
grant execute on function public.gk_get_concept_batch(text,text,text,integer) to authenticated;
grant execute on function public.gk_get_home_snapshot() to authenticated;
grant execute on function public.gk_get_starred_hub() to authenticated;
grant execute on function public.gk_get_on_demand_hub() to authenticated;
grant execute on function public.gk_get_progress() to authenticated;
grant execute on function public.gk_get_question_intelligence(text,text) to authenticated;
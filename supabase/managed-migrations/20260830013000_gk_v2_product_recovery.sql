-- GK V2 product recovery.
-- Old GK remains the semantic authority; this migration ports those contracts onto
-- the migrated Supabase schema without renumbering questions or destroying history.

alter table gk.questions add column if not exists library_key text;
alter table gk.questions add column if not exists chapter text;
alter table gk.questions add column if not exists subtopic text;
alter table gk.questions add column if not exists confusion_pair_id text;
alter table gk.questions add column if not exists fact_family_id text;

alter table gk.question_state add column if not exists retention_accuracy numeric;
alter table gk.question_state add column if not exists recent_spaced_failures integer not null default 0;
alter table gk.question_state add column if not exists last_spaced_correct timestamptz;
alter table gk.question_state add column if not exists last_spaced_wrong timestamptz;

-- Preserve the migrated canonical Main/Rapid classification. Only fill genuinely
-- missing values from the old canonical content_type semantics.
update gk.questions
set content_lane = case when lower(coalesce(content_type,''))='rapid recall' then 'RAPID' else 'MAIN' end
where content_lane is null or btrim(content_lane)='';

update gk.questions
set library_key = case
  when lower(coalesce(source_label,'')) like '%nitto%' or upper(question_id) like 'NIT%' then 'nitto'
  when lower(coalesce(source_label,'')) like '%mixed%' then 'mixed'
  when lower(coalesce(source_label,'')) like '%pyq%' or upper(question_id) ~ '^POL[0-9]' or upper(question_id) ~ '^ECO' then 'subject-pyq'
  when coalesce(subject,'') <> '' and lower(coalesce(source_label,'')) like '%lecture%' then 'subject-pyq'
  else 'misc'
end
where library_key is null or btrim(library_key)='';

create index if not exists gk_questions_library_idx on gk.questions(library_key,active,lecture_key);
create index if not exists gk_questions_academic_idx on gk.questions(subject,topic,active);
create index if not exists gk_questions_source_date_idx on gk.questions(source_date,active);
create index if not exists gk_state_priority_idx on gk.question_state(user_id,learning_status,next_review);
create index if not exists gk_state_star_idx on gk.question_state(user_id,starred_at) where starred_at is not null;
create index if not exists gk_state_guess_idx on gk.question_state(user_id,unconfirmed_guess) where unconfirmed_guess;
create index if not exists gk_attempts_evidence_idx on gk.attempts(user_id,question_id,attempted_at,attempt_id);
create index if not exists gk_exposures_user_question_idx on gk.exposures(user_id,question_id,exposed_at);
create unique index if not exists gk_daily_one_per_study_date_idx on gk.sessions(user_id,study_date) where mode='daily';

create or replace function gk.current_study_date()
returns date
language sql
stable
set search_path=pg_catalog
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- Normalized question contract consumed by the single React quiz engine.
create or replace function gk.question_payload(p_user_id uuid,p_question_id text)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,gk,auth
as $$
select to_jsonb(q)-'source_payload'||jsonb_build_object(
 'id',q.question_id,
 'question_id',q.question_id,
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
   'firstAttemptCorrect',s.first_attempt_correct,
   'retentionAttempts',coalesce(s.retention_attempts,0),
   'retentionCorrect',coalesce(s.retention_correct,0),
   'retentionWrong',coalesce(s.retention_wrong,0),
   'retentionAccuracy',coalesce(s.retention_accuracy,0),
   'recentSpacedFailures',coalesce(s.recent_spaced_failures,0),
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
   'exposureCount',coalesce(s.exposure_count,0),
   'firstSeen',s.first_seen,
   'lastSeen',s.last_seen,
   'flagged',coalesce(s.flag_active,false),
   'flagReason',coalesce(s.flag_reason,''),
   'note',coalesce(n.note,'')
 )
)
from gk.questions q
left join gk.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
left join gk.user_notes n on n.user_id=p_user_id and n.question_id=q.question_id
where q.question_id=p_question_id and q.active;
$$;

-- Raw attempts remain primary evidence. QuestionState is refreshed from them using
-- the old GK 18-hour retention-gap contract; immediate same-session corrections
-- cannot prove retention.
create or replace function gk.refresh_question_state(p_user_id uuid,p_question_id text)
returns gk.question_state
language plpgsql
security definer
set search_path=pg_catalog,gk,auth
as $$
declare
 total_n int:=0; correct_n int:=0; wrong_n int:=0; guessed_n int:=0;
 ret_n int:=0; ret_correct int:=0; ret_wrong int:=0; confirmed_n int:=0;
 recent_failures int:=0; exposure_n int:=0;
 first_correct boolean:=null; latest_correct boolean:=null; latest_spaced_correct boolean:=null;
 last_attempt_at timestamptz:=null; last_spaced_at timestamptz:=null;
 last_spaced_correct_at timestamptz:=null; last_spaced_wrong_at timestamptz:=null;
 last_guess_at_v timestamptz:=null; first_seen_v timestamptz:=null; last_seen_v timestamptz:=null;
 unresolved boolean:=false; ret_accuracy numeric:=0; overall_accuracy numeric:=0;
 state_name text:='New'; latest_result_v text:=''; meaningful_result_v text:='';
 next_review_v timestamptz:=null; review_days int:=2; existing gk.question_state%rowtype;
begin
 with ordered as(
   select attempt_id,attempted_at,
     extract(epoch from (attempted_at-lag(attempted_at) over(order by attempted_at,attempt_id)))/3600.0 as gap
   from gk.attempts where user_id=p_user_id and question_id=p_question_id
 ), calc as(
   select attempt_id,gap,coalesce(gap>=18,false) spaced from ordered
 )
 update gk.attempts a set gap_hours=c.gap,is_spaced=c.spaced
 from calc c where a.attempt_id=c.attempt_id and (a.gap_hours is distinct from c.gap or a.is_spaced is distinct from c.spaced);

 select count(*)::int,
        count(*) filter(where is_correct)::int,
        count(*) filter(where not is_correct)::int,
        count(*) filter(where guessed)::int,
        count(*) filter(where is_spaced)::int,
        count(*) filter(where is_spaced and is_correct)::int,
        count(*) filter(where is_spaced and not is_correct)::int,
        count(*) filter(where is_spaced and is_correct and not coalesce(guessed,false))::int
 into total_n,correct_n,wrong_n,guessed_n,ret_n,ret_correct,ret_wrong,confirmed_n
 from gk.attempts where user_id=p_user_id and question_id=p_question_id;

 select a.is_correct,a.attempted_at into first_correct,last_attempt_at
 from gk.attempts a where a.user_id=p_user_id and a.question_id=p_question_id
 order by a.attempted_at,a.attempt_id limit 1;
 select a.is_correct,a.attempted_at into latest_correct,last_attempt_at
 from gk.attempts a where a.user_id=p_user_id and a.question_id=p_question_id
 order by a.attempted_at desc,a.attempt_id desc limit 1;
 select a.is_correct,a.attempted_at into latest_spaced_correct,last_spaced_at
 from gk.attempts a where a.user_id=p_user_id and a.question_id=p_question_id and coalesce(a.is_spaced,false)
 order by a.attempted_at desc,a.attempt_id desc limit 1;
 select max(attempted_at) into last_spaced_correct_at from gk.attempts where user_id=p_user_id and question_id=p_question_id and coalesce(is_spaced,false) and is_correct;
 select max(attempted_at) into last_spaced_wrong_at from gk.attempts where user_id=p_user_id and question_id=p_question_id and coalesce(is_spaced,false) and not is_correct;
 select max(attempted_at) into last_guess_at_v from gk.attempts where user_id=p_user_id and question_id=p_question_id and coalesce(guessed,false);
 select count(*)::int into recent_failures from(
   select is_correct from gk.attempts where user_id=p_user_id and question_id=p_question_id and coalesce(is_spaced,false)
   order by attempted_at desc,attempt_id desc limit 3
 ) r where not r.is_correct;

 unresolved:=last_guess_at_v is not null and not exists(
   select 1 from gk.attempts where user_id=p_user_id and question_id=p_question_id
   and coalesce(is_spaced,false) and is_correct and not coalesce(guessed,false) and attempted_at>last_guess_at_v
 );
 ret_accuracy:=case when ret_n>0 then round(ret_correct*1000.0/ret_n)/10.0 else 0 end;
 overall_accuracy:=case when total_n>0 then round(correct_n*1000.0/total_n)/10.0 else 0 end;
 latest_result_v:=case when total_n=0 then '' when latest_correct then 'Correct' else 'Wrong' end;
 meaningful_result_v:=case when ret_n>0 then case when latest_spaced_correct then 'Correct' else 'Wrong' end else latest_result_v end;

 if total_n=0 then state_name:='New';
 elsif recent_failures>=2 or (ret_wrong>=2 and ret_accuracy<60) then state_name:='Persistent Weak';
 elsif (ret_wrong>=1 and (ret_n=0 or not coalesce(latest_spaced_correct,false))) or (wrong_n>=2 and ret_correct=0) then state_name:='Weak';
 elsif unresolved or ret_n<2 then state_name:='Fragile';
 elsif ret_correct>=3 and ret_accuracy>=85 and coalesce(latest_spaced_correct,false) and recent_failures=0 and not unresolved and confirmed_n>=2 then state_name:='Proven Mastered';
 elsif ret_correct>=2 and ret_accuracy>=75 and coalesce(latest_spaced_correct,false) and not unresolved then state_name:='Strong';
 elsif wrong_n>0 or ret_accuracy<70 then state_name:='Weak';
 else state_name:='Learning'; end if;

 review_days:=case state_name when 'Persistent Weak' then 1 when 'Weak' then 1 when 'Fragile' then 2 when 'Learning' then 3 when 'Strong' then 7 when 'Proven Mastered' then 21 else 2 end;
 if coalesce(last_spaced_at,last_attempt_at) is not null then
   next_review_v:=(((coalesce(last_spaced_at,last_attempt_at) at time zone 'Asia/Kolkata')::date + review_days)::timestamp at time zone 'Asia/Kolkata');
 end if;

 select count(*)::int,min(exposed_at),max(exposed_at) into exposure_n,first_seen_v,last_seen_v
 from gk.exposures where user_id=p_user_id and question_id=p_question_id;
 select * into existing from gk.question_state where user_id=p_user_id and question_id=p_question_id;

 insert into gk.question_state(
   user_id,question_id,attempts,correct,wrong,streak,accuracy,last_attempt,next_review,marked_review,learning_status,
   last_selected,last_correct,difficult,starred_at,first_attempt_correct,retention_attempts,retention_correct,retention_wrong,
   last_spaced_attempt,exposure_count,first_seen,last_seen,guessed_attempts,unconfirmed_guess,last_guess_at,
   confirmed_unguessed_spaced_recalls,last_meaningful_result,latest_result,flag_active,flag_reason,flag_note,flag_updated_at,
   learning_updated_at,retention_accuracy,recent_spaced_failures,last_spaced_correct,last_spaced_wrong
 ) values(
   p_user_id,p_question_id,total_n,correct_n,wrong_n,
   case when coalesce(latest_correct,false) then coalesce(existing.streak,0)+case when total_n>coalesce(existing.attempts,0) then 1 else 0 end else 0 end,
   overall_accuracy,last_attempt_at,next_review_v,coalesce(existing.marked_review,false),state_name,
   coalesce(existing.last_selected,(select selected_option from gk.attempts where user_id=p_user_id and question_id=p_question_id order by attempted_at desc,attempt_id desc limit 1)),
   latest_correct,coalesce(existing.difficult,false),existing.starred_at,first_correct,ret_n,ret_correct,ret_wrong,last_spaced_at,
   exposure_n,first_seen_v,last_seen_v,guessed_n,unresolved,last_guess_at_v,confirmed_n,meaningful_result_v,latest_result_v,
   coalesce(existing.flag_active,false),existing.flag_reason,existing.flag_note,existing.flag_updated_at,now(),ret_accuracy,recent_failures,last_spaced_correct_at,last_spaced_wrong_at
 ) on conflict(user_id,question_id) do update set
   attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,accuracy=excluded.accuracy,last_attempt=excluded.last_attempt,
   next_review=excluded.next_review,learning_status=excluded.learning_status,last_selected=excluded.last_selected,last_correct=excluded.last_correct,
   first_attempt_correct=excluded.first_attempt_correct,retention_attempts=excluded.retention_attempts,retention_correct=excluded.retention_correct,
   retention_wrong=excluded.retention_wrong,last_spaced_attempt=excluded.last_spaced_attempt,exposure_count=excluded.exposure_count,
   first_seen=excluded.first_seen,last_seen=excluded.last_seen,guessed_attempts=excluded.guessed_attempts,unconfirmed_guess=excluded.unconfirmed_guess,
   last_guess_at=excluded.last_guess_at,confirmed_unguessed_spaced_recalls=excluded.confirmed_unguessed_spaced_recalls,
   last_meaningful_result=excluded.last_meaningful_result,latest_result=excluded.latest_result,learning_updated_at=now(),
   retention_accuracy=excluded.retention_accuracy,recent_spaced_failures=excluded.recent_spaced_failures,
   last_spaced_correct=excluded.last_spaced_correct,last_spaced_wrong=excluded.last_spaced_wrong;
 return (select s from gk.question_state s where s.user_id=p_user_id and s.question_id=p_question_id);
end;
$$;

-- Central semantic selector: feature routes choose WHAT; the React quiz engine controls HOW.
create or replace function public.gk_get_batch(
 p_mode text default 'smart',p_count integer default 20,p_lane text default 'MIXED',
 p_subject text default null,p_topic text default null,p_lecture_key text default null,p_library_key text default null,
 p_demand_id text default null,p_ca_months integer default null,p_ca_category text default null
) returns jsonb
language plpgsql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); mode_name text:=lower(btrim(coalesce(p_mode,'smart'))); lane_name text:=upper(btrim(coalesce(p_lane,'MIXED'))); n int:=greatest(1,least(100,coalesce(p_count,20))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if lane_name not in ('MAIN','RAPID','MIXED','ALL') then raise exception 'Invalid GK question style'; end if;
 with base as(
   select q.*,
     coalesce(s.learning_status,'New') st,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
     coalesce(s.retention_attempts,0) retention_attempts,coalesce(s.retention_accuracy,0) retention_accuracy,
     coalesce(s.difficult,false) difficult,coalesce(s.marked_review,false) starred,coalesce(s.unconfirmed_guess,false) unconfirmed_guess,
     s.starred_at,s.last_attempt,s.last_seen,s.next_review,
     coalesce(s.next_review<=now(),false) due,
     exists(select 1 from gk.exposures e where e.user_id=uid and e.question_id=q.question_id) exposed,
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
     and (p_ca_months is null or p_ca_months<=0 or q.source_date>=((current_date - make_interval(months=>p_ca_months))::date))
     and (p_demand_id is null or exists(
       select 1 from gk.demand_sets d,jsonb_array_elements_text(coalesce(d.question_ids,'[]'::jsonb)) j(question_id)
       where d.demand_id=p_demand_id and d.active and j.question_id=q.question_id
     ))
 ), eligible as(
   select * from base b where
     case
       when mode_name in ('new','unseen','new_v2') then not b.exposed
       when mode_name in ('weak','weak_practice') then b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name in ('persistent_weak','starred_persistent') then b.st='Persistent Weak' and (mode_name='persistent_weak' or b.starred)
       when mode_name in ('due','due_recall') then b.due
       when mode_name='difficult' then b.difficult
       when mode_name in ('starred','starred_smart') then b.starred
       when mode_name='starred_weak' then b.starred and b.st in ('Persistent Weak','Weak','Fragile')
       when mode_name='starred_due' then b.starred and b.due
       when mode_name='starred_difficult' then b.starred and b.difficult
       when mode_name='starred_never' then b.starred and not exists(select 1 from gk.attempts a where a.user_id=uid and a.question_id=b.question_id and a.attempted_at>b.starred_at)
       when mode_name in ('starred_oldest','starred_random') then b.starred
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
       case when mode_name in ('random','starred_random','guessed_random','current_random') then random() else 0 end,
       case when mode_name='starred_oldest' then extract(epoch from coalesce(e.last_attempt,e.starred_at,to_timestamp(0))) else 0 end asc,
       case when mode_name='guessed_oldest' then extract(epoch from coalesce((select s3.last_guess_at from gk.question_state s3 where s3.user_id=uid and s3.question_id=e.question_id),to_timestamp(0))) else 0 end asc,
       case when mode_name='guessed_recent' then extract(epoch from coalesce((select s4.last_guess_at from gk.question_state s4 where s4.user_id=uid and s4.question_id=e.question_id),to_timestamp(0))) else 0 end desc,
       e.priority desc,e.question_id
     ) ord
   from eligible e
 ), chosen as(select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(gk.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end;
$$;

create or replace function public.gk_get_lane_batch(p_lane text,p_mode text default 'all',p_count integer default 20)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
 select public.gk_get_batch(p_mode,p_count,p_lane,null,null,null,null,null,null,null); $$;

create or replace function public.gk_get_lecture_batch(p_lecture_key text,p_lane text default 'MIXED',p_mode text default 'all',p_count integer default 20)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
 select public.gk_get_batch(p_mode,p_count,p_lane,null,null,p_lecture_key,null,null,null,null); $$;

create or replace function public.gk_get_subject_batch(p_subject text,p_topic text default null,p_lane text default 'MIXED',p_mode text default 'all',p_count integer default 20)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
 select public.gk_get_batch(p_mode,p_count,p_lane,p_subject,p_topic,null,null,null,null,null); $$;

create or replace function public.gk_get_smart_revision(p_mode text default 'smart',p_count integer default 20)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
 select public.gk_get_batch(p_mode,p_count,'MIXED',null,null,null,null,null,null,null); $$;

create or replace function public.gk_get_catalog()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), lectures as(
 select q.library_key,q.lecture_key,q.lecture_no,max(coalesce(q.source_label,l.title,'Lecture')) title,max(q.source_date) source_date,
   count(*)::int total,count(*) filter(where q.content_lane='MAIN')::int main,count(*) filter(where q.content_lane='RAPID')::int rapid,
   count(*) filter(where coalesce(s.attempts,0)>0)::int attempted,
   count(*) filter(where coalesce(s.learning_status,'New') in ('Persistent Weak','Weak','Fragile'))::int weak
 from gk.questions q cross join u left join gk.lectures l on l.lecture_key=q.lecture_key
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active group by q.library_key,q.lecture_key,q.lecture_no
), libraries as(
 select x.key,x.title,x.icon,count(l.lecture_key)::int lectures,coalesce(sum(l.total),0)::int questions
 from (values('subject-pyq','Subject-wise PYQ','▤'),('mixed','Mixed PYQ','▦'),('nitto','Nitto Series','⚡'),('misc','MISC','◫')) x(key,title,icon)
 left join lectures l on l.library_key=x.key group by x.key,x.title,x.icon
), topics as(
 select coalesce(nullif(btrim(q.subject),''),'Unclassified') subject,coalesce(nullif(btrim(q.topic),''),'General') topic,
   count(*)::int total,count(*) filter(where q.content_lane='MAIN')::int main,count(*) filter(where q.content_lane='RAPID')::int rapid,
   count(*) filter(where coalesce(s.learning_status,'New') in ('Persistent Weak','Weak','Fragile'))::int weak
 from gk.questions q cross join u left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id where q.active group by 1,2
), subjects as(
 select subject,sum(total)::int total,sum(main)::int main,sum(rapid)::int rapid,sum(weak)::int weak,
   jsonb_agg(jsonb_build_object('topic',topic,'total',total,'main',main,'rapidRecall',rapid,'weak',weak) order by total desc,topic) topics
 from topics group by subject
), ca as(
 select coalesce(nullif(btrim(topic),''),'General') category,count(*)::int count,min(source_date) minDate,max(source_date) maxDate
 from gk.questions where active and subject='Current Affairs' group by 1
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'libraries',(select jsonb_agg(to_jsonb(libraries) order by case key when 'subject-pyq' then 1 when 'mixed' then 2 when 'nitto' then 3 else 4 end) from libraries),
 'lectures',(select coalesce(jsonb_agg(jsonb_build_object('libraryKey',library_key,'lectureKey',lecture_key,'lectureNo',lecture_no,'title',title,'sourceDate',source_date,'total',total,'main',main,'rapidRecall',rapid,'attempted',attempted,'weak',weak) order by source_date,lecture_key),'[]'::jsonb) from lectures),
 'subjects',(select coalesce(jsonb_agg(jsonb_build_object('subject',subject,'total',total,'main',main,'rapidRecall',rapid,'weak',weak,'topics',topics) order by total desc,subject),'[]'::jsonb) from subjects),
 'currentAffairs',(select coalesce(jsonb_agg(to_jsonb(ca) order by count desc,category),'[]'::jsonb) from ca),
 'demandSets',(select coalesce(jsonb_agg(jsonb_build_object('demandId',demand_id,'title',coalesce(title,demand_id),'kind',kind,'count',jsonb_array_length(coalesce(question_ids,'[]'::jsonb)),'lastUsed',last_used) order by coalesce(last_used,created_at) desc nulls last,demand_id),'[]'::jsonb) from gk.demand_sets where active)
) end;
$$;

create or replace function public.gk_get_home_snapshot()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
with u as(select auth.uid() uid), q as(select count(*)::int total,count(*) filter(where content_lane='MAIN')::int main,count(*) filter(where content_lane='RAPID')::int rapid from gk.questions where active),
s as(select count(*)::int attempted,count(*) filter(where learning_status='Persistent Weak')::int persistent_weak,count(*) filter(where learning_status='Weak')::int weak,
 count(*) filter(where learning_status='Fragile')::int fragile,count(*) filter(where learning_status='Strong')::int strong,count(*) filter(where learning_status='Proven Mastered')::int mastered,
 count(*) filter(where next_review<=now())::int due,count(*) filter(where marked_review)::int starred,count(*) filter(where difficult)::int difficult,count(*) filter(where unconfirmed_guess)::int guessed,
 coalesce(round(sum(correct)*100.0/nullif(sum(attempts),0),1),0) accuracy,
 coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention_accuracy
 from gk.question_state cross join u where user_id=u.uid), e as(select count(distinct question_id)::int exposed from gk.exposures cross join u where user_id=u.uid),
r as(select session_id,title,mode,position_index,current_index,updated_at from gk.sessions cross join u where user_id=u.uid and not completed order by updated_at desc nulls last,created_at desc limit 1)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object('ok',true,'summary',jsonb_build_object(
 'total',q.total,'eligibleTotal',q.total,'eligibleMain',q.main,'eligibleRapidRecall',q.rapid,'exposed',e.exposed,'bankExposure',case when q.total>0 then round(e.exposed*100.0/q.total,1) else 0 end,
 'persistentWeak',s.persistent_weak,'weak',s.weak,'fragile',s.fragile,'strong',s.strong,'provenMastered',s.mastered,'due',s.due,'starred',s.starred,'difficult',s.difficult,'guessed',s.guessed,
 'firstAttemptAccuracy',s.accuracy,'retentionAccuracy',s.retention_accuracy,'newQuestions',greatest(q.total-e.exposed,0)
),'resume',(select to_jsonb(r) from r)) from q,s,e;
$$;

create or replace function public.gk_get_progress()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
with u as(select auth.uid() uid), base as(
 select q.question_id,q.subject,q.topic,q.concept_id,q.lecture_key,q.source_label,q.source_date,q.library_key,
   coalesce(s.learning_status,'New') st,coalesce(s.attempts,0) attempts,coalesce(s.correct,0) correct,coalesce(s.first_attempt_correct,false) first_ok,
   coalesce(s.retention_attempts,0) ret_attempts,coalesce(s.retention_correct,0) ret_correct,coalesce(s.retention_accuracy,0) ret_accuracy,
   coalesce(s.marked_review,false) starred,s.starred_at,coalesce(s.difficult,false) difficult,coalesce(s.unconfirmed_guess,false) guessed,
   coalesce(s.exposure_count,0) exposure_count,s.last_attempt,s.next_review
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
   coalesce(round(count(*) filter(where attempts>0 and first_ok)*100.0/nullif(count(*) filter(where attempts>0),0),1),0) firstAccuracy,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) retentionAccuracy from base
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'overview',(select to_jsonb(top) from top),
 'knowledgeHealth',(select jsonb_build_array(
   jsonb_build_object('state','Persistent Weak','count',persistentWeak),jsonb_build_object('state','Weak','count',weak),jsonb_build_object('state','Fragile','count',fragile),
   jsonb_build_object('state','Strong','count',strong),jsonb_build_object('state','Proven Mastered','count',mastered)) from top),
 'subjectMastery',(select coalesce(jsonb_agg(to_jsonb(subject_rows) order by total desc,subject),'[]'::jsonb) from subject_rows),
 'weakConcepts',(select coalesce(jsonb_agg(to_jsonb(c) order by persistentWeak desc,weak desc,total desc),'[]'::jsonb) from (select * from concepts where persistentWeak+weak>0 limit 50)c),
 'currentAffairsHealth',(select coalesce(jsonb_agg(to_jsonb(ca) order by case band when '1 Month' then 1 when '3 Months' then 2 when '6 Months' then 3 else 4 end),'[]'::jsonb) from ca),
 'starredHealth',(select jsonb_build_object('total',starred,'due',(select count(*) from base where starred and next_review<=now()),'weak',(select count(*) from base where starred and st in ('Persistent Weak','Weak','Fragile')),'neverRevised',(select count(*) from base where starred and attempts=0)) from top),
 'guessedHealth',(select jsonb_build_object('unconfirmed',guessed,'weak',(select count(*) from base where guessed and st in ('Persistent Weak','Weak','Fragile')),'due',(select count(*) from base where guessed and next_review<=now())) from top),
 'difficultResolution',(select jsonb_build_object('active',difficult,'weak',(select count(*) from base where difficult and st in ('Persistent Weak','Weak','Fragile')),'strongOrMastered',(select count(*) from base where difficult and st in ('Strong','Proven Mastered'))) from top),
 'lectureCoverage',(select coalesce(jsonb_agg(to_jsonb(lectures) order by case when total>0 then exposed::numeric/total else 0 end asc,title),'[]'::jsonb) from lectures)
); $$;

create or replace function public.gk_get_question_intelligence(p_question_id text,p_session_id text default null)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else
 coalesce(gk.question_payload(auth.uid(),p_question_id)->'state','{}'::jsonb)||jsonb_build_object(
  'ok',true,'questionId',q.question_id,'conceptId',q.concept_id,'subject',q.subject,'topic',q.topic,'lectureKey',q.lecture_key,
  'selectionReason',coalesce((select s.composition->'reasons'->>q.question_id from gk.sessions s where s.user_id=auth.uid() and s.session_id=p_session_id),''),
  'conceptHealth',(select jsonb_build_object('total',count(*),'attempted',count(*) filter(where coalesce(st.exposure_count,0)>0),'weak',count(*) filter(where st.learning_status in ('Persistent Weak','Weak','Fragile')),'mastered',count(*) filter(where st.learning_status='Proven Mastered'),'guessed',count(*) filter(where st.unconfirmed_guess)) from gk.questions q2 left join gk.question_state st on st.user_id=auth.uid() and st.question_id=q2.question_id where q2.active and coalesce(q2.concept_id,'')=coalesce(q.concept_id,''))
 ) end
from gk.questions q where q.question_id=p_question_id and q.active; $$;

-- Actual display, not selection, creates exposure evidence.
create or replace function public.gk_record_exposure(p_question_id text,p_session_id text,p_mode text default 'practice',p_exposure_id text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid(); sid text:=coalesce(nullif(btrim(p_session_id),''),'adhoc'); eid text:=coalesce(nullif(btrim(p_exposure_id),''),'gk-exp-'||replace(gen_random_uuid()::text,'-','')); ekey text; inserted int; st gk.question_state%rowtype;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from gk.questions where question_id=p_question_id and active) then raise exception 'Question not found'; end if;
 ekey:=uid::text||':'||sid||':'||p_question_id;
 insert into gk.exposures(exposure_id,user_id,exposed_at,question_id,session_id,mode,exposure_key,study_date)
 values(eid,uid,now(),p_question_id,nullif(sid,'adhoc'),coalesce(p_mode,'practice'),ekey,gk.current_study_date()) on conflict(exposure_key) do nothing;
 get diagnostics inserted=row_count;
 insert into gk.question_state(user_id,question_id,exposure_count,first_seen,last_seen,learning_status)
 select uid,p_question_id,count(*)::int,min(exposed_at),max(exposed_at),'New' from gk.exposures where user_id=uid and question_id=p_question_id
 on conflict(user_id,question_id) do update set exposure_count=excluded.exposure_count,first_seen=excluded.first_seen,last_seen=excluded.last_seen;
 select * into st from gk.question_state where user_id=uid and question_id=p_question_id;
 return jsonb_build_object('ok',true,'deduped',inserted=0,'exposureId',eid,'state',to_jsonb(st));
end; $$;

-- Guess annotates the existing answer attempt. It never creates a second attempt.
create or replace function public.gk_mark_guessed(p_question_id text,p_attempt_id text,p_guessed boolean default true,p_mutation_id text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid(); changed int; st gk.question_state%rowtype;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 update gk.attempts set guessed=coalesce(p_guessed,true),guessed_at=case when coalesce(p_guessed,true) then coalesce(guessed_at,now()) else null end
 where user_id=uid and question_id=p_question_id and attempt_id=p_attempt_id;
 get diagnostics changed=row_count;
 if changed=0 then raise exception 'Answer attempt not available yet'; end if;
 st:=gk.refresh_question_state(uid,p_question_id);
 return jsonb_build_object('ok',true,'attemptId',p_attempt_id,'guessed',coalesce(p_guessed,true),'state',to_jsonb(st));
end; $$;

drop function if exists public.gk_submit_answer(text,text,boolean,text,text);
create or replace function public.gk_submit_answer(
 p_question_id text,p_selected_option text,p_marked_review boolean default false,p_attempt_id text default null,p_mode text default 'practice',p_session_id text default null,p_response_ms integer default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid(); q gk.questions%rowtype; aid text; sel text:=upper(btrim(coalesce(p_selected_option,''))); ok boolean; inserted int; st gk.question_state%rowtype;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into q from gk.questions where question_id=btrim(p_question_id) and active; if not found then raise exception 'Question not found'; end if;
 if sel not in ('A','B','C','D') then raise exception 'Invalid answer'; end if;
 ok:=sel=upper(coalesce(q.correct_option,'')); aid:=coalesce(nullif(btrim(p_attempt_id),''),'gk-'||q.question_id||'-'||replace(gen_random_uuid()::text,'-',''));
 insert into gk.attempts(attempt_id,user_id,attempted_at,question_id,selected_option,is_correct,marked_review,mode,session_id,response_ms,submission_key,canonical_selected_option,display_selected_option,attempt_kind,study_date)
 values(aid,uid,now(),q.question_id,sel,ok,coalesce(p_marked_review,false),coalesce(nullif(btrim(p_mode),''),'practice'),nullif(btrim(coalesce(p_session_id,'')),''),p_response_ms,aid,sel,sel,'practice',gk.current_study_date()) on conflict(submission_key) do nothing;
 get diagnostics inserted=row_count;
 if inserted>0 then st:=gk.refresh_question_state(uid,q.question_id); else select * into st from gk.question_state where user_id=uid and question_id=q.question_id; end if;
 return jsonb_build_object('ok',true,'deduped',inserted=0,'attemptId',aid,'isCorrect',ok,'correctOption',upper(coalesce(q.correct_option,'')),'state',to_jsonb(st));
end; $$;

create or replace function public.gk_start_daily(p_count integer default 20)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid(); d date:=gk.current_study_date(); sid text; payload jsonb; title_v text:='Daily Revision';
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select session_id into sid from gk.sessions where user_id=uid and study_date=d and mode='daily' order by created_at limit 1;
 if sid is null then
   sid:='gk-daily-'||d::text||'-'||uid::text;
   payload:=public.gk_get_batch('daily',p_count,'MIXED',null,null,null,null,null,null,null);
   insert into gk.sessions(session_id,user_id,mode,params,current_index,updated_at,completed,title,study_date,position_index,session_version,created_at)
   values(sid,uid,'daily',jsonb_build_object('count',p_count),0,now(),false,title_v,d,0,'gk-v2',now()) on conflict(session_id) do nothing;
   insert into gk.session_questions(session_id,question_id,position)
   select sid,x.value->>'id',(x.ordinality-1)::int from jsonb_array_elements(payload) with ordinality x(value,ordinality)
   on conflict do nothing;
 end if;
 select coalesce(jsonb_agg(gk.question_payload(uid,sq.question_id) order by sq.position),'[]'::jsonb) into payload from gk.session_questions sq where sq.session_id=sid;
 return jsonb_build_object('ok',true,'sessionId',sid,'studyDate',d,'title',title_v,'mode','daily','questions',payload,
  'position',(select coalesce(position_index,current_index,0) from gk.sessions where session_id=sid and user_id=uid),
  'answers',(select coalesce(answers,'{}'::jsonb) from gk.sessions where session_id=sid and user_id=uid),
  'optionOrders',(select coalesce(option_orders,'{}'::jsonb) from gk.sessions where session_id=sid and user_id=uid));
end; $$;

create or replace function public.gk_save_session(p_session_id text,p_title text,p_mode text,p_position integer,p_answers jsonb,p_option_orders jsonb,p_question_ids jsonb,p_completed boolean default false,p_params jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid(); sid text:=nullif(btrim(p_session_id),'');
begin
 if uid is null then raise exception 'Authentication required'; end if; if sid is null then raise exception 'Session id required'; end if;
 insert into gk.sessions(session_id,user_id,mode,params,current_index,updated_at,completed,title,study_date,position_index,option_orders,answers,paused_at,session_version,created_at)
 values(sid,uid,coalesce(p_mode,'practice'),coalesce(p_params,'{}'::jsonb),greatest(coalesce(p_position,0),0),now(),coalesce(p_completed,false),p_title,gk.current_study_date(),greatest(coalesce(p_position,0),0),coalesce(p_option_orders,'{}'::jsonb),coalesce(p_answers,'{}'::jsonb),case when p_completed then null else now() end,'gk-v2',now())
 on conflict(session_id) do update set mode=excluded.mode,params=excluded.params,current_index=excluded.current_index,updated_at=now(),completed=excluded.completed,title=excluded.title,position_index=excluded.position_index,option_orders=excluded.option_orders,answers=excluded.answers,paused_at=excluded.paused_at
 where gk.sessions.user_id=uid;
 insert into gk.session_questions(session_id,question_id,position)
 select sid,x.value,(x.ordinality-1)::int from jsonb_array_elements_text(coalesce(p_question_ids,'[]'::jsonb)) with ordinality x(value,ordinality)
 on conflict do nothing;
 return jsonb_build_object('ok',true,'sessionId',sid,'completed',coalesce(p_completed,false));
end; $$;

create or replace function public.gk_get_resume_session()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,gk,auth as $$
with s as(select * from gk.sessions where user_id=auth.uid() and not completed order by updated_at desc nulls last,created_at desc limit 1)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') when not exists(select 1 from s) then jsonb_build_object('ok',true,'session',null) else jsonb_build_object('ok',true,'session',(
 select jsonb_build_object('sessionId',s.session_id,'title',s.title,'mode',s.mode,'position',coalesce(s.position_index,s.current_index,0),'answers',coalesce(s.answers,'{}'::jsonb),'optionOrders',coalesce(s.option_orders,'{}'::jsonb),'params',coalesce(s.params,'{}'::jsonb),'questions',
   (select coalesce(jsonb_agg(gk.question_payload(auth.uid(),sq.question_id) order by sq.position),'[]'::jsonb) from gk.session_questions sq where sq.session_id=s.session_id)) from s
 )) end; $$;

create or replace function public.gk_set_starred(p_question_id text,p_starred boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid();
begin if uid is null then raise exception 'Authentication required'; end if;
 insert into gk.question_state(user_id,question_id,marked_review,starred_at,learning_status) values(uid,p_question_id,p_starred,case when p_starred then now() else null end,'New')
 on conflict(user_id,question_id) do update set marked_review=excluded.marked_review,starred_at=case when p_starred then coalesce(gk.question_state.starred_at,now()) else null end;
 return jsonb_build_object('ok',true,'starred',p_starred); end; $$;

create or replace function public.gk_set_difficult(p_question_id text,p_difficult boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid();
begin if uid is null then raise exception 'Authentication required'; end if;
 insert into gk.question_state(user_id,question_id,difficult,learning_status) values(uid,p_question_id,p_difficult,'New')
 on conflict(user_id,question_id) do update set difficult=excluded.difficult;
 return jsonb_build_object('ok',true,'difficult',p_difficult); end; $$;

create or replace function public.gk_set_flag(p_question_id text,p_active boolean,p_reason text default '',p_note text default '')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid(); fid text;
begin if uid is null then raise exception 'Authentication required'; end if;
 insert into gk.question_state(user_id,question_id,flag_active,flag_reason,flag_note,flag_updated_at,learning_status) values(uid,p_question_id,p_active,p_reason,p_note,now(),'New')
 on conflict(user_id,question_id) do update set flag_active=excluded.flag_active,flag_reason=excluded.flag_reason,flag_note=excluded.flag_note,flag_updated_at=now();
 if p_active then fid:='gk-flag-'||uid::text||'-'||p_question_id; insert into gk.flags(flag_id,user_id,question_id,reason,note,created_at,resolved,updated_at) values(fid,uid,p_question_id,p_reason,p_note,now(),false,now()) on conflict(flag_id) do update set reason=excluded.reason,note=excluded.note,resolved=false,resolved_at=null,updated_at=now();
 else update gk.flags set resolved=true,resolved_at=now(),updated_at=now() where user_id=uid and question_id=p_question_id and not resolved; end if;
 return jsonb_build_object('ok',true,'flagged',p_active); end; $$;

create or replace function public.gk_save_note(p_question_id text,p_note text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,gk,auth as $$
declare uid uuid:=auth.uid();
begin if uid is null then raise exception 'Authentication required'; end if;
 insert into gk.user_notes(user_id,question_id,note,updated_at) values(uid,p_question_id,p_note,now()) on conflict(user_id,question_id) do update set note=excluded.note,updated_at=now();
 return jsonb_build_object('ok',true); end; $$;

grant execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) to authenticated;
grant execute on function public.gk_get_lane_batch(text,text,integer) to authenticated;
grant execute on function public.gk_get_lecture_batch(text,text,text,integer) to authenticated;
grant execute on function public.gk_get_subject_batch(text,text,text,text,integer) to authenticated;
grant execute on function public.gk_get_smart_revision(text,integer) to authenticated;
grant execute on function public.gk_get_catalog() to authenticated;
grant execute on function public.gk_get_home_snapshot() to authenticated;
grant execute on function public.gk_get_progress() to authenticated;
grant execute on function public.gk_get_question_intelligence(text,text) to authenticated;
grant execute on function public.gk_record_exposure(text,text,text,text) to authenticated;
grant execute on function public.gk_mark_guessed(text,text,boolean,text) to authenticated;
grant execute on function public.gk_submit_answer(text,text,boolean,text,text,text,integer) to authenticated;
grant execute on function public.gk_start_daily(integer) to authenticated;
grant execute on function public.gk_save_session(text,text,text,integer,jsonb,jsonb,jsonb,boolean,jsonb) to authenticated;
grant execute on function public.gk_get_resume_session() to authenticated;
grant execute on function public.gk_set_starred(text,boolean) to authenticated;
grant execute on function public.gk_set_difficult(text,boolean) to authenticated;
grant execute on function public.gk_set_flag(text,boolean,text,text) to authenticated;
grant execute on function public.gk_save_note(text,text) to authenticated;

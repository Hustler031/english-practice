-- GK V2 final implementation audit fixes.
-- Forward-only/read-model hardening. No historical Attempts, Exposures, Sessions,
-- question_state, teacher content, or canonical Question_IDs are rewritten.
--
-- Fixes:
-- 1) Any real historical answer attempt proves the question has been seen even when
--    a legacy migration lacks a matching explicit exposure row.
-- 2) New Practice derives "unseen" from the authoritative learning profile.
-- 3) Legacy progress drill-down canonicalises subject aliases exactly like the
--    modern intelligence dashboard.

begin;

create or replace function gk.learning_profiles_v2(p_user_id uuid)
returns table(
  question_id text,
  attempts integer,
  correct integer,
  wrong integer,
  accuracy numeric,
  first_attempt_correct boolean,
  retention_attempts integer,
  retention_correct integer,
  retention_wrong integer,
  retention_accuracy numeric,
  recent_spaced_failures integer,
  last_attempt timestamptz,
  last_spaced_attempt timestamptz,
  last_meaningful_result text,
  latest_result text,
  learning_state text,
  next_review timestamptz,
  due boolean,
  guessed_attempts integer,
  repeatedly_guessed boolean,
  unconfirmed_guess boolean,
  last_guess_at timestamptz,
  confirmed_unguessed_spaced_recalls integer,
  exposure_count integer,
  first_seen timestamptz,
  last_seen timestamptz
)
language sql
stable security definer
set search_path=pg_catalog,gk,auth
as $$
with ordered as (
  select a.*,
    lag(a.attempted_at) over(partition by a.question_id order by a.attempted_at,a.attempt_id) prev_attempted_at,
    lag(a.session_id) over(partition by a.question_id order by a.attempted_at,a.attempt_id) prev_session_id
  from gk.attempts a
  where a.user_id=p_user_id and a.is_correct is not null
), marked as (
  select o.*,
    (o.prev_attempted_at is not null
      and extract(epoch from(o.attempted_at-o.prev_attempted_at))/3600.0 >= 18
      and not (o.session_id is not null and o.prev_session_id is not null and o.session_id=o.prev_session_id)) spaced
  from ordered o
), spaced_ranked as (
  select m.*,row_number() over(partition by m.question_id order by m.attempted_at desc,m.attempt_id desc) spaced_desc
  from marked m where m.spaced
), agg as (
  select m.question_id,
    count(*)::int attempts,
    count(*) filter(where m.is_correct)::int correct,
    count(*) filter(where not m.is_correct)::int wrong,
    round(count(*) filter(where m.is_correct)*100.0/nullif(count(*),0),1) accuracy,
    (array_agg(m.is_correct order by m.attempted_at,m.attempt_id))[1] first_attempt_correct,
    min(m.attempted_at) first_attempt,
    count(*) filter(where m.spaced)::int retention_attempts,
    count(*) filter(where m.spaced and m.is_correct)::int retention_correct,
    count(*) filter(where m.spaced and not m.is_correct)::int retention_wrong,
    round(count(*) filter(where m.spaced and m.is_correct)*100.0/nullif(count(*) filter(where m.spaced),0),1) retention_accuracy,
    max(m.attempted_at) last_attempt,
    max(m.attempted_at) filter(where m.spaced) last_spaced_attempt,
    (array_agg(m.is_correct order by m.attempted_at desc,m.attempt_id desc))[1] latest_correct,
    (array_agg(m.is_correct order by m.attempted_at desc,m.attempt_id desc) filter(where m.spaced))[1] last_spaced_correct,
    (array_agg(coalesce(m.guessed,false) order by m.attempted_at desc,m.attempt_id desc) filter(where m.spaced))[1] last_spaced_guessed,
    count(*) filter(where coalesce(m.guessed,false))::int guessed_attempts,
    max(m.attempted_at) filter(where coalesce(m.guessed,false)) last_guess_at,
    count(*) filter(where m.spaced and m.is_correct and not coalesce(m.guessed,false))::int confirmed_unguessed_spaced_recalls,
    max(m.attempted_at) filter(where m.spaced and m.is_correct and not coalesce(m.guessed,false)) last_confirming_at
  from marked m group by m.question_id
), recent as (
  select question_id,count(*) filter(where not is_correct)::int recent_spaced_failures
  from spaced_ranked where spaced_desc<=3 group by question_id
), exposure as (
  select question_id,count(*)::int exposure_count,min(exposed_at) first_seen,max(exposed_at) last_seen
  from gk.exposures where user_id=p_user_id group by question_id
), raw as (
  select q.question_id,
    coalesce(a.attempts,0)::int attempts,coalesce(a.correct,0)::int correct,coalesce(a.wrong,0)::int wrong,
    coalesce(a.accuracy,0)::numeric accuracy,a.first_attempt_correct,
    coalesce(a.retention_attempts,0)::int retention_attempts,
    coalesce(a.retention_correct,0)::int retention_correct,
    coalesce(a.retention_wrong,0)::int retention_wrong,
    coalesce(a.retention_accuracy,0)::numeric retention_accuracy,
    coalesce(r.recent_spaced_failures,0)::int recent_spaced_failures,
    a.last_attempt,a.last_spaced_attempt,
    case when coalesce(a.retention_attempts,0)>0 then case when a.last_spaced_correct then 'Correct' else 'Wrong' end
      when a.attempts is not null then case when a.latest_correct then 'Correct' else 'Wrong' end else '' end last_meaningful_result,
    case when a.attempts is not null then case when a.latest_correct then 'Correct' else 'Wrong' end else '' end latest_result,
    coalesce(a.guessed_attempts,0)::int guessed_attempts,
    coalesce(a.guessed_attempts,0)>=2 repeatedly_guessed,
    (a.last_guess_at is not null and (a.last_confirming_at is null or a.last_confirming_at<=a.last_guess_at)) unconfirmed_guess,
    a.last_guess_at,coalesce(a.confirmed_unguessed_spaced_recalls,0)::int confirmed_unguessed_spaced_recalls,
    a.last_spaced_correct,a.last_spaced_guessed,
    greatest(coalesce(e.exposure_count,0),case when coalesce(a.attempts,0)>0 then 1 else 0 end)::int exposure_count,
    case
      when e.first_seen is null then a.first_attempt
      when a.first_attempt is null then e.first_seen
      else least(e.first_seen,a.first_attempt)
    end first_seen,
    case
      when e.last_seen is null then a.last_attempt
      when a.last_attempt is null then e.last_seen
      else greatest(e.last_seen,a.last_attempt)
    end last_seen
  from gk.questions q
  left join agg a on a.question_id=q.question_id
  left join recent r on r.question_id=q.question_id
  left join exposure e on e.question_id=q.question_id
  where q.active
), stated as (
  select r.*,
    case
      when r.attempts=0 then 'New'
      when r.recent_spaced_failures>=2 or (r.retention_wrong>=2 and r.retention_accuracy<60) then 'Persistent Weak'
      when (r.retention_wrong>=1 and coalesce(r.last_spaced_correct,false)=false)
        or (r.wrong>=2 and r.retention_correct=0) then 'Weak'
      when r.unconfirmed_guess or r.retention_attempts<2 then 'Fragile'
      when r.retention_correct>=3 and r.retention_accuracy>=85
        and r.last_spaced_correct is true and not coalesce(r.last_spaced_guessed,false)
        and r.recent_spaced_failures=0 and not r.unconfirmed_guess
        and r.confirmed_unguessed_spaced_recalls>=2 then 'Proven Mastered'
      when r.retention_correct>=2 and r.retention_accuracy>=75
        and r.last_spaced_correct is true and not r.unconfirmed_guess then 'Strong'
      when r.wrong>0 or r.retention_accuracy<70 then 'Weak'
      else 'Learning'
    end learning_state
  from raw r
), scheduled as (
  select s.*,
    case when s.last_attempt is null then null::timestamptz else
      (((coalesce(s.last_spaced_attempt,s.last_attempt) at time zone 'Asia/Kolkata')::date
        + case s.learning_state
            when 'Persistent Weak' then 1 when 'Weak' then 1 when 'Fragile' then 2
            when 'Learning' then 3 when 'Strong' then 7 when 'Proven Mastered' then 21 else 2 end
      )::timestamp at time zone 'Asia/Kolkata') end next_review
  from stated s
)
select s.question_id,s.attempts,s.correct,s.wrong,s.accuracy,s.first_attempt_correct,
  s.retention_attempts,s.retention_correct,s.retention_wrong,s.retention_accuracy,
  s.recent_spaced_failures,s.last_attempt,s.last_spaced_attempt,s.last_meaningful_result,s.latest_result,
  s.learning_state,s.next_review,coalesce(s.next_review<=now(),false) due,
  s.guessed_attempts,s.repeatedly_guessed,s.unconfirmed_guess,s.last_guess_at,
  s.confirmed_unguessed_spaced_recalls,s.exposure_count,s.first_seen,s.last_seen
from scheduled s
$$;
revoke execute on function gk.learning_profiles_v2(uuid) from public,anon,authenticated,service_role;

create or replace function public.gk_get_new_practice_hub()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
profile as(select * from gk.learning_profiles_v2((select uid from u))),
base as (
  select q.question_id,q.subject,q.topic,q.lecture_key,q.lecture_no,q.source_label,q.source_date,q.content_lane,
    gk.derive_library_key(q.question_id,q.source_label,q.subject) library_key,
    coalesce(p.exposure_count,0)=0 unseen
  from gk.questions q
  join profile p on p.question_id=q.question_id
  where q.active
), totals as (
  select count(*)::int total,count(*) filter(where unseen)::int unseen from base
), topic_rows as (
  select coalesce(gk.canonical_subject(subject),'Unclassified') subject,
    coalesce(nullif(btrim(topic),''),'General') topic,
    count(*) filter(where unseen)::int unseen
  from base group by 1,2
), subject_rows as (
  select subject,sum(unseen)::int unseen,
    jsonb_agg(jsonb_build_object('topic',topic,'unseen',unseen) order by unseen desc,topic)
      filter(where unseen>0) topics
  from topic_rows group by subject
), lecture_rows as (
  select library_key,lecture_key,lecture_no,max(coalesce(nullif(source_label,''),'Lecture')) title,
    count(*) filter(where unseen)::int unseen_total,
    count(*) filter(where unseen and upper(content_lane)='MAIN')::int unseen_main,
    count(*) filter(where unseen and upper(content_lane) in ('RAPID','RAPID_RECALL'))::int unseen_rapid
  from base where lecture_key is not null group by library_key,lecture_key,lecture_no
), library_rows as (
  select x.key library_key,x.title,
    coalesce(sum(l.unseen_total),0)::int unseen,
    coalesce(jsonb_agg(jsonb_build_object(
      'lectureKey',l.lecture_key,'lectureNo',l.lecture_no,'title',l.title,
      'unseenTotal',l.unseen_total,'unseenMain',l.unseen_main,'unseenRapid',l.unseen_rapid
    ) order by l.lecture_no,l.lecture_key) filter(where l.lecture_key is not null),'[]'::jsonb) lectures
  from (values('subject-pyq','Subject-wise PYQ'),('mixed','Mixed PYQ'),('nitto','Nitto Series'),('misc','MISC')) x(key,title)
  left join lecture_rows l on l.library_key=x.key
  group by x.key,x.title
), ca as (
  select
    count(*) filter(where unseen and subject='Current Affairs')::int all_n,
    count(*) filter(where unseen and subject='Current Affairs' and source_date>=current_date-interval '1 month')::int m1,
    count(*) filter(where unseen and subject='Current Affairs' and source_date>=current_date-interval '3 months')::int m3,
    count(*) filter(where unseen and subject='Current Affairs' and source_date>=current_date-interval '6 months')::int m6
  from base
), ca_categories as (
  select coalesce(nullif(btrim(topic),''),'General') category,
    count(*) filter(where unseen)::int all_n,
    count(*) filter(where unseen and source_date>=current_date-interval '1 month')::int m1,
    count(*) filter(where unseen and source_date>=current_date-interval '3 months')::int m3,
    count(*) filter(where unseen and source_date>=current_date-interval '6 months')::int m6
  from base where subject='Current Affairs' group by 1
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else
 jsonb_build_object(
  'ok',true,
  'summary',jsonb_build_object(
    'unseen',(select unseen from totals),
    'totalActive',(select total from totals),
    'bankExposedPct',case when (select total from totals)>0 then round(((select total-unseen from totals)*100.0/(select total from totals)),1) else 0 end
  ),
  'subjects',coalesce((select jsonb_agg(jsonb_build_object('subject',subject,'unseen',unseen,'topics',coalesce(topics,'[]'::jsonb)) order by unseen desc,subject) from subject_rows where unseen>0),'[]'::jsonb),
  'libraries',coalesce((select jsonb_agg(jsonb_build_object('libraryKey',library_key,'title',title,'unseen',unseen,'lectures',lectures) order by case library_key when 'subject-pyq' then 1 when 'mixed' then 2 when 'nitto' then 3 else 4 end) from library_rows),'[]'::jsonb),
  'currentAffairs',jsonb_build_object(
    'all',(select all_n from ca),'m1',(select m1 from ca),'m3',(select m3 from ca),'m6',(select m6 from ca),
    'categories',coalesce((select jsonb_agg(jsonb_build_object('category',category,'all',all_n,'m1',m1,'m3',m3,'m6',m6) order by all_n desc,category) from ca_categories),'[]'::jsonb)
  )
 ) end;
$$;

create or replace function public.gk_get_progress()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), p as(select * from gk.learning_profiles_v2((select uid from u))),
base as (
 select q.question_id,gk.canonical_subject(q.subject) subject,q.topic,q.concept_id,q.lecture_key,q.source_label,q.source_date,
   p.learning_state st,p.retention_attempts ret_attempts,p.retention_correct ret_correct,
   coalesce(s.marked_review,false) starred,coalesce(s.difficult,false) difficult,
   p.guessed_attempts,p.unconfirmed_guess guessed,p.next_review,p.exposure_count>0 exposed,
   p.first_attempt_correct first_ok
 from gk.questions q join p on p.question_id=q.question_id
 left join gk.question_state s on s.user_id=(select uid from u) and s.question_id=q.question_id
 where q.active
), subject_rows as (
 select coalesce(subject,'Unclassified') subject,count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base group by 1
), concepts as (
 select coalesce(subject,'Unclassified')||'|'||coalesce(topic,'General')||'|'||coalesce(nullif(concept_id,''),'') "conceptId",
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*)::int total,count(*) filter(where exposed)::int attempted,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st in ('Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,count(*) filter(where guessed)::int guessed,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base group by coalesce(subject,'Unclassified'),coalesce(topic,'General'),coalesce(nullif(concept_id,''),'')
), lectures as (
 select lecture_key,max(source_label) title,count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered
 from base where lecture_key is not null group by lecture_key
), ca as (
 select case when source_date>=current_date-interval '1 month' then '1 Month'
   when source_date>=current_date-interval '3 months' then '3 Months'
   when source_date>=current_date-interval '6 months' then '6 Months' else 'Older' end band,
   count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where guessed)::int guessed
 from base where subject='Current Affairs' group by 1
), top as (
 select count(*)::int total,count(*) filter(where exposed)::int exposed,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st='Weak')::int weak,count(*) filter(where st='Fragile')::int fragile,
   count(*) filter(where st='Strong')::int strong,count(*) filter(where st='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,count(*) filter(where starred)::int starred,
   count(*) filter(where difficult)::int difficult,count(*) filter(where guessed)::int guessed,
   coalesce(round(count(*) filter(where first_ok is true)*100.0/
     nullif(count(*) filter(where first_ok is not null),0),1),0) "firstAccuracy",
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base
), concept_top as (
 select count(*) filter(where "persistentWeak">0)::int "persistentWeakConcepts",
   count(*) filter(where weak>0 or "persistentWeak">0)::int "weakConcepts" from concepts
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object(
 'ok',true,'overview',(select to_jsonb(top)||to_jsonb(concept_top) from top cross join concept_top),
 'knowledgeHealth',(select jsonb_build_array(
   jsonb_build_object('state','Persistent Weak','count',"persistentWeak"),
   jsonb_build_object('state','Weak','count',weak),jsonb_build_object('state','Fragile','count',fragile),
   jsonb_build_object('state','Strong','count',strong),jsonb_build_object('state','Proven Mastered','count',mastered)
 ) from top),
 'subjectMastery',(select coalesce(jsonb_agg(to_jsonb(subject_rows) order by total desc,subject),'[]'::jsonb) from subject_rows),
 'weakConcepts',(select coalesce(jsonb_agg(to_jsonb(c) order by "persistentWeak" desc,weak desc,total desc),'[]'::jsonb)
   from (select * from concepts where "persistentWeak"+weak>0 limit 50) c),
 'currentAffairsHealth',(select coalesce(jsonb_agg(to_jsonb(ca)
   order by case band when '1 Month' then 1 when '3 Months' then 2 when '6 Months' then 3 else 4 end),'[]'::jsonb) from ca),
 'starredHealth',(select jsonb_build_object(
   'total',starred,'focus',(select count(*) from base where starred and
     (st in ('Persistent Weak','Weak','Fragile') or next_review<=now() or guessed)),
   'due',(select count(*) from base where starred and next_review<=now()),
   'difficult',(select count(*) from base where starred and difficult),
   'mastered',(select count(*) from base where starred and st='Proven Mastered')) from top),
 'guessedHealth',(select jsonb_build_object(
   'historicallyGuessed',(select count(*) from base where guessed_attempts>0),'unresolved',guessed,
   'repeated',(select count(*) from base where guessed and guessed_attempts>=2),
   'due',(select count(*) from base where guessed and next_review<=now())) from top),
 'difficultResolution',(select jsonb_build_object(
   'total',difficult,'resolvedStrong',(select count(*) from base where difficult and st in ('Strong','Proven Mastered')),
   'needsFocus',(select count(*) from base where difficult and
     (st in ('Persistent Weak','Weak','Fragile') or next_review<=now()))) from top),
 'lectureCoverage',(select coalesce(jsonb_agg(jsonb_build_object(
   'lecture_key',lecture_key,'title',title,'total',total,'exposed',exposed,'weak',weak,'mastered',mastered
 ) order by case when total>0 then exposed::numeric/total else 0 end asc,title),'[]'::jsonb) from lectures)
) end
$$;

revoke execute on function public.gk_get_new_practice_hub() from public,anon;
grant execute on function public.gk_get_new_practice_hub() to authenticated;
revoke execute on function public.gk_get_progress() from public,anon;
grant execute on function public.gk_get_progress() to authenticated;

commit;

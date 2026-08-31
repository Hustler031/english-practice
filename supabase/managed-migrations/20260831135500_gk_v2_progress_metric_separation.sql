-- Keep Teacher Content Completion and Question Bank Exposure as distinct truths.
-- Teacher completion is the exposure rate across canonical questions that belong
-- to active teacher-owned Topic/Mixed/Current-Affairs series. Bank exposure is
-- the exposure rate across the entire active canonical GK bank.

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
        p.learning_state st,p.retention_attempts,p.retention_correct,p.exposure_count,p.unconfirmed_guess,p.due,
        p.next_review,p.last_attempt,p.first_attempt_correct,
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
), subject_rows as(
 select subject,count(*)::int total,count(*) filter(where exposure_count>0)::int seen,
  count(*) filter(where exposure_count=0)::int unseen,
  count(*) filter(where st='Persistent Weak')::int "persistentWeak",
  count(*) filter(where st='Weak')::int weak,count(*) filter(where st='Fragile')::int fragile,
  count(*) filter(where st='Proven Mastered')::int mastered,
  count(*) filter(where unconfirmed_guess)::int guessed,
  count(*) filter(where teacher_pyq and exposure_count=0)::int "unseenHighYield",
  coalesce(round(sum(retention_correct)*100.0/nullif(sum(retention_attempts),0),1),0) retention,
  coalesce(round(count(*) filter(where exposure_count>0)*100.0/nullif(count(*),0),1),0) coverage,
  (count(*) filter(where st='Persistent Weak')*5 + count(*) filter(where st='Weak')*3 + count(*) filter(where st='Fragile')*2 + count(*) filter(where unconfirmed_guess)*2)::int attention_score
 from base group by subject
), series_rows as(
 select cs.series_id "seriesId",cs.series_kind "seriesKind",cs.title,
  count(distinct m.question_id)::int total,
  count(distinct m.question_id) filter(where p.exposure_count>0)::int exposed,
  count(distinct m.question_id) filter(where p.learning_state in('Persistent Weak','Weak','Fragile'))::int weak,
  count(distinct m.question_id) filter(where p.learning_state='Proven Mastered')::int mastered,
  coalesce(round(count(distinct m.question_id) filter(where p.exposure_count>0)*100.0/nullif(count(distinct m.question_id),0),1),0) completion,
  coalesce(round(sum(p.retention_correct)*100.0/nullif(sum(p.retention_attempts),0),1),0) retention
 from gk.content_series cs join gk.question_source_memberships m on m.series_id=cs.series_id
 join p on p.question_id=m.question_id
 where cs.active and cs.series_kind in('TOPIC_PYQ','MIXED_PYQ','CURRENT_AFFAIRS')
 group by cs.series_id,cs.series_kind,cs.title
), teacher_top as(
 select count(distinct m.question_id)::int total,
        count(distinct m.question_id) filter(where p.exposure_count>0)::int exposed
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
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'overview',(select jsonb_build_object(
   'readiness',readiness,'retention',retention,'bankExposure',exposure_pct,'provenKnowledge',proven_pct,
   'weakBurden',weak_burden,'persistentWeak',persistent_weak,'unresolvedGuesses',unresolved_guesses,'due',due,
   'teacherContentCompletion',teacher_completion,'questionBankExposure',exposure_pct,'knowledgeRetention',retention
 ) from score),
 'needsAttention',(select coalesce(jsonb_agg(to_jsonb(x) order by x.attention_score desc,x.subject),'[]'::jsonb) from (select * from subject_rows order by attention_score desc,subject limit 4)x),
 'strongest',(select coalesce(jsonb_agg(to_jsonb(x) order by x.retention desc,x.coverage desc),'[]'::jsonb) from (select * from subject_rows where seen>0 order by retention desc,coverage desc limit 3)x),
 'subjects',(select coalesce(jsonb_agg(to_jsonb(x) order by x.attention_score desc,x.subject),'[]'::jsonb) from subject_rows x),
 'seriesProgress',(select coalesce(jsonb_agg(to_jsonb(x) order by case x."seriesKind" when 'TOPIC_PYQ' then 1 when 'MIXED_PYQ' then 2 else 3 end,x.title),'[]'::jsonb) from series_rows x),
 'thisWeek',jsonb_build_object('factsSeen',(select facts_seen from weekly),'weakResolved',(select resolved from weak_resolved),'unresolvedGuesses',(select unresolved_guesses from top))
) end;
$$;

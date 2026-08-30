-- Read-only routing fix for reused GK concept IDs.
-- UI route keys are scoped as Subject|Topic|CanonicalConcept while canonical content/state remains unchanged.

create or replace function public.gk_get_concept_batch(
 p_concept_id text,
 p_lane text default 'MIXED',
 p_mode text default 'all',
 p_count integer default 20
) returns jsonb
language sql
security definer
set search_path=pg_catalog,public,gk,auth
as $$
with input as (
 select
   case when length(coalesce(p_concept_id,''))-length(replace(coalesce(p_concept_id,''),'|',''))>=2 then split_part(p_concept_id,'|',1) end route_subject,
   case when length(coalesce(p_concept_id,''))-length(replace(coalesce(p_concept_id,''),'|',''))>=2 then split_part(p_concept_id,'|',2) end route_topic,
   case when length(coalesce(p_concept_id,''))-length(replace(coalesce(p_concept_id,''),'|',''))>=2
      then regexp_replace(p_concept_id,'^[^|]*\|[^|]*\|','') else coalesce(p_concept_id,'') end canonical_concept
), u as(select auth.uid() uid), scopes as (
 select distinct q.subject,q.topic
 from gk.questions q cross join input i
 where q.active and (
   (i.route_subject is not null
    and coalesce(q.subject,'Unclassified')=i.route_subject
    and coalesce(q.topic,'General')=i.route_topic
    and coalesce(q.concept_id,'')=i.canonical_concept)
   or
   (i.route_subject is null and coalesce(q.concept_id,'')=i.canonical_concept)
 )
), expanded as (
 select x.item,x.ord
 from scopes s
 cross join lateral jsonb_array_elements(
   public.gk_get_batch(p_mode,100,p_lane,s.subject,s.topic,null,null,null,null,null)
 ) with ordinality x(item,ord)
), exact as (
 select e.item,min(e.ord)::bigint ord
 from expanded e cross join input i
 where coalesce(e.item->>'concept_id','')=i.canonical_concept
   and (i.route_subject is null or (
      coalesce(e.item->>'subject','Unclassified')=i.route_subject
      and coalesce(e.item->>'topic','General')=i.route_topic
   ))
 group by e.item
 order by min(e.ord),e.item->>'id'
 limit greatest(1,least(100,coalesce(p_count,20)))
)
select case when (select uid from u) is null
 then jsonb_build_object('ok',false,'error','Authentication required')
 else coalesce(jsonb_agg(item order by ord,item->>'id'),'[]'::jsonb) end
from exact
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
 select coalesce(subject,'Unclassified')||'|'||coalesce(topic,'General')||'|'||coalesce(nullif(concept_id,''),'') concept_id,
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*) filter(where st='Persistent Weak')::int persistent_weak,
   count(*) filter(where st in ('Persistent Weak','Weak','Fragile'))::int weak,
   coalesce(round(avg(retention_accuracy) filter(where retention_accuracy>0),1),0) retention_accuracy
 from b
 group by coalesce(subject,'Unclassified'),coalesce(topic,'General'),coalesce(nullif(concept_id,''),'')
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
 select coalesce(subject,'Unclassified')||'|'||coalesce(topic,'General')||'|'||coalesce(nullif(concept_id,''),'') "conceptId",
   coalesce(subject,'Unclassified') subject,coalesce(topic,'General') topic,
   count(*)::int total,count(*) filter(where exposed)::int attempted,
   count(*) filter(where st='Persistent Weak')::int "persistentWeak",
   count(*) filter(where st in ('Weak','Fragile'))::int weak,
   count(*) filter(where st='Proven Mastered')::int mastered,
   count(*) filter(where guessed)::int guessed,
   coalesce(round(sum(ret_correct)*100.0/nullif(sum(ret_attempts),0),1),0) "retentionAccuracy"
 from base
 group by coalesce(subject,'Unclassified'),coalesce(topic,'General'),coalesce(nullif(concept_id,''),'')
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

revoke execute on function public.gk_get_concept_batch(text,text,text,integer) from public,anon;
revoke execute on function public.gk_get_on_demand_hub() from public,anon;
revoke execute on function public.gk_get_progress() from public,anon;
grant execute on function public.gk_get_concept_batch(text,text,text,integer) to authenticated;
grant execute on function public.gk_get_on_demand_hub() to authenticated;
grant execute on function public.gk_get_progress() to authenticated;

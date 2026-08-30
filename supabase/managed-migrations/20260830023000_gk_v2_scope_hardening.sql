-- GK V2 security/scope hardening.
-- Keep the old unlabeled legacy batch in MISC until canonical source metadata exists;
-- do not guess a Mixed/Subject-wise identity from academic subjects alone.

-- Direct table access remains unnecessary for the web client, but explicit RLS
-- policies make the ownership contract safe if table grants are ever expanded.
drop policy if exists gk_demand_sets_read on gk.demand_sets;
drop policy if exists gk_demand_sets_insert on gk.demand_sets;
drop policy if exists gk_demand_sets_update on gk.demand_sets;
drop policy if exists gk_demand_sets_delete on gk.demand_sets;

create policy gk_demand_sets_read on gk.demand_sets
for select to authenticated
using (user_id is null or user_id = auth.uid());

create policy gk_demand_sets_insert on gk.demand_sets
for insert to authenticated
with check (user_id = auth.uid());

create policy gk_demand_sets_update on gk.demand_sets
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy gk_demand_sets_delete on gk.demand_sets
for delete to authenticated
using (user_id = auth.uid());

-- Catalog must never expose another user's saved/custom Demand Sets. Legacy rows
-- with user_id NULL stay compatible as shared imported sets.
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
 'demandSets',(select coalesce(jsonb_agg(jsonb_build_object('demandId',d.demand_id,'title',coalesce(d.title,d.demand_id),'kind',d.kind,'count',jsonb_array_length(coalesce(d.question_ids,'[]'::jsonb)),'lastUsed',d.last_used) order by coalesce(d.last_used,d.created_at) desc nulls last,d.demand_id),'[]'::jsonb)
   from gk.demand_sets d cross join u where d.active and (d.user_id is null or d.user_id=u.uid))
) end;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC by PostgreSQL default. Keep every new
-- GK V2 security-definer endpoint explicitly authenticated-only.
revoke execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) from public, anon;
revoke execute on function public.gk_get_lane_batch(text,text,integer) from public, anon;
revoke execute on function public.gk_get_lecture_batch(text,text,text,integer) from public, anon;
revoke execute on function public.gk_get_subject_batch(text,text,text,text,integer) from public, anon;
revoke execute on function public.gk_get_smart_revision(text,integer) from public, anon;
revoke execute on function public.gk_get_catalog() from public, anon;
revoke execute on function public.gk_get_home_snapshot() from public, anon;
revoke execute on function public.gk_get_progress() from public, anon;
revoke execute on function public.gk_get_question_intelligence(text,text) from public, anon;
revoke execute on function public.gk_record_exposure(text,text,text,text) from public, anon;
revoke execute on function public.gk_mark_guessed(text,text,boolean,text) from public, anon;
revoke execute on function public.gk_submit_answer(text,text,boolean,text,text,text,integer) from public, anon;
revoke execute on function public.gk_start_daily(integer) from public, anon;
revoke execute on function public.gk_save_session(text,text,text,integer,jsonb,jsonb,jsonb,boolean,jsonb) from public, anon;
revoke execute on function public.gk_get_resume_session() from public, anon;
revoke execute on function public.gk_set_starred(text,boolean) from public, anon;
revoke execute on function public.gk_set_difficult(text,boolean) from public, anon;
revoke execute on function public.gk_set_flag(text,boolean,text,text) from public, anon;
revoke execute on function public.gk_save_note(text,text) from public, anon;
revoke execute on function public.gk_get_starred_hub() from public, anon;
revoke execute on function public.gk_get_on_demand_hub() from public, anon;
revoke execute on function public.gk_create_demand_set(text,integer,text) from public, anon;

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
grant execute on function public.gk_get_starred_hub() to authenticated;
grant execute on function public.gk_get_on_demand_hub() to authenticated;
grant execute on function public.gk_create_demand_set(text,integer,text) to authenticated;

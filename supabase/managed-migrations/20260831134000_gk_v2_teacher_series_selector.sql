-- First-class Topic-wise / Mixed teacher-series selector over canonical Question_IDs.
-- Source membership is a browse dimension; learning history remains global per canonical question.

begin;

create or replace function public.gk_get_teacher_batch(
 p_series_id text,
 p_lecture_key text default null,
 p_mode text default 'smart',
 p_count integer default 20,
 p_lane text default 'MIXED'
)
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), params as(
 select upper(btrim(coalesce(p_lane,'MIXED'))) lane,lower(btrim(coalesce(p_mode,'smart'))) mode,
        greatest(1,least(1000,coalesce(p_count,20))) n
), profile as(select * from gk.learning_profiles_v2((select uid from u))), member_questions as(
 select distinct m.question_id
 from gk.question_source_memberships m join gk.content_series s on s.series_id=m.series_id
 where s.active and m.series_id=p_series_id and (p_lecture_key is null or m.lecture_key=p_lecture_key)
), base as(
 select q.question_id,p.learning_state,p.due,p.unconfirmed_guess,p.exposure_count,
        coalesce(st.difficult,false) difficult,
        case p.learning_state when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700
             when 'Learning' then 500 when 'New' then 300 when 'Strong' then 180 when 'Proven Mastered' then 20 else 0 end
        +case when p.due then 300 else 0 end+case when p.unconfirmed_guess then 240 else 0 end+case when coalesce(st.difficult,false) then 180 else 0 end priority
 from member_questions m join gk.questions q on q.question_id=m.question_id and q.active
 join profile p on p.question_id=q.question_id
 left join gk.question_state st on st.user_id=(select uid from u) and st.question_id=q.question_id
 cross join params z
 where z.lane in('MIXED','ALL') or upper(q.content_lane)=z.lane
), eligible as(
 select b.* from base b cross join params z where case
  when z.mode in('new','unseen') then b.exposure_count=0
  when z.mode in('weak','weak_practice') then b.learning_state in('Persistent Weak','Weak','Fragile')
  when z.mode='persistent_weak' then b.learning_state='Persistent Weak'
  when z.mode in('due','due_recall') then b.due
  when z.mode='guessed' then b.unconfirmed_guess
  when z.mode='difficult' then b.difficult
  when z.mode='smart' then b.learning_state<>'Proven Mastered' or b.due
  else true end
), ranked as(
 select e.*,row_number() over(order by case when (select mode from params)='random' then random() else 0 end,
   e.priority desc,e.question_id) ord from eligible e
), chosen as(select * from ranked order by ord limit (select n from params))
select case when (select uid from u) is null then jsonb_build_array()
 else coalesce((select jsonb_agg(gk.question_payload_v2_read((select uid from u),c.question_id) order by c.ord) from chosen c),'[]'::jsonb) end;
$$;

revoke all on function public.gk_get_teacher_batch(text,text,text,integer,text) from public,anon;
grant execute on function public.gk_get_teacher_batch(text,text,text,integer,text) to authenticated;

commit;

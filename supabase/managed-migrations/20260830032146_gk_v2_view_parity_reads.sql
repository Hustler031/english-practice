-- GK V2 old-view parity reads.
-- Read-only compatibility for the React migration. No question, attempt, exposure,
-- state, session, demand-set, note, flag, or English row is mutated here.

create or replace function public.gk_get_scope_batch(
  p_mode text default 'all',
  p_count integer default 20,
  p_lane text default 'MIXED',
  p_subject text default null,
  p_topic text default null,
  p_lecture_key text default null,
  p_library_key text default null,
  p_ca_months integer default null,
  p_ca_category text default null
) returns jsonb
language plpgsql
volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  mode_name text:=lower(btrim(coalesce(p_mode,'all')));
  lane_name text:=upper(btrim(coalesce(p_lane,'MIXED')));
  n integer:=greatest(1,least(1000,coalesce(p_count,20)));
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if lane_name not in ('MAIN','RAPID','MIXED','ALL') then raise exception 'Invalid GK question style'; end if;

  with base as (
    select q.question_id,
      coalesce(s.learning_status,'New') learning_state,
      coalesce(s.wrong,0) wrong,
      coalesce(s.next_review<=now(),false) due,
      exists(select 1 from gk.exposures e where e.user_id=uid and e.question_id=q.question_id) exposed,
      s.next_review,
      case coalesce(s.learning_status,'New')
        when 'Persistent Weak' then 1000 when 'Weak' then 850 when 'Fragile' then 700
        when 'Learning' then 500 when 'New' then 300 when 'Strong' then 180
        when 'Proven Mastered' then 20 else 0 end
        +case when coalesce(s.next_review<=now(),false) then 300 else 0 end
        +case when coalesce(s.difficult,false) then 180 else 0 end
        +case when coalesce(s.unconfirmed_guess,false) then 240 else 0 end as priority
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
  ), eligible as (
    select * from base b where
      case
        when mode_name in ('new','unseen','new_v2','new_random') then not b.exposed
        when mode_name in ('weak','weak_practice') then b.learning_state in ('Persistent Weak','Weak','Fragile')
        when mode_name in ('due','due_recall') then b.due
        when mode_name in ('recall','recall_check') then b.exposed and b.learning_state<>'Proven Mastered'
        else true
      end
  ), ranked as (
    select e.*,
      row_number() over(order by
        case when mode_name in ('random','new_random') then random() else 0 end,
        case when mode_name in ('random','new_random') then 0 else e.priority end desc,
        e.wrong desc,e.next_review nulls last,e.question_id
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

create or replace function public.gk_get_lecture_part_batch(
  p_lecture_key text,
  p_lane text default 'MAIN',
  p_part integer default 1,
  p_part_size integer default 20
) returns jsonb
language plpgsql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare
  uid uuid:=auth.uid();
  lane_name text:=upper(btrim(coalesce(p_lane,'MAIN')));
  part_no integer:=greatest(1,coalesce(p_part,1));
  part_size integer:=greatest(1,least(100,coalesce(p_part_size,20)));
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if lane_name not in ('MAIN','RAPID') then raise exception 'Lecture part requires MAIN or RAPID'; end if;
  with ranked as (
    select q.question_id,
      row_number() over(order by
        regexp_replace(q.question_id,'[0-9]','','g'),
        nullif(regexp_replace(q.question_id,'[^0-9]','','g'),'')::numeric nulls first,
        q.question_id
      ) ord
    from gk.questions q
    where q.active and q.lecture_key=p_lecture_key and upper(q.content_lane)=lane_name
  ), chosen as (
    select * from ranked
    where ord>((part_no-1)*part_size) and ord<=(part_no*part_size)
    order by ord
  )
  select coalesce(jsonb_agg(gk.question_payload_v2_read(uid,c.question_id) order by c.ord),'[]'::jsonb)
    into out from chosen c;
  return out;
end
$$;

create or replace function public.gk_get_new_practice_hub()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid),
base as (
  select q.question_id,q.subject,q.topic,q.lecture_key,q.lecture_no,q.source_label,q.source_date,q.content_lane,
    gk.derive_library_key(q.question_id,q.source_label,q.subject) library_key,
    not exists(select 1 from gk.exposures e where e.user_id=u.uid and e.question_id=q.question_id) unseen
  from gk.questions q cross join u where q.active
), totals as (
  select count(*)::int total,count(*) filter(where unseen)::int unseen from base
), topic_rows as (
  select coalesce(nullif(btrim(subject),''),'Unclassified') subject,
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
    count(*) filter(where unseen and upper(content_lane)='RAPID')::int unseen_rapid
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

create or replace function public.gk_get_guessed_hub()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), rows as (
  select q.question_id,q.question,q.subject,q.topic,
    coalesce(s.learning_status,'New') learning_state,
    coalesce(s.guessed_attempts,0) guessed_attempts,
    coalesce(s.next_review<=now(),false) due,
    coalesce(s.confirmed_unguessed_spaced_recalls,0) confirmed_recalls
  from gk.question_state s cross join u join gk.questions q on q.question_id=s.question_id and q.active
  where s.user_id=u.uid and coalesce(s.unconfirmed_guess,false)
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'summary',jsonb_build_object(
   'unresolved',(select count(*) from rows),
   'repeated',(select count(*) from rows where guessed_attempts>=2),
   'weak',(select count(*) from rows where learning_state in ('Persistent Weak','Weak','Fragile')),
   'due',(select count(*) from rows where due)
 ),
 'rows',coalesce((select jsonb_agg(jsonb_build_object(
   'id',question_id,'question',question,'subject',coalesce(subject,'Unclassified'),'topic',coalesce(topic,'General'),
   'learningState',learning_state,'guessedAttempts',guessed_attempts,'repeatedlyGuessed',guessed_attempts>=2,
   'due',due,'confirmedUnguessedSpacedRecalls',confirmed_recalls
 ) order by guessed_attempts desc,due desc,question_id) from rows),'[]'::jsonb)
) end;
$$;

create or replace function public.gk_get_flagged_content()
returns jsonb
language sql
stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else
 coalesce(jsonb_agg(jsonb_build_object(
   'id',q.question_id,'question',q.question,'subject',coalesce(q.subject,'Unclassified'),'topic',coalesce(q.topic,'General'),
   'reason',coalesce(s.flag_reason,''),'note',coalesce(s.flag_note,'')
 ) order by s.flag_updated_at desc nulls last,q.question_id),'[]'::jsonb) end
from u
left join gk.question_state s on s.user_id=u.uid and coalesce(s.flag_active,false)
left join gk.questions q on q.question_id=s.question_id and q.active
where q.question_id is not null;
$$;

revoke execute on function public.gk_get_scope_batch(text,integer,text,text,text,text,text,integer,text) from public,anon;
revoke execute on function public.gk_get_lecture_part_batch(text,text,integer,integer) from public,anon;
revoke execute on function public.gk_get_new_practice_hub() from public,anon;
revoke execute on function public.gk_get_guessed_hub() from public,anon;
revoke execute on function public.gk_get_flagged_content() from public,anon;
grant execute on function public.gk_get_scope_batch(text,integer,text,text,text,text,text,integer,text) to authenticated;
grant execute on function public.gk_get_lecture_part_batch(text,text,integer,integer) to authenticated;
grant execute on function public.gk_get_new_practice_hub() to authenticated;
grant execute on function public.gk_get_guessed_hub() to authenticated;
grant execute on function public.gk_get_flagged_content() to authenticated;

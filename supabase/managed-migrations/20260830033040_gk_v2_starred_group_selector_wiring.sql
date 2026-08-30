-- Route the existing Starred day-group modes through the dedicated read-only
-- group selector. This preserves old Random 10 / Smart 20 / Practice All behavior
-- without changing the React URL contract or any learning data.
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
 group_kind text:=case when coalesce(p_count,20)=10 then 'random' when coalesce(p_count,20)=20 then 'smart' else 'all' end;
 out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if lane_name not in ('MAIN','RAPID','MIXED','ALL') then raise exception 'Invalid GK question style'; end if;
 if mode_name ~ '^starred_age_[0-9]+_[0-9]+$' then
   age_from:=split_part(mode_name,'_',3)::int;
   age_to:=split_part(mode_name,'_',4)::int;
   return public.gk_get_starred_group_batch(age_from,age_to,false,group_kind,n);
 end if;
 if mode_name='starred_earlier' then
   return public.gk_get_starred_group_batch(null,null,true,group_kind,n);
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
revoke execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) from public,anon;
grant execute on function public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text) to authenticated;

-- GK V2 parity follow-up: exact old Starred age grouping, rotation-aware Smart,
-- strict random-New, and dynamic + persisted On Demand behavior.

alter table gk.demand_sets add column if not exists user_id uuid;
create index if not exists gk_demand_sets_owner_idx on gk.demand_sets(user_id,active,last_used);

-- Replace the central selector without changing its public signature.
-- This keeps all React practice routes on one normalized question contract.
create or replace function public.gk_get_batch(
 p_mode text default 'smart',p_count integer default 20,p_lane text default 'MIXED',
 p_subject text default null,p_topic text default null,p_lecture_key text default null,p_library_key text default null,
 p_demand_id text default null,p_ca_months integer default null,p_ca_category text default null
) returns jsonb
language plpgsql
stable security definer
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

create or replace function public.gk_get_starred_hub()
returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), rows as(
 select s.question_id,s.learning_status,s.next_review,s.difficult,s.starred_at,
   greatest(0,floor(extract(epoch from(now()-s.starred_at))/86400)::int) age,
   (select max(a.attempted_at) from gk.attempts a where a.user_id=u.uid and a.question_id=s.question_id and (a.mode like 'starred_%' or a.mode='review')) last_starred_revision
 from gk.question_state s cross join u where s.user_id=u.uid and s.marked_review and s.starred_at is not null
), exact_days as(
 select age,('Day '||(age+1)) label,age age_from,age age_to from generate_series(0,9) age
), later_bands as(
 select 10 age,'Days 11–20' label,10 age_from,19 age_to union all
 select 20,'Days 21–30',20,29 union all
 select start_age,('Days '||(start_age+1)||'–'||(start_age+30)),start_age,start_age+29
 from generate_series(30,greatest(30,coalesce((select max(age) from rows),30)),30) start_age
), groups as(
 select d.label,d.age_from,d.age_to,count(r.question_id)::int count,
   count(*) filter(where r.learning_status='Persistent Weak')::int persistent_weak,
   count(*) filter(where r.learning_status in ('Weak','Fragile'))::int weak_fragile,
   count(*) filter(where r.next_review<=now())::int due,
   count(*) filter(where r.difficult)::int difficult,
   count(*) filter(where r.learning_status not in ('Persistent Weak','Weak','Fragile') and not coalesce(r.next_review<=now(),false))::int healthy
 from (select * from exact_days union all select * from later_bands) d
 left join rows r on r.age between d.age_from and d.age_to group by d.age,d.label,d.age_from,d.age_to having count(r.question_id)>0
), summary as(
 select count(*)::int starred,count(*) filter(where learning_status in ('Persistent Weak','Weak','Fragile') or next_review<=now())::int focus,
   count(*) filter(where difficult)::int difficult,count(*) filter(where learning_status='Proven Mastered')::int mastered,
   count(*) filter(where next_review<=now())::int due,count(*) filter(where last_starred_revision is null)::int never_revised from rows
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'summary',(select to_jsonb(summary) from summary),
 'groups',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'ageFrom',age_from,'ageTo',age_to,'count',count,'health',jsonb_build_object('persistentWeak',persistent_weak,'weakFragile',weak_fragile,'due',due,'difficult',difficult,'healthy',healthy)) order by age_from desc),'[]'::jsonb) from groups)
) end;
$$;

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
   'longUnseen',(select count(*) from b where last_seen is null or last_seen<now()-interval '30 days')
 ),
 'weakTopics',(select coalesce(jsonb_agg(to_jsonb(x) order by persistent_weak desc,weak desc,topic),'[]'::jsonb) from (select * from concepts where weak>0 limit 30)x),
 'myDemandSets',(select coalesce(jsonb_agg(jsonb_build_object('demandId',demand_id,'title',coalesce(title,demand_id),'kind',kind,'count',jsonb_array_length(coalesce(question_ids,'[]'::jsonb)),'lastUsed',last_used) order by coalesce(last_used,created_at) desc nulls last,demand_id),'[]'::jsonb) from gk.demand_sets d cross join u where d.active and (d.user_id is null or d.user_id=u.uid))
) end;
$$;

create or replace function public.gk_create_demand_set(p_kind text default 'weak',p_count integer default 20,p_title text default null)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,gk,auth
as $$
declare uid uuid:=auth.uid(); kind_name text:=lower(btrim(coalesce(p_kind,'weak'))); mode_name text; title_name text; n int:=greatest(1,least(100,coalesce(p_count,20))); payload jsonb; ids jsonb; did text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 mode_name:=case kind_name when 'guessed' then 'guessed_smart' when 'difficult' then 'difficult' when 'long_unseen' then 'long_unseen' else 'weak' end;
 title_name:=coalesce(nullif(btrim(p_title),''),case kind_name when 'guessed' then 'Guessed Focus' when 'difficult' then 'Difficult Focus' when 'long_unseen' then 'Long Time No See' else 'Fix Weaknesses' end);
 payload:=public.gk_get_batch(mode_name,n,'MIXED',null,null,null,null,null,null,null);
 select coalesce(jsonb_agg(value->>'id'),'[]'::jsonb) into ids from jsonb_array_elements(payload);
 if jsonb_array_length(ids)=0 then return jsonb_build_object('ok',false,'message','No eligible questions for this set.'); end if;
 did:='DMD-'||gen_random_uuid()::text;
 insert into gk.demand_sets(demand_id,title,kind,criteria,question_ids,created_at,active,user_id)
 values(did,title_name,kind_name,jsonb_build_object('kind',kind_name,'limit',n),ids,now(),true,uid);
 return jsonb_build_object('ok',true,'setId',did,'title',title_name,'count',jsonb_array_length(ids));
end;
$$;

grant execute on function public.gk_get_starred_hub() to authenticated;
grant execute on function public.gk_get_on_demand_hub() to authenticated;
grant execute on function public.gk_create_demand_set(text,integer,text) to authenticated;

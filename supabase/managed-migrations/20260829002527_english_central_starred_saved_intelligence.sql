create or replace function english.saved_revision_candidates(p_user_id uuid)
returns table(
  question_id text,state text,due boolean,difficult boolean,starred boolean,mastered boolean,
  controlled_new boolean,never_revised boolean,revised_count integer,last_revision timestamptz,days_since_revision integer,created_at timestamptz
)
language sql stable security definer
set search_path='pg_catalog','english','auth'
as $$
with saved as (
  select si.practice_question_id question_id,min(si.created_at) created_at
  from english.saved_items si
  where si.user_id=p_user_id and si.active and nullif(btrim(si.practice_question_id),'') is not null
  group by si.practice_question_id
), mods as (
  select a.question_id,count(*)::int revised_count,max(a.attempted_at) last_revision
  from english.attempts a join saved x on x.question_id=a.question_id
  where a.user_id=p_user_id and lower(coalesce(a.module,''))='mysavedrevision'
  group by a.question_id
)
select q.question_id,coalesce(s.status,'New'),
  (s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date + 1)::timestamp at time zone 'Asia/Kolkata')) due,
  coalesce(d.difficult,false),coalesce(s.last_marked,false),coalesce(s.mastered,false),
  coalesce(s.attempts,0)=0,coalesce(m.revised_count,0)=0,coalesce(m.revised_count,0),m.last_revision,
  case when m.last_revision is null then null else greatest(0,floor(extract(epoch from (now()-m.last_revision))/86400)::int) end,
  x.created_at
from saved x join english.questions q on q.question_id=x.question_id and q.active
left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
left join mods m on m.question_id=q.question_id;
$$;

create or replace function public.english_get_saved_revision_hub() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with c as (select * from english.saved_revision_candidates(auth.uid())), e as (select * from c where not mastered),
stats as (
 select count(*)::int saved,count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and never_revised)::int never_revised,count(*) filter(where not mastered and due)::int due,
 count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where not mastered and starred)::int starred,
 count(*) filter(where mastered)::int mastered from c
), days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,count(*)::int saved,
 count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and due)::int due,count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where mastered)::int mastered
 from c group by 1 order by 1 desc
)
select jsonb_build_object(
 'version','V2','stats',jsonb_build_object('saved',s.saved,'eligible',s.eligible,'controlledNew',s.controlled_new,'neverRevised',s.never_revised,'due',s.due,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'mastered',s.mastered),
 'available',jsonb_build_object('smart',s.eligible,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'random',s.eligible,'all',s.eligible),
 'sizes',jsonb_build_array(10,20,30,50),
 'history',coalesce((select jsonb_agg(jsonb_build_object('date',d,'label',to_char(d,'DD Mon YYYY'),'saved',saved,'eligible',eligible,'controlledNew',controlled_new,'due',due,'weak',weak,'difficult',difficult,'mastered',mastered) order by d desc) from days),'[]'::jsonb)
) from stats s;
$$;
grant execute on function public.english_get_saved_revision_hub() to authenticated;

create or replace function public.english_get_saved_revision_batch(p_mode text default 'smart',p_count integer default 20)
returns jsonb language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid(); m text:=lower(btrim(coalesce(p_mode,'smart'))); n integer:=greatest(1,least(100,coalesce(p_count,20))); eligible_n integer; remaining integer; urgent integer; coverage integer; learning_ratio numeric:=.5; new_target integer; learn_target integer; rotation_target integer; out jsonb; cur integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('smart','weak','difficult','starred','random','all') then raise exception 'Unknown My Saved mode: %',p_mode; end if;
 create temporary table if not exists pg_temp.saved_pick(question_id text primary key,lane text,reason text,ord integer) on commit drop; truncate pg_temp.saved_pick;
 if m='all' then
   insert into pg_temp.saved_pick select c.question_id,'rotation',case when c.never_revised then 'Never Revised' when coalesce(c.days_since_revision,0)>=7 then 'Longest Not Revised' else 'Coverage Rotation' end,row_number() over(order by c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz),case when c.due and c.state='Persistent Weak' then 8 when c.due and c.state='Weak' then 7 when c.due and c.state='Fragile' then 6 when c.due then 5 when c.difficult then 4 when c.never_revised then 3 when c.state in ('Learning','New') then 2 else 1 end desc,c.question_id)::int from english.saved_revision_candidates(uid)c where not c.mastered;
 elsif m='random' then
   insert into pg_temp.saved_pick select x.question_id,'learning','Random',x.rn from (select c.question_id,row_number() over(order by random())::int rn from english.saved_revision_candidates(uid)c where not c.mastered)x order by x.rn limit n;
 elsif m in ('weak','difficult','starred') then
   insert into pg_temp.saved_pick
   select x.question_id,'learning',case when m='weak' then x.state when m='difficult' then 'Difficult' else 'Starred' end,x.rn from (
     select c.*,row_number() over(order by case when c.due and c.state='Persistent Weak' then 8 when c.due and c.state='Weak' then 7 when c.due and c.state='Fragile' then 6 when c.due then 5 when c.difficult then 4 when c.never_revised then 3 when c.state in ('Learning','New') then 2 else 1 end desc,c.due desc,c.difficult desc,coalesce(c.days_since_revision,1000000000) desc,c.question_id)::int rn
     from english.saved_revision_candidates(uid)c where not c.mastered and (m<>'weak' or c.state in ('Persistent Weak','Weak','Fragile')) and (m<>'difficult' or c.difficult) and (m<>'starred' or c.starred)
   )x order by x.rn limit n;
 else
   select count(*) into eligible_n from english.saved_revision_candidates(uid)c where not c.mastered; n:=least(n,coalesce(eligible_n,0)); if n=0 then return '[]'::jsonb; end if;
   select least(count(*) filter(where controlled_new),greatest(1,round(n*.2)::int)) into new_target from english.saved_revision_candidates(uid)c where not c.mastered;
   insert into pg_temp.saved_pick select c.question_id,'new','Controlled New',row_number() over(order by c.question_id)::int from english.saved_revision_candidates(uid)c where not c.mastered and c.controlled_new order by c.question_id limit new_target;
   remaining:=n-new_target;
   select count(*) filter(where (case when c.due and c.state='Persistent Weak' then 8 when c.due and c.state='Weak' then 7 when c.due and c.state='Fragile' then 6 when c.due then 5 when c.difficult then 4 when c.never_revised then 3 when c.state in ('Learning','New') then 2 else 1 end)>=4),count(*) filter(where c.never_revised or coalesce(c.days_since_revision,0)>=7) into urgent,coverage from english.saved_revision_candidates(uid)c where not c.mastered and not exists(select 1 from pg_temp.saved_pick p where p.question_id=c.question_id);
   if urgent>=ceil(greatest(1,remaining)*.7) then learning_ratio:=.6; end if; if coverage>=ceil(greatest(1,remaining)*.5) then learning_ratio:=.4; end if;
   learn_target:=round(remaining*learning_ratio); rotation_target:=remaining-learn_target;
   insert into pg_temp.saved_pick select x.question_id,'learning',x.reason,new_target+x.rn from (
      select c.question_id,case when c.state in ('Persistent Weak','Weak','Fragile') then c.state when c.due and c.difficult then 'Difficult + Due' when c.due then 'Due Recall' when c.difficult then 'Difficult' when c.state in ('Learning','New') then 'Learning' else 'Healthy Rotation' end reason,row_number() over(order by case when c.due and c.state='Persistent Weak' then 8 when c.due and c.state='Weak' then 7 when c.due and c.state='Fragile' then 6 when c.due then 5 when c.difficult then 4 when c.never_revised then 3 when c.state in ('Learning','New') then 2 else 1 end desc,c.due desc,c.difficult desc,coalesce(c.days_since_revision,1000000000) desc,c.question_id)::int rn from english.saved_revision_candidates(uid)c where not c.mastered and not exists(select 1 from pg_temp.saved_pick p where p.question_id=c.question_id)
   )x order by x.rn limit learn_target;
   select count(*) into cur from pg_temp.saved_pick;
   insert into pg_temp.saved_pick select x.question_id,'rotation',x.reason,cur+x.rn from (
      select c.question_id,case when c.never_revised then 'Never Revised' when coalesce(c.days_since_revision,0)>=7 then 'Longest Not Revised' else 'Coverage Rotation' end reason,row_number() over(order by c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz),case when c.due and c.state='Persistent Weak' then 8 when c.due and c.state='Weak' then 7 when c.due and c.state='Fragile' then 6 when c.due then 5 when c.difficult then 4 when c.never_revised then 3 when c.state in ('Learning','New') then 2 else 1 end desc,c.question_id)::int rn from english.saved_revision_candidates(uid)c where not c.mastered and not exists(select 1 from pg_temp.saved_pick p where p.question_id=c.question_id)
   )x order by x.rn limit rotation_target;
   select count(*) into cur from pg_temp.saved_pick;
   if cur<n then insert into pg_temp.saved_pick select x.question_id,'rotation',x.reason,cur+x.rn from (select c.question_id,case when c.never_revised then 'Never Revised' when coalesce(c.days_since_revision,0)>=7 then 'Longest Not Revised' else 'Coverage Rotation' end reason,row_number() over(order by c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz),c.question_id)::int rn from english.saved_revision_candidates(uid)c where not c.mastered and not exists(select 1 from pg_temp.saved_pick p where p.question_id=c.question_id))x order by x.rn limit n-cur; end if;
 end if;
 select coalesce(jsonb_agg(english.question_payload(uid,p.question_id)||jsonb_build_object('smartMySaved',true,'smartMySavedLane',p.lane,'smartMySavedReason',p.reason) order by p.ord),'[]'::jsonb) into out from pg_temp.saved_pick p;
 return out;
end $$;
grant execute on function public.english_get_saved_revision_batch(text,integer) to authenticated;

create or replace function english.starred_revision_candidates(p_user_id uuid)
returns table(question_id text,state text,due boolean,difficult boolean,controlled_new boolean,never_revised boolean,revised_count integer,last_revision timestamptz,days_since_revision integer,origin_day integer)
language sql stable security definer
set search_path='pg_catalog','english','auth'
as $$
with mods as (
 select a.question_id,count(*)::int revised_count,max(a.attempted_at) last_revision from english.attempts a where a.user_id=p_user_id and lower(coalesce(a.module,''))='starredrevision' group by a.question_id
), ev as (
 select distinct on (e.question_id) e.question_id,e.day_no from english.star_events e where e.user_id=p_user_id order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
)
select q.question_id,coalesce(s.status,'New'),(s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')),
 coalesce(d.difficult,false),coalesce(s.attempts,0)=0,coalesce(m.revised_count,0)=0,coalesce(m.revised_count,0),m.last_revision,
 case when m.last_revision is null then null else greatest(0,floor(extract(epoch from (now()-m.last_revision))/86400)::int) end,
 greatest(1,coalesce(ev.day_no,1))
from english.questions q join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id and coalesce(s.last_marked,false)
left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id left join mods m on m.question_id=q.question_id left join ev on ev.question_id=q.question_id
where q.active and not coalesce(s.mastered,false);
$$;

create or replace function public.english_get_starred_hub(p_from_day integer default null,p_to_day integer default null) returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with allc as (select * from english.starred_revision_candidates(auth.uid())), c as (select * from allc where (p_from_day is null or origin_day>=p_from_day) and (p_to_day is null or origin_day<=p_to_day)),
s as (select count(*)::int active,count(*) filter(where revised_count>0)::int revised,count(*) filter(where never_revised)::int never_revised,count(*) filter(where revised_count=1)::int revised_once,count(*) filter(where revised_count>=2)::int revised_multiple,count(*) filter(where revised_count>0 and coalesce(days_since_revision,0)>=14)::int long_overdue,count(*) filter(where due)::int due,count(*) filter(where state in ('Persistent Weak','Weak','Fragile'))::int weak,count(*) filter(where state='Persistent Weak')::int persistent_weak,count(*) filter(where state='Fragile')::int fragile,count(*) filter(where difficult)::int difficult,count(*) filter(where state='Strong')::int strong,count(*) filter(where state in ('Learning','New'))::int learning from c),
days as (select origin_day,count(*)::int count from allc group by origin_day order by origin_day desc)
select jsonb_build_object('version','V1','stats',jsonb_build_object('active',s.active,'revised',s.revised,'neverRevised',s.never_revised,'revisedOnce',s.revised_once,'revisedMultiple',s.revised_multiple,'longOverdue',s.long_overdue,'due',s.due,'weak',s.weak,'persistentWeak',s.persistent_weak,'fragile',s.fragile,'difficult',s.difficult,'strong',s.strong,'learning',s.learning),'available',jsonb_build_object('smart',s.active,'notRevised',s.never_revised,'due',s.due,'weak',s.weak,'difficult',s.difficult,'longest',s.active,'all',s.active),'sizes',jsonb_build_array(10,20,30,50),'history',coalesce((select jsonb_agg(jsonb_build_object('day',origin_day,'label','Day '||origin_day,'count',count) order by origin_day desc) from days),'[]'::jsonb)) from s;
$$;
grant execute on function public.english_get_starred_hub(integer,integer) to authenticated;

create or replace function public.english_get_starred_batch(p_mode text default 'smart',p_count integer default 20,p_from_day integer default null,p_to_day integer default null)
returns jsonb language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();m text:=lower(btrim(coalesce(p_mode,'smart')));n integer:=greatest(1,least(50,coalesce(p_count,20)));total_n integer;remaining integer;urgent integer;rotation_pressure integer;ratio numeric:=.6;new_target integer;learn_target integer;rotation_target integer;cur integer;out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('smart','notrevised','due','weak','difficult','longest','all','random') then raise exception 'Unknown Starred mode: %',p_mode; end if;
 create temporary table if not exists pg_temp.star_pick(question_id text primary key,lane text,reason text,ord integer) on commit drop;truncate pg_temp.star_pick;
 if m='all' then
  insert into pg_temp.star_pick select c.question_id,'rotation',case when c.never_revised then 'Never Revised' when coalesce(c.days_since_revision,0)>=7 then 'Longest Not Revised' else 'Coverage Rotation' end,row_number() over(order by c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz),c.question_id)::int from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day);
 elsif m='random' then
  insert into pg_temp.star_pick select x.question_id,'rotation','Random',x.rn from (select c.question_id,row_number() over(order by random())::int rn from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day))x order by x.rn limit n;
 elsif m in ('notrevised','due','weak','difficult','longest') then
  insert into pg_temp.star_pick select x.question_id,case when m in ('notrevised','longest') then 'rotation' else 'learning' end,case when m='notrevised' then 'Never Revised' when m='due' then 'Due Recall' when m='weak' then x.state when m='difficult' then 'Difficult' when x.never_revised then 'Never Revised' else 'Longest Not Revised' end,x.rn from (
   select c.*,row_number() over(order by case when m in ('notrevised','longest') then 0 else case when c.due and c.state='Persistent Weak' then 7 when c.due and c.state='Weak' then 6 when c.due and c.state='Fragile' then 5 when c.due then 4 when c.difficult then 3 when c.state in ('Learning','New') then 2 else 1 end end desc,case when m in ('notrevised','longest') then coalesce(c.last_revision,'epoch'::timestamptz) end asc,c.due desc,c.difficult desc,coalesce(c.days_since_revision,1000000000) desc,c.question_id)::int rn
   from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day) and (m<>'notrevised' or c.never_revised) and (m<>'due' or c.due) and (m<>'weak' or c.state in ('Persistent Weak','Weak','Fragile')) and (m<>'difficult' or c.difficult)
  )x order by x.rn limit n;
 else
  select count(*) into total_n from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day);n:=least(n,coalesce(total_n,0));if n=0 then return '[]'::jsonb;end if;
  select least(count(*) filter(where controlled_new),greatest(1,round(n*.2)::int)) into new_target from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day);
  insert into pg_temp.star_pick select c.question_id,'new','Controlled New',row_number() over(order by c.question_id)::int from english.starred_revision_candidates(uid)c where c.controlled_new and (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day) order by c.question_id limit new_target;
  remaining:=n-new_target;
  select count(*) filter(where (case when c.due and c.state='Persistent Weak' then 7 when c.due and c.state='Weak' then 6 when c.due and c.state='Fragile' then 5 when c.due then 4 when c.difficult then 3 when c.state in ('Learning','New') then 2 else 1 end)>=3),count(*) filter(where c.never_revised or coalesce(c.days_since_revision,0)>=7) into urgent,rotation_pressure from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day) and not exists(select 1 from pg_temp.star_pick p where p.question_id=c.question_id);
  if urgent>=ceil(greatest(1,remaining)*.7) and rotation_pressure>0 then ratio:=.7; elsif urgent<=floor(remaining*.35) and rotation_pressure>=ceil(greatest(1,remaining)*.5) then ratio:=.4; end if;
  learn_target:=round(remaining*ratio);rotation_target:=remaining-learn_target;
  insert into pg_temp.star_pick select x.question_id,'learning',x.reason,new_target+x.rn from (
   select c.question_id,case when c.due and c.state in ('Persistent Weak','Weak','Fragile') then c.state when c.due and c.difficult then 'Difficult + Due' when c.due then 'Due Recall' when c.difficult then 'Difficult' when c.state in ('Learning','New') then 'Learning' else 'Coverage Rotation' end reason,row_number() over(order by case when c.due and c.state='Persistent Weak' then 7 when c.due and c.state='Weak' then 6 when c.due and c.state='Fragile' then 5 when c.due then 4 when c.difficult then 3 when c.state in ('Learning','New') then 2 else 1 end desc,c.due desc,c.difficult desc,coalesce(c.days_since_revision,1000000000) desc,c.question_id)::int rn from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day) and not exists(select 1 from pg_temp.star_pick p where p.question_id=c.question_id)
  )x order by x.rn limit learn_target;
  select count(*) into cur from pg_temp.star_pick;
  insert into pg_temp.star_pick select x.question_id,'rotation',x.reason,cur+x.rn from (
   select c.question_id,case when c.never_revised then 'Never Revised' when coalesce(c.days_since_revision,0)>=7 then 'Longest Not Revised' else 'Coverage Rotation' end reason,row_number() over(order by c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz),case when c.due and c.state='Persistent Weak' then 7 when c.due and c.state='Weak' then 6 when c.due and c.state='Fragile' then 5 when c.due then 4 when c.difficult then 3 when c.state in ('Learning','New') then 2 else 1 end desc,c.question_id)::int rn from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day) and not exists(select 1 from pg_temp.star_pick p where p.question_id=c.question_id)
  )x order by x.rn limit rotation_target;
  select count(*) into cur from pg_temp.star_pick;if cur<n then insert into pg_temp.star_pick select x.question_id,'rotation',x.reason,cur+x.rn from (select c.question_id,case when c.never_revised then 'Never Revised' else 'Coverage Rotation' end reason,row_number() over(order by c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz),c.question_id)::int rn from english.starred_revision_candidates(uid)c where (p_from_day is null or c.origin_day>=p_from_day) and (p_to_day is null or c.origin_day<=p_to_day) and not exists(select 1 from pg_temp.star_pick p where p.question_id=c.question_id))x order by x.rn limit n-cur;end if;
 end if;
 select coalesce(jsonb_agg(english.question_payload(uid,p.question_id)||jsonb_build_object('starredIntelligence',true,'starredSelectionLane',p.lane,'starredSelectionReason',p.reason) order by p.ord),'[]'::jsonb) into out from pg_temp.star_pick p;return out;
end $$;
grant execute on function public.english_get_starred_batch(text,integer,integer,integer) to authenticated;

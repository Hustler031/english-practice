create or replace function public.english_get_starred_batch(p_mode text default 'smart',p_count integer default 20,p_from_day integer default null,p_to_day integer default null)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
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
 select coalesce(jsonb_agg(
   english.question_payload(uid,p.question_id)||jsonb_build_object(
     'starredIntelligence',true,'starredSelectionLane',p.lane,'starredSelectionReason',p.reason,
     'starredSelectionSignals',english.starred_selection_signals(c.state,c.due,c.difficult,c.never_revised,c.days_since_revision)
   ) order by p.ord
 ),'[]'::jsonb) into out
 from pg_temp.star_pick p join english.starred_revision_candidates(uid) c on c.question_id=p.question_id;
 return out;
end $$;

revoke execute on function public.english_get_starred_batch(text,integer,integer,integer) from public,anon;
grant execute on function public.english_get_starred_batch(text,integer,integer,integer) to authenticated,service_role;

create or replace function english.daily_day_no(p_date date)
returns integer language sql immutable as $$
select greatest(1,(coalesce(p_date,date '2026-08-14')-date '2026-08-14')+1);
$$;

create or replace function english.starred_manual_index(p_user_id uuid)
returns table(question_id text,origin_day integer,starred boolean,mastered boolean,difficult boolean)
language sql stable security definer
set search_path=pg_catalog,english,auth as $$
with ev as (
  select e.question_id,bool_or(e.action='STAR') ever_starred
  from english.star_events e where e.user_id=p_user_id group by e.question_id
), latest as (
  select distinct on (e.question_id) e.question_id,greatest(1,coalesce(e.day_no,1))::int day_no,e.action
  from english.star_events e where e.user_id=p_user_id
  order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
)
select qs.question_id,greatest(1,coalesce(l.day_no,1))::int,
       coalesce(qs.last_marked,false),coalesce(qs.mastered,false),coalesce(d.difficult,false)
from english.question_state qs
join english.questions q on q.question_id=qs.question_id and q.active
left join ev on ev.question_id=qs.question_id
left join latest l on l.question_id=qs.question_id
left join english.difficult_state d on d.user_id=qs.user_id and d.question_id=qs.question_id
where qs.user_id=p_user_id
  and (coalesce(ev.ever_starred,false) or coalesce(qs.last_marked,false))
  and (coalesce(qs.last_marked,false) or coalesce(qs.mastered,false));
$$;

create or replace function english.starred_selection_signals(
  p_state text,p_due boolean,p_difficult boolean,p_never boolean,p_days integer
)
returns text[] language sql immutable as $$
select array_remove(array[
  nullif(coalesce(p_state,'New'),''),
  case when p_due then 'Due Recall' end,
  case when p_difficult then 'Difficult' end,
  case when p_never then 'Never Revised'
       when coalesce(p_days,0)>=14 then '14+ Days Not Revised'
       when coalesce(p_days,0)>=7 then '7+ Days Not Revised' end
]::text[],null);
$$;

create or replace function public.english_get_starred_hub(p_from_day integer default null,p_to_day integer default null)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with allc as (
  select * from english.starred_revision_candidates(auth.uid())
), c as (
  select * from allc
  where (p_from_day is null or origin_day>=p_from_day)
    and (p_to_day is null or origin_day<=p_to_day)
), s as (
  select count(*)::int active,
    count(*) filter(where revised_count>0)::int revised,
    count(*) filter(where never_revised)::int never_revised,
    count(*) filter(where revised_count=1)::int revised_once,
    count(*) filter(where revised_count>=2)::int revised_multiple,
    count(*) filter(where revised_count>0 and coalesce(days_since_revision,0)>=14)::int long_overdue,
    count(*) filter(where due)::int due,
    count(*) filter(where state in ('Persistent Weak','Weak','Fragile'))::int weak,
    count(*) filter(where state='Persistent Weak')::int persistent_weak,
    count(*) filter(where state='Weak')::int weak_exact,
    count(*) filter(where state='Fragile')::int fragile,
    count(*) filter(where difficult)::int difficult,
    count(*) filter(where state='Strong')::int strong,
    count(*) filter(where state in ('Learning','New'))::int learning,
    count(*) filter(where due and state in ('Persistent Weak','Weak','Fragile'))::int due_weak
  from c
), manual_all as (
  select * from english.starred_manual_index(auth.uid())
), manual_scope as (
  select * from manual_all where (p_from_day is null or origin_day>=p_from_day) and (p_to_day is null or origin_day<=p_to_day)
), ms as (
  select count(*)::int starred,count(*) filter(where mastered)::int mastered,
         count(*) filter(where starred and not mastered)::int focus,
         count(*) filter(where difficult and starred and not mastered)::int difficult
  from manual_scope
), cur as (
  select coalesce(
    (select max(english.daily_day_no(quiz_date)) from english.daily_current where user_id=auth.uid()),
    (select max(day_no) from english.daily_history where user_id=auth.uid()),
    (select max(origin_day) from manual_all),1
  )::int current_day
), bounds as (
  select current_day,
         floor((current_day-1)/30.0)::int+1 current_month,
         (floor((current_day-1)/30.0)::int)*30+1 current_month_start,
         (floor((current_day-1)/10.0)::int)*10+1 current_block_start
  from cur
), day_ranges as (
  select 'day'::text type,'Day '||d label,d::int from_day,d::int to_day,
         (b.current_day-d)::int sort_order,true expanded
  from bounds b cross join lateral generate_series(b.current_day,b.current_block_start,-1) d
), block_ranges as (
  select 'block','Days '||st||'–'||least(st+9,b.current_day),st::int,least(st+9,b.current_day)::int,
         1000+(b.current_block_start-st)::int,false
  from bounds b cross join lateral generate_series(b.current_block_start-10,b.current_month_start,-10) st
), month_ranges as (
  select 'month','Month '||m||' · Days '||((m-1)*30+1)||'–'||(m*30),((m-1)*30+1)::int,(m*30)::int,
         2000+(b.current_month-m)::int,false
  from bounds b cross join lateral generate_series(b.current_month-1,1,-1) m
), ranges as (
  select * from day_ranges union all select * from block_ranges union all select * from month_ranges
), group_rows as (
  select r.type,r.label,r.from_day,r.to_day,r.sort_order,r.expanded,
         count(m.question_id)::int starred,
         count(*) filter(where m.mastered)::int mastered,
         count(*) filter(where m.starred and not m.mastered)::int focus,
         count(*) filter(where m.difficult and m.starred and not m.mastered)::int difficult
  from ranges r left join manual_all m on m.origin_day between r.from_day and r.to_day
  group by r.type,r.label,r.from_day,r.to_day,r.sort_order,r.expanded
  having count(m.question_id)>0
), days as (
  select origin_day,count(*)::int starred,count(*) filter(where mastered)::int mastered,
         count(*) filter(where starred and not mastered)::int focus,
         count(*) filter(where difficult and starred and not mastered)::int difficult
  from manual_all group by origin_day
)
select jsonb_build_object(
 'version','V3-central-parity','currentDay',cur.current_day,
 'stats',jsonb_build_object(
   'active',s.active,'revised',s.revised,'neverRevised',s.never_revised,'revisedOnce',s.revised_once,'revisedMultiple',s.revised_multiple,
   'longOverdue',s.long_overdue,'due',s.due,'weak',s.weak,'weakExact',s.weak_exact,'persistentWeak',s.persistent_weak,
   'fragile',s.fragile,'difficult',s.difficult,'strong',s.strong,'learning',s.learning,'dueWeak',s.due_weak,
   'starred',ms.starred,'mastered',ms.mastered,'focus',ms.focus,'manualDifficult',ms.difficult
 ),
 'available',jsonb_build_object('smart',s.active,'notRevised',s.never_revised,'due',s.due,'weak',s.weak,'difficult',s.difficult,'longest',s.active,'all',s.active),
 'sizes',jsonb_build_array(10,20,30,50),
 'groups',coalesce((select jsonb_agg(jsonb_build_object(
    'type',g.type,'label',g.label,'fromDay',g.from_day,'toDay',g.to_day,'expanded',g.expanded,
    'stats',jsonb_build_object('starred',g.starred,'mastered',g.mastered,'focus',g.focus,'difficult',g.difficult)
  ) order by g.sort_order) from group_rows g),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(jsonb_build_object(
    'day',origin_day,'label','Day '||origin_day,'count',focus,'starred',starred,'mastered',mastered,'focus',focus,'difficult',difficult
  ) order by origin_day desc) from days),'[]'::jsonb)
) from s cross join ms cross join cur;
$$;

create or replace function public.english_get_starred_manual_items(p_mode text default 'all',p_from_day integer default null,p_to_day integer default null)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); m text:=lower(btrim(coalesce(p_mode,'all'))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('all','mastered') then raise exception 'Unknown Starred manual view mode: %',p_mode; end if;
 with rows as (
   select * from english.starred_manual_index(uid)
   where (p_from_day is null or origin_day>=p_from_day)
     and (p_to_day is null or origin_day<=p_to_day)
     and (m<>'mastered' or mastered)
 )
 select coalesce(jsonb_agg(english.question_payload(uid,r.question_id)||jsonb_build_object(
   'starredDay',r.origin_day,'starred',r.starred,'mastered',r.mastered,'difficult',r.difficult
 ) order by r.origin_day desc,r.question_id),'[]'::jsonb) into out from rows r;
 return out;
end;
$$;

create or replace function public.english_get_saved_revision_hub()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with c0 as (select * from english.saved_revision_candidates(auth.uid())),
types as (
 select distinct on (si.practice_question_id) si.practice_question_id,
        coalesce(nullif(sit.resolved_type,''),nullif(sit.capture_type,''),'') saved_type
 from english.saved_items si
 left join english.saved_item_types sit on sit.user_id=si.user_id and sit.saved_id=si.saved_id
 where si.user_id=auth.uid() and si.active and nullif(btrim(si.practice_question_id),'') is not null
 order by si.practice_question_id,si.created_at
), c as (
 select c0.*,english.daily_day_no((c0.created_at at time zone 'Asia/Kolkata')::date) origin_day,
        coalesce(t.saved_type,'') saved_type,q.topic,q.concept_id
 from c0 join english.questions q on q.question_id=c0.question_id
 left join types t on t.practice_question_id=c0.question_id
), stats as (
 select count(*)::int saved,count(*) filter(where not mastered)::int eligible,
 count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and never_revised)::int never_revised,
 count(*) filter(where not mastered and due)::int due,
 count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and state='Persistent Weak')::int persistent_weak,
 count(*) filter(where not mastered and difficult)::int difficult,
 count(*) filter(where not mastered and starred)::int starred,
 count(*) filter(where mastered)::int mastered,
 count(*) filter(where not mastered and not controlled_new)::int seen
 from c
), cur as (
 select coalesce((select max(english.daily_day_no(quiz_date)) from english.daily_current where user_id=auth.uid()),
                 (select max(day_no) from english.daily_history where user_id=auth.uid()),
                 (select max(origin_day) from c),1)::int current_day
), bounds as (
 select current_day,floor((current_day-1)/30.0)::int+1 current_month,
        floor((current_day-1)/30.0)::int*30+1 current_month_start,
        floor((current_day-1)/10.0)::int*10+1 current_block_start from cur
), ranges as (
 select 'day'::text type,'Day '||d label,d::int from_day,d::int to_day,(b.current_day-d)::int sort_order
 from bounds b cross join lateral generate_series(b.current_day,b.current_block_start,-1) d
 union all
 select 'block','Days '||st||'–'||least(st+9,b.current_day),st::int,least(st+9,b.current_day)::int,1000+(b.current_block_start-st)::int
 from bounds b cross join lateral generate_series(b.current_block_start-10,b.current_month_start,-10) st
 union all
 select 'month','Month '||m||' · Days '||((m-1)*30+1)||'–'||(m*30),((m-1)*30+1)::int,(m*30)::int,2000+(b.current_month-m)::int
 from bounds b cross join lateral generate_series(b.current_month-1,1,-1) m
), groups as (
 select r.type,r.label,r.from_day,r.to_day,r.sort_order,
   count(c.question_id)::int saved,
   count(*) filter(where not c.mastered)::int focus,
   count(*) filter(where c.controlled_new and not c.mastered)::int new_count,
   count(*) filter(where not c.controlled_new)::int seen,
   count(*) filter(where c.controlled_new)::int left_count,
   count(*) filter(where not c.mastered and c.state in ('Persistent Weak','Weak'))::int weak,
   count(*) filter(where not c.mastered and c.state='Persistent Weak')::int persistent_weak,
   count(*) filter(where not c.mastered and c.difficult)::int difficult,
   count(*) filter(where not c.mastered and c.starred)::int starred,
   count(*) filter(where c.mastered)::int mastered
 from ranges r left join c on c.origin_day between r.from_day and r.to_day
 group by r.type,r.label,r.from_day,r.to_day,r.sort_order having count(c.question_id)>0
), catrows as (
 select case c.saved_type when 'CU' then 'CU' when 'SM' then 'SPELLING' when 'OWS' then 'OWS' when 'PV' then 'PHRASAL' when 'IP' then 'IDIOM' when 'V' then 'VOC' else english.learning_category(c.topic) end id,
        case c.saved_type when 'CU' then 'Concept / Usage' when 'SM' then 'Spelling' when 'OWS' then 'One Word Substitution' when 'PV' then 'Phrasal Verbs' when 'IP' then 'Idioms & Phrases' when 'V' then 'Vocabulary'
             else case english.learning_category(c.topic) when 'FIXED_PREPOSITION' then 'Fixed Preposition' when 'FIELDS_OF_STUDY' then 'Fields of Study' else coalesce(c.topic,'Other') end end name,
        c.* from c
), categories as (
 select id,min(name) name,count(*)::int total,count(*) filter(where not controlled_new)::int seen,
        count(*) filter(where controlled_new)::int left_count
 from catrows group by id
), days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,count(*)::int saved,
 count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and controlled_new)::int controlled_new,
 count(*) filter(where not mastered and due)::int due,count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
 count(*) filter(where not mastered and difficult)::int difficult,count(*) filter(where mastered)::int mastered
 from c group by 1
)
select jsonb_build_object(
 'version','V3-central-parity','currentDay',cur.current_day,
 'stats',jsonb_build_object('saved',s.saved,'eligible',s.eligible,'focus',s.eligible,'controlledNew',s.controlled_new,'newCount',s.controlled_new,
    'neverRevised',s.never_revised,'due',s.due,'weak',s.weak,'persistentWeak',s.persistent_weak,'difficult',s.difficult,
    'starred',s.starred,'mastered',s.mastered,'seen',s.seen,'left',s.controlled_new),
 'available',jsonb_build_object('smart',s.eligible,'weak',s.weak,'difficult',s.difficult,'starred',s.starred,'random',s.eligible,'all',s.eligible),
 'sizes',jsonb_build_array(10,20,30,50),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'total',total,'seen',seen,'left',left_count,
      'coverage',case when total>0 then round(seen*100.0/total,1) else 0 end) order by left_count desc,name) from categories),'[]'::jsonb),
 'groups',coalesce((select jsonb_agg(jsonb_build_object('type',g.type,'label',g.label,'fromDay',g.from_day,'toDay',g.to_day,
      'stats',jsonb_build_object('saved',g.saved,'focus',g.focus,'newCount',g.new_count,'seen',g.seen,'left',g.left_count,
        'weak',g.weak,'persistentWeak',g.persistent_weak,'difficult',g.difficult,'starred',g.starred,'mastered',g.mastered)) order by g.sort_order) from groups g),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(jsonb_build_object('date',d,'label',case when d is null then 'Imported Saved' else to_char(d,'DD Mon YYYY') end,
      'saved',saved,'eligible',eligible,'controlledNew',controlled_new,'due',due,'weak',weak,'difficult',difficult,'mastered',mastered) order by d desc nulls last) from days),'[]'::jsonb)
) from stats s cross join cur;
$$;

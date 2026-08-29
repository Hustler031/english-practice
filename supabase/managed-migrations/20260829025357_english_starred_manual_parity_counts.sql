create or replace function public.english_get_starred_hub(p_from_day integer default null, p_to_day integer default null)
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with allc as (
  select * from english.starred_revision_candidates(auth.uid())
),
c as (
  select * from allc
  where (p_from_day is null or origin_day>=p_from_day)
    and (p_to_day is null or origin_day<=p_to_day)
),
s as (
  select
    count(*)::int active,
    count(*) filter(where revised_count>0)::int revised,
    count(*) filter(where never_revised)::int never_revised,
    count(*) filter(where revised_count=1)::int revised_once,
    count(*) filter(where revised_count>=2)::int revised_multiple,
    count(*) filter(where revised_count>0 and coalesce(days_since_revision,0)>=14)::int long_overdue,
    count(*) filter(where due)::int due,
    count(*) filter(where state in ('Persistent Weak','Weak','Fragile'))::int weak,
    count(*) filter(where state='Persistent Weak')::int persistent_weak,
    count(*) filter(where state='Fragile')::int fragile,
    count(*) filter(where difficult)::int difficult,
    count(*) filter(where state='Strong')::int strong,
    count(*) filter(where state in ('Learning','New'))::int learning
  from c
),
latest_star as (
  select distinct on (e.question_id) e.question_id,e.day_no
  from english.star_events e
  where e.user_id=auth.uid()
  order by e.question_id,e.event_at desc,e.source_row desc nulls last,e.id desc
),
manual as (
  select qs.question_id,
         coalesce(qs.mastered,false) mastered,
         greatest(1,coalesce(ls.day_no,1))::int origin_day,
         coalesce(ds.difficult,false) difficult
  from english.question_state qs
  join english.questions q on q.question_id=qs.question_id and q.active
  left join latest_star ls on ls.question_id=qs.question_id
  left join english.difficult_state ds on ds.user_id=qs.user_id and ds.question_id=qs.question_id
  where qs.user_id=auth.uid() and coalesce(qs.last_marked,false)
),
manual_scope as (
  select * from manual
  where (p_from_day is null or origin_day>=p_from_day)
    and (p_to_day is null or origin_day<=p_to_day)
),
ms as (
  select count(*)::int starred,
         count(*) filter(where mastered)::int mastered,
         count(*) filter(where not mastered)::int focus,
         count(*) filter(where difficult and not mastered)::int difficult
  from manual_scope
),
days as (
  select origin_day,
         count(*)::int starred,
         count(*) filter(where mastered)::int mastered,
         count(*) filter(where not mastered)::int focus,
         count(*) filter(where difficult and not mastered)::int difficult
  from manual
  group by origin_day
  order by origin_day desc
),
cur as (
  select coalesce((select max(day_no) from english.daily_history where user_id=auth.uid()),(select max(origin_day) from manual),1)::int current_day
)
select jsonb_build_object(
 'version','V2-manual-parity',
 'currentDay',cur.current_day,
 'stats',jsonb_build_object(
   'active',s.active,'revised',s.revised,'neverRevised',s.never_revised,'revisedOnce',s.revised_once,'revisedMultiple',s.revised_multiple,
   'longOverdue',s.long_overdue,'due',s.due,'weak',s.weak,'persistentWeak',s.persistent_weak,'fragile',s.fragile,'difficult',s.difficult,
   'strong',s.strong,'learning',s.learning,
   'starred',ms.starred,'mastered',ms.mastered,'focus',ms.focus,'manualDifficult',ms.difficult
 ),
 'available',jsonb_build_object('smart',s.active,'notRevised',s.never_revised,'due',s.due,'weak',s.weak,'difficult',s.difficult,'longest',s.active,'all',s.active),
 'sizes',jsonb_build_array(10,20,30,50),
 'history',coalesce((select jsonb_agg(jsonb_build_object('day',origin_day,'label','Day '||origin_day,'count',focus,'starred',starred,'mastered',mastered,'focus',focus,'difficult',difficult) order by origin_day desc) from days),'[]'::jsonb)
)
from s cross join ms cross join cur;
$function$;

-- My Saved is a permanent collection. Fast Track is a learning route.
-- Preserve all Saved membership/history, but do not deep-revise Fast Track items
-- through Smart/History selectors until they leave Fast Track.

create or replace function english.saved_revision_candidates_all(p_user_id uuid)
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

create or replace function english.saved_revision_candidates(p_user_id uuid)
returns table(
  question_id text,state text,due boolean,difficult boolean,starred boolean,mastered boolean,
  controlled_new boolean,never_revised boolean,revised_count integer,last_revision timestamptz,days_since_revision integer,created_at timestamptz
)
language sql stable security definer
set search_path='pg_catalog','english','auth'
as $$
select a.*
from english.saved_revision_candidates_all(p_user_id) a
where not exists(
  select 1 from english.learning_route_state r
  where r.user_id=p_user_id and r.question_id=a.question_id and r.route='fast_track'
);
$$;

create or replace function public.english_get_saved_revision_hub()
returns jsonb language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with allc as (select * from english.saved_revision_candidates_all(auth.uid())),
elig as (select * from english.saved_revision_candidates(auth.uid())),
stats_all as (
 select count(*)::int saved,count(*) filter(where mastered)::int mastered from allc
), stats_eligible as (
 select count(*) filter(where not mastered)::int eligible,
        count(*) filter(where not mastered and controlled_new)::int controlled_new,
        count(*) filter(where not mastered and never_revised)::int never_revised,
        count(*) filter(where not mastered and due)::int due,
        count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
        count(*) filter(where not mastered and difficult)::int difficult,
        count(*) filter(where not mastered and starred)::int starred
 from elig
), all_days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,count(*)::int saved,count(*) filter(where mastered)::int mastered
 from allc group by 1
), eligible_days as (
 select (created_at at time zone 'Asia/Kolkata')::date d,
        count(*) filter(where not mastered)::int eligible,
        count(*) filter(where not mastered and controlled_new)::int controlled_new,
        count(*) filter(where not mastered and due)::int due,
        count(*) filter(where not mastered and state in ('Persistent Weak','Weak','Fragile'))::int weak,
        count(*) filter(where not mastered and difficult)::int difficult
 from elig group by 1
), days as (
 select a.d,a.saved,a.mastered,coalesce(e.eligible,0)::int eligible,coalesce(e.controlled_new,0)::int controlled_new,
        coalesce(e.due,0)::int due,coalesce(e.weak,0)::int weak,coalesce(e.difficult,0)::int difficult
 from all_days a left join eligible_days e using(d)
), day_meta as (
 select greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1)::int current_day
)
select jsonb_build_object(
 'version','V5','currentDay',m.current_day,
 'stats',jsonb_build_object(
   'saved',sa.saved,'eligible',se.eligible,'controlledNew',se.controlled_new,'neverRevised',se.never_revised,
   'due',se.due,'weak',se.weak,'difficult',se.difficult,'starred',se.starred,'mastered',sa.mastered,
   'fastTrack',greatest(0,sa.saved-sa.mastered-se.eligible)
 ),
 'available',jsonb_build_object(
   'smart',se.eligible,'new',se.never_revised,'weak',se.weak,'difficult',se.difficult,
   'starred',se.starred,'random',se.eligible,'all',se.eligible
 ),
 'sizes',jsonb_build_array(10,20,30,50),
 'history',coalesce((select jsonb_agg(jsonb_build_object(
   'date',d,'day',greatest(1,(d-date '2026-08-14')+1),'label',to_char(d,'DD Mon YYYY'),
   'saved',saved,'eligible',eligible,'controlledNew',controlled_new,'due',due,'weak',weak,'difficult',difficult,'mastered',mastered
 ) order by d desc) from days),'[]'::jsonb)
) from stats_all sa cross join stats_eligible se cross join day_meta m;
$$;

grant execute on function public.english_get_saved_revision_hub() to authenticated,service_role;

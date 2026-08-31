-- Final route hardening: confirmation cooldown, recovery provenance,
-- fresh Fast Track sessions, grouped drill-downs, recovery KPI and bootstrap reconciliation.

create or replace function english.route_origin_matches(p_origins text[],p_origin text)
returns boolean language sql immutable as $$
select case
  when nullif(btrim(coalesce(p_origin,'')),'') is null then true
  when p_origin='Bank Coverage' then ('Bank Coverage'=any(coalesce(p_origins,'{}'::text[])) or 'Historical Clean Bank'=any(coalesce(p_origins,'{}'::text[])))
  else p_origin=any(coalesce(p_origins,'{}'::text[]))
end;
$$;

create or replace function english.route_origin_label(p_origin text)
returns text language sql immutable as $$
select case btrim(coalesce(p_origin,''))
  when 'Historical Clean Bank' then 'Bank Coverage'
  else btrim(coalesce(p_origin,''))
end;
$$;

create or replace function english.route_recovery_origin(p_reason text)
returns text language sql immutable as $$
select case btrim(coalesce(p_reason,''))
  when 'Persistent Weak' then 'Recovered Persistent Weak'
  when 'Weak' then 'Recovered Weak'
  when 'Fragile' then 'Recovered Weak'
  when 'Difficult' then 'Recovered Difficult'
  else 'Recovered Targeted'
end;
$$;

create or replace function public.english_resolve_fast_track_failure(p_question_id text,p_add_targeted boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); r english.learning_route_state%rowtype;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into r from english.learning_route_state where user_id=uid and question_id=btrim(p_question_id) and route='fast_track' for update;
 if not found or not r.pending_failure_decision then return jsonb_build_object('ok',false,'reason','no-pending-fast-track-failure'); end if;
 if coalesce(p_add_targeted,false) then
   return english.route_to_targeted(uid,btrim(p_question_id),'Fast Track Failure','Learner approved Targeted Mastery after Fast Track miss');
 end if;
 if r.kept_failure_count>=1 then
   return english.route_to_targeted(uid,btrim(p_question_id),'Fast Track Failure','Repeated Fast Track miss requires Targeted Mastery');
 end if;
 update english.learning_route_state set
   pending_failure_decision=false,
   kept_failure_count=kept_failure_count+1,
   fast_track_status='waiting',
   next_fast_track_check=now()+interval '1 day',
   last_route_reason='One Fast Track miss kept; spaced confirmation required',
   updated_at=now()
 where user_id=uid and question_id=btrim(p_question_id);
 perform english.route_event(uid,btrim(p_question_id),'KEEP','fast_track','fast_track','Fast Track Failure','Learner kept one-off miss in Fast Track; spaced confirmation required','{}'::jsonb,null);
 return jsonb_build_object('ok',true,'route','fast_track','status','waiting','confirmationRequired',true,'nextCheck',now()+interval '1 day');
end $$;

create or replace function english.route_after_question_state_trigger()
returns trigger language plpgsql security definer
set search_path=pg_catalog,english,auth as $$
declare
 r english.learning_route_state%rowtype;
 reason text;
 d boolean:=false;
 clean_days integer:=0;
 wrong_after integer:=0;
 recovery_origin text;
begin
 if coalesce(new.mastered,false) then return new; end if;
 select * into r from english.learning_route_state where user_id=new.user_id and question_id=new.question_id;

 if found and r.route='targeted' and new.status in ('Strong','Proven Mastered') and coalesce(new.last_result,false) then
   select coalesce(difficult,false) into d from english.difficult_state where user_id=new.user_id and question_id=new.question_id;
   if not found then d:=false; end if;
   if not d and not english.route_has_active_star(new.user_id,new.question_id) then
     select
       count(distinct (a.attempted_at at time zone 'Asia/Kolkata')::date) filter(where coalesce(a.correct,false))::int,
       count(*) filter(where not coalesce(a.correct,false))::int
     into clean_days,wrong_after
     from english.attempts a
     where a.user_id=new.user_id and a.question_id=new.question_id
       and a.attempted_at>=coalesce(r.targeted_at,'epoch'::timestamptz);
     if clean_days>=2 and wrong_after=0 then
       recovery_origin:=english.route_recovery_origin(r.last_route_reason);
       perform english.route_to_fast_track(new.user_id,new.question_id,recovery_origin,'Targeted item recovered with spaced clean evidence',true);
       return new;
     end if;
   end if;
 end if;

 if coalesce(new.last_marked,false) and (r.question_id is null or r.route='fast_track' or r.route='unclassified') then
   insert into english.learning_route_state(user_id,question_id,route,fast_track_status,origins,baseline_wrong,last_route_reason,updated_at)
   values(new.user_id,new.question_id,'starred_unresolved',null,english.route_add_origin(coalesce(r.origins,'{}'::text[]),'From Starred'),coalesce(new.wrong,0),'Active Starred uncertainty',now())
   on conflict(user_id,question_id) do update set
     route='starred_unresolved',fast_track_status=null,
     origins=english.route_add_origin(english.learning_route_state.origins,'From Starred'),
     last_route_reason='Active Starred uncertainty',updated_at=now();
   if r.route='fast_track' then
     perform english.route_event(new.user_id,new.question_id,'ROUTE','fast_track','starred_unresolved','From Starred','Learner expressed uncertainty','{}'::jsonb,null);
   end if;
   return new;
 end if;

 reason:=english.route_targeted_reason(new.user_id,new.question_id);
 if nullif(reason,'') is not null then
   perform english.route_to_targeted(
     new.user_id,new.question_id,
     case when reason='Difficult' then 'Difficult' else 'Central Intelligence' end,
     reason
   );
 end if;
 return new;
end $$;

create or replace function public.english_get_fast_track_batch_session(p_count integer default 30,p_origin text default null,p_nonce text default null)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
select public.english_get_fast_track_batch(p_count,p_origin);
$$;

create or replace function public.english_get_route_view(
 p_route text,
 p_origin text default null,
 p_status text default null,
 p_category text default null,
 p_limit integer default 100,
 p_offset integer default 0
) returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), params as (
 select lower(btrim(coalesce(p_route,''))) route,
        nullif(btrim(coalesce(p_origin,'')),'') origin,
        nullif(lower(btrim(coalesce(p_status,''))),'') status,
        nullif(lower(btrim(coalesce(p_category,''))),'') category
), saved as (
 select distinct si.practice_question_id question_id
 from english.saved_items si cross join uid
 where si.user_id=uid.id and si.active and nullif(btrim(si.practice_question_id),'') is not null
), base as (
 select q.question_id,q.topic,english.learning_category(q.topic) category,
        r.route,r.fast_track_status,r.origins,r.entered_fast_track_at,r.next_fast_track_check,r.fast_track_mastered_at,r.last_route_reason,r.updated_at,
        coalesce(s.status,'New') learning_status,coalesce(s.mastered,false) mastered,coalesce(s.wrong,0) wrong,
        coalesce(d.difficult,false) difficult,
        case
          when p.route='fast_track' then lower(coalesce(r.fast_track_status,'ready'))
          when p.route='targeted' then lower(case when coalesce(d.difficult,false) then 'Difficult' else coalesce(s.status,'Learning') end)
          else 'unclassified'
        end view_status
 from english.questions q cross join uid cross join params p
 left join english.learning_route_state r on r.user_id=uid.id and r.question_id=q.question_id
 left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id
 left join english.difficult_state d on d.user_id=uid.id and d.question_id=q.question_id
 where uid.id is not null and q.active and (
   (p.route in ('fast_track','targeted') and r.route=p.route and english.route_origin_matches(r.origins,p.origin))
   or (p.route='unclassified' and q.question_id in (select question_id from saved)
       and (r.route is null or r.route in ('unclassified','starred_unresolved'))
       and (p.origin is null or p.origin='From My Saved'))
 )
), filtered as (
 select b.* from base b cross join params p
 where (p.status is null or b.view_status=p.status)
   and (p.category is null or lower(b.category)=p.category)
), statuses as (
 select view_status,count(*)::int n from base group by view_status order by n desc,view_status
), categories as (
 select category,count(*)::int n from base group by category order by n desc,category
), page as (
 select * from filtered order by
   case view_status when 'ready' then 1 when 'waiting' then 2 when 'persistent weak' then 3 when 'weak' then 4 when 'fragile' then 5 when 'difficult' then 6 when 'mastered' then 9 else 7 end,
   updated_at desc nulls last,question_id
 limit greatest(1,least(250,coalesce(p_limit,100))) offset greatest(0,coalesce(p_offset,0))
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'route',(select route from params),'origin',(select origin from params),
 'total',(select count(*) from base),'filteredTotal',(select count(*) from filtered),
 'statuses',coalesce((select jsonb_agg(jsonb_build_object('status',view_status,'count',n) order by n desc,view_status) from statuses),'[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('category',category,'count',n) order by n desc,category) from categories),'[]'::jsonb),
 'items',coalesce((select jsonb_agg(
   english.question_payload((select id from uid),p.question_id)||jsonb_build_object(
     'learningRoute',coalesce(p.route,'unclassified'),'viewStatus',p.view_status,'fastTrackStatus',p.fast_track_status,
     'fastTrackOrigins',coalesce(p.origins,'{}'::text[]),'fastTrackReason',p.last_route_reason,
     'fastTrackEnteredAt',p.entered_fast_track_at,'fastTrackNextCheck',p.next_fast_track_check,'fastTrackMasteredAt',p.fast_track_mastered_at,
     'learningStatus',p.learning_status,'wrong',p.wrong,'difficult',p.difficult,
     'routeHistory',coalesce((select jsonb_agg(jsonb_build_object('at',e.event_at,'type',e.event_type,'from',e.from_route,'to',e.to_route,'origin',e.origin,'reason',e.reason) order by e.event_at) from english.learning_route_events e where e.user_id=(select id from uid) and e.question_id=p.question_id),'[]'::jsonb)
   ) order by p.updated_at desc nulls last,p.question_id
 ) from page p),'[]'::jsonb)
) end;
$$;

create or replace function public.english_get_learning_route_overview()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), ft as (
 select r.*,(r.fast_track_status='ready' or (r.fast_track_status='waiting' and r.next_fast_track_check<=now())) ready_now
 from english.learning_route_state r cross join uid where r.user_id=uid.id and r.route='fast_track'
), origin_rows as (
 select english.route_origin_label(o) origin,f.fast_track_status,f.question_id
 from ft f cross join lateral unnest(f.origins) o
), origins as (
 select origin,count(distinct question_id)::int total,
   count(distinct question_id) filter(where fast_track_status='mastered')::int mastered,
   count(distinct question_id) filter(where fast_track_status<>'mastered')::int remaining
 from origin_rows where nullif(origin,'') is not null group by origin
), starhist as (
 select count(distinct question_id) filter(where to_route='fast_track' and origin='From Starred')::int moved_fast,
        count(distinct question_id) filter(where to_route='targeted' and origin='From Starred')::int moved_targeted
 from english.learning_route_events e cross join uid where e.user_id=uid.id
), saved as (
 select distinct si.practice_question_id question_id from english.saved_items si cross join uid
 where si.user_id=uid.id and si.active and nullif(btrim(si.practice_question_id),'') is not null
), savestats as (
 select count(*)::int total,
  count(*) filter(where r.route='fast_track')::int fast_track,
  count(*) filter(where r.route='fast_track' and r.fast_track_status='mastered')::int fast_mastered,
  count(*) filter(where r.route='fast_track' and r.fast_track_status<>'mastered')::int fast_remaining,
  count(*) filter(where r.route='targeted')::int targeted,
  count(*) filter(where r.route is null or r.route in ('unclassified','starred_unresolved'))::int unclassified
 from saved s left join english.learning_route_state r on r.user_id=(select id from uid) and r.question_id=s.question_id
), savedhist as (
 select count(distinct e.question_id) filter(where e.to_route='targeted')::int ever_targeted,
        count(distinct e.question_id) filter(where e.to_route='targeted' and exists(select 1 from english.learning_route_state r where r.user_id=e.user_id and r.question_id=e.question_id and r.route<>'targeted'))::int recovered
 from english.learning_route_events e join saved s on s.question_id=e.question_id cross join uid where e.user_id=uid.id
), active_star as (
 select count(*)::int n from english.question_state s cross join uid where s.user_id=uid.id and s.last_marked and not s.mastered
), targeted_first as (
 select e.question_id,min(e.event_at) targeted_at
 from english.learning_route_events e cross join uid where e.user_id=uid.id and e.to_route='targeted' group by e.question_id
), recovery as (
 select t.question_id,t.targeted_at,
   exists(select 1 from english.learning_route_events e cross join uid where e.user_id=uid.id and e.question_id=t.question_id and e.to_route='fast_track' and e.event_type='RECOVER' and e.event_at>=t.targeted_at+interval '7 days' and e.event_at<=t.targeted_at+interval '14 days') recovered_window
 from targeted_first t where t.targeted_at<=now()-interval '7 days'
), targeted_now as (
 select count(*)::int active from english.learning_route_state r cross join uid where r.user_id=uid.id and r.route='targeted'
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'fastTrack',jsonb_build_object(
   'total',(select count(*) from ft),
   'readyToVerify',(select count(*) from ft where ready_now and fast_track_status<>'mastered'),
   'waiting',(select count(*) from ft where fast_track_status='waiting' and not ready_now),
   'mastered',(select count(*) from ft where fast_track_status='mastered'),
   'remaining',(select count(*) from ft where fast_track_status<>'mastered'),
   'origins',coalesce((select jsonb_agg(jsonb_build_object('origin',origin,'total',total,'mastered',mastered,'remaining',remaining) order by case origin when 'Bank Coverage' then 1 when 'From Starred' then 2 when 'From My Saved' then 3 when 'Manual Fast Track' then 4 when 'Recovered Weak' then 5 when 'Recovered Persistent Weak' then 6 when 'Recovered Difficult' then 7 when 'Recovered Targeted' then 8 else 20 end,origin) from origins),'[]'::jsonb)
 ),
 'starred',jsonb_build_object(
   'active',(select n from active_star),'movedFastTrack',sh.moved_fast,'movedTargeted',sh.moved_targeted,
   'fastTrackMastered',(select count(*) from ft where 'From Starred'=any(origins) and fast_track_status='mastered'),
   'fastTrackRemaining',(select count(*) from ft where 'From Starred'=any(origins) and fast_track_status<>'mastered')
 ),
 'saved',jsonb_build_object(
   'total',ss.total,'fastTrack',ss.fast_track,'fastTrackMastered',ss.fast_mastered,'fastTrackRemaining',ss.fast_remaining,
   'targeted',ss.targeted,'everTargeted',coalesce(sh2.ever_targeted,0),'recoveredStable',coalesce(sh2.recovered,0),
   'stillLearning',ss.targeted,'unclassified',ss.unclassified
 ),
 'targeted',jsonb_build_object(
   'active',(select active from targeted_now),'eligible7Day',(select count(*) from recovery),
   'recovered7To14Day',(select count(*) from recovery where recovered_window),
   'recoveryRate',case when (select count(*) from recovery)>0 then round((select count(*) from recovery where recovered_window)*100.0/(select count(*) from recovery),1) else null end
 )
) end
from starhist sh cross join savestats ss cross join savedhist sh2;
$$;

create or replace function public.english_get_learning_route_bootstrap_reconciliation()
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
with uid as (select auth.uid() id), baseline as (
 select b.* from english.learning_route_bootstrap_baseline b cross join uid where b.user_id=uid.id
), relevant as (
 select s.question_id,s.mastered
 from english.question_state s join english.questions q on q.question_id=s.question_id and q.active cross join uid
 where s.user_id=uid.id and s.attempts>0 and (
   english.is_genuine_bank_question(q)
   or english.route_is_saved(uid.id,s.question_id)
   or exists(select 1 from english.star_events e where e.user_id=uid.id and e.question_id=s.question_id)
 )
), routed as (
 select r.question_id,r.route from english.learning_route_state r cross join uid where r.user_id=uid.id
), excluded as (
 select count(*)::int n
 from english.question_state s join english.questions q on q.question_id=s.question_id and q.active cross join uid
 where s.user_id=uid.id and s.attempts>0 and not (
   english.is_genuine_bank_question(q)
   or english.route_is_saved(uid.id,s.question_id)
   or exists(select 1 from english.star_events e where e.user_id=uid.id and e.question_id=s.question_id)
 )
), saved as (
 select distinct si.practice_question_id question_id from english.saved_items si cross join uid
 where si.user_id=uid.id and si.active and nullif(btrim(si.practice_question_id),'') is not null
), now_counts as (
 select
   (select count(*) from english.attempts a cross join uid where a.user_id=uid.id)::bigint attempts_count,
   (select count(*) from english.daily_current d cross join uid where d.user_id=uid.id)::bigint daily_rows,
   (select count(*) from english.star_events e cross join uid where e.user_id=uid.id)::bigint star_events_count,
   (select count(*) from english.saved_items s cross join uid where s.user_id=uid.id)::bigint saved_rows,
   (select count(*) from english.question_state s cross join uid where s.user_id=uid.id)::bigint question_state_rows,
   (select count(*) from english.questions q where q.active)::bigint active_questions,
   (select count(distinct q.question_id) from english.questions q where q.active)::bigint active_question_ids
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'totalEvaluated',(select count(*) from relevant),
 'fastTrackCandidates',(select count(*) from relevant x join routed r using(question_id) where not x.mastered and r.route='fast_track'),
 'targetedCandidates',(select count(*) from relevant x join routed r using(question_id) where not x.mastered and r.route='targeted'),
 'starredUnresolved',(select count(*) from relevant x join routed r using(question_id) where not x.mastered and r.route='starred_unresolved'),
 'insufficientEvidence',(select count(*) from relevant x left join routed r using(question_id) where not x.mastered and (r.route is null or r.route='unclassified')),
 'alreadyMastered',(select count(*) from relevant where mastered),
 'excludedCases',(select n from excluded),
 'savedClean',(select count(*) from saved s join english.learning_route_state r on r.user_id=(select id from uid) and r.question_id=s.question_id where r.route='fast_track'),
 'savedTargeted',(select count(*) from saved s join english.learning_route_state r on r.user_id=(select id from uid) and r.question_id=s.question_id where r.route='targeted'),
 'savedUnclassified',(select count(*) from saved s left join english.learning_route_state r on r.user_id=(select id from uid) and r.question_id=s.question_id where r.route is null or r.route in ('unclassified','starred_unresolved')),
 'invariants',jsonb_build_object(
   'baselineAvailable',exists(select 1 from baseline),
   'attemptsUnchanged',case when exists(select 1 from baseline) then (select attempts_count from baseline)=(select attempts_count from now_counts) else null end,
   'dailyHistoryUnchanged',case when exists(select 1 from baseline) then (select daily_rows from baseline)=(select daily_rows from now_counts) else null end,
   'savedRowsUnchanged',case when exists(select 1 from baseline) then (select saved_rows from baseline)=(select saved_rows from now_counts) else null end,
   'questionStateRowsUnchanged',case when exists(select 1 from baseline) then (select question_state_rows from baseline)=(select question_state_rows from now_counts) else null end,
   'starHistoryPreserved',case when exists(select 1 from baseline) then (select star_events_count from now_counts)>=(select star_events_count from baseline) else null end,
   'activeQuestionIdsUnique',(select active_questions from now_counts)=(select active_question_ids from now_counts),
   'baseline',coalesce((select jsonb_build_object('attempts',attempts_count,'dailyRows',daily_rows,'starEvents',star_events_count,'savedRows',saved_rows,'questionStateRows',question_state_rows,'activeQuestions',active_questions) from baseline),'{}'::jsonb),
   'current',(select jsonb_build_object('attempts',attempts_count,'dailyRows',daily_rows,'starEvents',star_events_count,'savedRows',saved_rows,'questionStateRows',question_state_rows,'activeQuestions',active_questions) from now_counts)
 )
) end;
$$;

revoke execute on function public.english_get_fast_track_batch_session(integer,text,text) from public,anon;
revoke execute on function public.english_get_route_view(text,text,text,text,integer,integer) from public,anon;
revoke execute on function public.english_get_learning_route_bootstrap_reconciliation() from public,anon;
grant execute on function public.english_get_fast_track_batch_session(integer,text,text) to authenticated,service_role;
grant execute on function public.english_get_route_view(text,text,text,text,integer,integer) to authenticated,service_role;
grant execute on function public.english_get_learning_route_bootstrap_reconciliation() to authenticated,service_role;
grant execute on function public.english_get_learning_route_overview() to authenticated,service_role;
grant execute on function public.english_resolve_fast_track_failure(text,boolean) to authenticated,service_role;

-- Follow-up hardening for the final-30-day learning-route layer.
-- Keep Targeted authoritative, but allow proven recovery before re-evaluating Targeted reason.

create or replace function english.route_event(
 p_user_id uuid,p_question_id text,p_event_type text,p_from text,p_to text,p_origin text,p_reason text,
 p_metadata jsonb default '{}'::jsonb,p_event_key text default null
) returns void language plpgsql security definer
set search_path=pg_catalog,english,auth as $$
begin
 insert into english.learning_route_events(user_id,question_id,event_type,from_route,to_route,origin,reason,metadata,event_key)
 values(p_user_id,p_question_id,p_event_type,p_from,p_to,nullif(btrim(coalesce(p_origin,'')),''),p_reason,coalesce(p_metadata,'{}'::jsonb),p_event_key)
 on conflict(event_key) do nothing;
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
begin
 if coalesce(new.mastered,false) then return new; end if;

 select * into r from english.learning_route_state where user_id=new.user_id and question_id=new.question_id;

 -- A Targeted item may recover only after independent spaced clean evidence.
 -- This check must happen before route_targeted_reason(), because an active Targeted route
 -- is itself a deliberate negative-routing signal until recovery is proven.
 if found and r.route='targeted' and new.status in ('Strong','Proven Mastered') and coalesce(new.last_result,false) then
   select coalesce(difficult,false) into d
   from english.difficult_state where user_id=new.user_id and question_id=new.question_id;
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
       perform english.route_to_fast_track(new.user_id,new.question_id,'Recovered Targeted','Targeted item recovered with spaced clean evidence',true);
       return new;
     end if;
   end if;
 end if;

 -- Starred is temporary unresolved uncertainty for otherwise non-Targeted material.
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

create or replace function public.english_get_question_route(p_question_id text)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,english,auth as $$
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
 else coalesce((
   select jsonb_build_object(
     'ok',true,'questionId',r.question_id,'route',r.route,'fastTrackStatus',r.fast_track_status,
     'origins',r.origins,'pendingFailureDecision',r.pending_failure_decision,
     'keptFailureCount',r.kept_failure_count,'reason',r.last_route_reason,
     'nextFastTrackCheck',r.next_fast_track_check,'updatedAt',r.updated_at
   ) from english.learning_route_state r
   where r.user_id=auth.uid() and r.question_id=btrim(p_question_id)
 ),jsonb_build_object('ok',true,'questionId',btrim(p_question_id),'route','unclassified')) end;
$$;

revoke execute on function public.english_get_question_route(text) from public,anon;
grant execute on function public.english_get_question_route(text) to authenticated,service_role;

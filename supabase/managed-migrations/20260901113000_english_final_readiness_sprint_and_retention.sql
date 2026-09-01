-- English V2 final readiness: Fast Track retention closure, route-aware central queues,
-- Sprint correctness, adaptive generation context, deterministic Sprint metadata, and AI usage audit.

-- ============================================================
-- 1. SPRINT AI USAGE LEDGER
-- ============================================================

create table if not exists english.sprint_ai_usage (
  id bigserial primary key,
  user_id uuid not null,
  session_id uuid null references english.sprint_sessions(session_id) on delete set null,
  request_group uuid not null,
  request_type text not null,
  mode text null,
  model text not null,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  reasoning_tokens integer not null default 0,
  total_tokens integer not null default 0,
  response_id text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists sprint_ai_usage_user_created_idx
  on english.sprint_ai_usage(user_id, created_at desc);
create index if not exists sprint_ai_usage_group_idx
  on english.sprint_ai_usage(user_id, request_group);

alter table english.sprint_ai_usage enable row level security;

drop policy if exists sprint_ai_usage_select_own on english.sprint_ai_usage;
create policy sprint_ai_usage_select_own on english.sprint_ai_usage
for select to authenticated
using (user_id=auth.uid());

revoke all on english.sprint_ai_usage from anon;
revoke insert, update, delete on english.sprint_ai_usage from authenticated;
grant select on english.sprint_ai_usage to authenticated;

create or replace function public.english_log_sprint_ai_usage(
  p_request_group uuid,
  p_request_type text,
  p_mode text,
  p_model text,
  p_input_tokens integer default 0,
  p_output_tokens integer default 0,
  p_reasoning_tokens integer default 0,
  p_total_tokens integer default 0,
  p_response_id text default null,
  p_session_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if p_session_id is not null and not exists(
    select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid
  ) then raise exception 'Sprint not found'; end if;

  insert into english.sprint_ai_usage(
    user_id,session_id,request_group,request_type,mode,model,
    input_tokens,output_tokens,reasoning_tokens,total_tokens,response_id,metadata
  ) values(
    uid,p_session_id,p_request_group,btrim(coalesce(p_request_type,'unknown')),
    nullif(btrim(coalesce(p_mode,'')),''),
    btrim(coalesce(p_model,'unknown')),
    greatest(0,coalesce(p_input_tokens,0)),
    greatest(0,coalesce(p_output_tokens,0)),
    greatest(0,coalesce(p_reasoning_tokens,0)),
    greatest(0,coalesce(p_total_tokens,0)),
    nullif(btrim(coalesce(p_response_id,'')),''),
    coalesce(p_metadata,'{}'::jsonb)
  );
  return jsonb_build_object('ok',true);
end
$function$;

create or replace function public.english_attach_sprint_ai_usage(
  p_request_group uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); n integer:=0;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=uid)
    then raise exception 'Sprint not found'; end if;
  update english.sprint_ai_usage
    set session_id=p_session_id
  where user_id=uid and request_group=p_request_group and session_id is null;
  get diagnostics n=row_count;
  return jsonb_build_object('ok',true,'attached',n);
end
$function$;

revoke all on function public.english_log_sprint_ai_usage(uuid,text,text,text,integer,integer,integer,integer,text,uuid,jsonb) from public,anon;
grant execute on function public.english_log_sprint_ai_usage(uuid,text,text,text,integer,integer,integer,integer,text,uuid,jsonb) to authenticated;
revoke all on function public.english_attach_sprint_ai_usage(uuid,uuid) from public,anon;
grant execute on function public.english_attach_sprint_ai_usage(uuid,uuid) to authenticated;

-- ============================================================
-- 2. FAST TRACK RETENTION WATCH
-- ============================================================

create or replace function english.route_after_attempt_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  q english.questions%rowtype;
  r english.learning_route_state%rowtype;
  d boolean:=false;
  ev record;
  lp record;
  v_module text:=lower(coalesce(new.module,''));
  v_attempts integer:=0;
  v_wrong integer:=0;
  v_ft_wrong integer:=0;
  v_ft_clean_days integer:=0;
  v_required integer:=1;
  v_saved boolean:=false;
  v_due timestamptz;
begin
  select * into q from english.questions where question_id=new.question_id;
  if not found or not q.active then return new; end if;

  select * into r from english.learning_route_state
  where user_id=new.user_id and question_id=new.question_id;

  select coalesce(ds.difficult,false) into d
  from english.difficult_state ds
  where ds.user_id=new.user_id and ds.question_id=new.question_id;
  if not found then d:=false; end if;

  v_saved:=english.route_is_saved(new.user_id,new.question_id);

  select count(*)::int,count(*) filter(where not coalesce(correct,false))::int
  into v_attempts,v_wrong
  from english.attempts
  where user_id=new.user_id and question_id=new.question_id;

  if v_module='fasttrack' and r.route='fast_track' then
    if coalesce(new.correct,false) then
      if r.fast_track_status='retention_watch' then
        select * into lp from english.learning_profile(new.user_id,new.question_id);
        if coalesce(lp.proven_mastery,false) then
          update english.learning_route_state set
            pending_failure_decision=false,
            fast_track_status='mastered',
            next_fast_track_check=null,
            fast_track_mastered_at=coalesce(fast_track_mastered_at,now()),
            last_route_reason='Retention confirmed — Proven Mastered',
            updated_at=now()
          where user_id=new.user_id and question_id=new.question_id;

          perform english.route_event(
            new.user_id,new.question_id,'RETENTION_CONFIRM','fast_track','fast_track',null,
            'Long-gap Fast Track recall confirmed Proven Mastered',
            jsonb_build_object('learningState',lp.state,'checkpointCount',lp.checkpoint_count),null
          );
        else
          v_due:=greatest(
            coalesce(lp.next_review,new.attempted_at+interval '5 days'),
            new.attempted_at+interval '5 days'
          );
          update english.learning_route_state set
            pending_failure_decision=false,
            fast_track_status='retention_watch',
            next_fast_track_check=v_due,
            fast_track_mastered_at=null,
            last_route_reason='Retention Watch — waiting for long-gap confirmation',
            updated_at=now()
          where user_id=new.user_id and question_id=new.question_id;

          perform english.route_event(
            new.user_id,new.question_id,'RETENTION_WAIT','fast_track','fast_track',null,
            'Clean retention check but Central Proven gap not yet satisfied',
            jsonb_build_object('learningState',lp.state,'nextCheck',v_due),null
          );
        end if;
        return new;
      end if;

      select count(distinct (a.attempted_at at time zone 'Asia/Kolkata')::date)::int
      into v_ft_clean_days
      from english.attempts a
      where a.user_id=new.user_id and a.question_id=new.question_id
        and lower(coalesce(a.module,''))='fasttrack'
        and coalesce(a.correct,false)
        and a.attempted_at>=coalesce(r.entered_fast_track_at,'epoch'::timestamptz);

      v_required:=case when exists(
        select 1 from unnest(coalesce(r.origins,'{}'::text[])) x
        where x like 'Recovered %'
      ) then 2 else 1 end;

      if v_ft_clean_days>=v_required then
        select * into lp from english.learning_profile(new.user_id,new.question_id);
        if coalesce(lp.proven_mastery,false) then
          update english.learning_route_state set
            pending_failure_decision=false,
            fast_track_status='mastered',
            next_fast_track_check=null,
            fast_track_mastered_at=coalesce(fast_track_mastered_at,now()),
            last_route_reason='Fast Track verified — Proven Mastered',
            updated_at=now()
          where user_id=new.user_id and question_id=new.question_id;
        else
          v_due:=greatest(
            coalesce(lp.next_review,new.attempted_at+interval '5 days'),
            new.attempted_at+interval '5 days'
          );
          update english.learning_route_state set
            pending_failure_decision=false,
            fast_track_status='retention_watch',
            next_fast_track_check=v_due,
            fast_track_mastered_at=null,
            last_route_reason='Fast Track cleared — Retention Watch',
            updated_at=now()
          where user_id=new.user_id and question_id=new.question_id;
        end if;

        perform english.route_event(
          new.user_id,new.question_id,'VERIFY','fast_track','fast_track',null,
          case when coalesce(lp.proven_mastery,false)
            then 'Fast Track verification complete — Proven Mastered'
            else 'Fast Track verification complete — moved to Retention Watch' end,
          jsonb_build_object(
            'cleanDays',v_ft_clean_days,'required',v_required,
            'learningState',lp.state,'provenMastery',coalesce(lp.proven_mastery,false),
            'nextCheck',case when coalesce(lp.proven_mastery,false) then null else v_due end
          ),null
        );
      else
        update english.learning_route_state set
          pending_failure_decision=false,
          fast_track_status='waiting',
          next_fast_track_check=now()+interval '2 days',
          last_route_reason='Waiting for spaced Fast Track check',
          updated_at=now()
        where user_id=new.user_id and question_id=new.question_id;

        perform english.route_event(
          new.user_id,new.question_id,'VERIFY','fast_track','fast_track',null,
          'Clean Fast Track recall — more verification required',
          jsonb_build_object('cleanDays',v_ft_clean_days,'required',v_required),null
        );
      end if;
    else
      if r.fast_track_status='retention_watch' then
        perform english.route_event(
          new.user_id,new.question_id,'RETENTION_FAIL','fast_track','targeted',
          'Fast Track Retention','Long-gap retention check failed',
          jsonb_build_object('attemptedAt',new.attempted_at),null
        );
        perform english.route_to_targeted(
          new.user_id,new.question_id,'Fast Track Retention',
          'Retention Watch failed — relearning required'
        );
        return new;
      end if;

      select count(*)::int into v_ft_wrong
      from english.attempts a
      where a.user_id=new.user_id and a.question_id=new.question_id
        and lower(coalesce(a.module,''))='fasttrack'
        and not coalesce(a.correct,false)
        and a.attempted_at>=coalesce(r.entered_fast_track_at,'epoch'::timestamptz);

      update english.learning_route_state set last_failure_at=now(),updated_at=now()
      where user_id=new.user_id and question_id=new.question_id;

      perform english.route_event(
        new.user_id,new.question_id,'FAIL','fast_track','fast_track',null,
        'Fast Track recall missed',jsonb_build_object('failureCount',v_ft_wrong),null
      );

      if v_ft_wrong>=2 then
        perform english.route_to_targeted(
          new.user_id,new.question_id,'Fast Track Failure','Repeated Fast Track failure'
        );
      else
        update english.learning_route_state set
          pending_failure_decision=true,
          fast_track_status='ready',
          next_fast_track_check=null,
          last_route_reason='Fast Track failure needs learner decision',
          updated_at=now()
        where user_id=new.user_id and question_id=new.question_id;
      end if;
    end if;
    return new;
  end if;

  if not coalesce(new.correct,false) then
    if r.route='fast_track' then
      perform english.route_to_targeted(
        new.user_id,new.question_id,'Fast Track',
        'Negative evidence outside Fast Track verification'
      );
    elsif v_saved then
      perform english.route_to_targeted(
        new.user_id,new.question_id,'From My Saved','Saved-item recall failed'
      );
    elsif v_module='bankcoverage' then
      perform english.route_to_targeted(
        new.user_id,new.question_id,'Bank Coverage','Bank Coverage discovery failed'
      );
    end if;
    return new;
  end if;

  if v_module='bankcoverage' and v_attempts=1 and v_wrong=0
     and english.is_genuine_bank_question(q) and not d then
    perform english.route_to_fast_track(
      new.user_id,new.question_id,'Bank Coverage',
      'First-time clean Bank Coverage discovery',false
    );
    return new;
  end if;

  if r.route is distinct from 'fast_track' and not d then
    select * into ev from english.fast_track_evidence(new.user_id,new.question_id);
    if coalesce(ev.eligible,false) then
      perform english.route_to_fast_track(
        new.user_id,new.question_id,'Global Evidence',
        '10 spaced checkpoints, >=80% accuracy and last 4 clean',false
      );
    end if;
  end if;

  return new;
end
$function$;

-- Retrospectively close the old terminal gap without putting items back into
-- Daily/Revision. Non-Proven Fast Track "mastered" rows become route-owned
-- Retention Watch items.
do $retention_reconcile$
declare x record; lp record; v_due timestamptz;
begin
  for x in
    select r.user_id,r.question_id
    from english.learning_route_state r
    where r.route='fast_track' and r.fast_track_status='mastered'
  loop
    select * into lp from english.learning_profile(x.user_id,x.question_id);
    if not coalesce(lp.proven_mastery,false) then
      v_due:=greatest(
        coalesce(lp.next_review,coalesce(lp.last_attempt,now())+interval '5 days'),
        coalesce(lp.last_attempt,now())+interval '5 days'
      );
      update english.learning_route_state set
        fast_track_status='retention_watch',
        next_fast_track_check=v_due,
        fast_track_mastered_at=null,
        pending_failure_decision=false,
        last_route_reason='Retrospective Retention Watch — Central Proven not yet confirmed',
        updated_at=now()
      where user_id=x.user_id and question_id=x.question_id;

      perform english.route_event(
        x.user_id,x.question_id,'RECONCILE','fast_track','fast_track',
        'Retention Watch','Fast Track cleared before Central Proven; scheduled long-gap check',
        jsonb_build_object('learningState',lp.state,'nextCheck',v_due),
        'retention-watch-v1:'||x.user_id::text||':'||x.question_id
      );
    end if;
  end loop;
end
$retention_reconcile$;

create or replace function public.english_get_fast_track_batch(
  p_count integer default 30,
  p_origin text default null
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with r as (
 select x.*,
   case
     when x.fast_track_status='retention_watch' then 0
     when x.fast_track_status='ready' then 1
     else 2
   end wait_ord
 from english.learning_route_state x
 where x.user_id=auth.uid()
   and x.route='fast_track'
   and x.fast_track_status<>'mastered'
   and (
     x.fast_track_status='ready'
     or (x.fast_track_status in ('waiting','retention_watch') and x.next_fast_track_check<=now())
   )
   and (p_origin is null or p_origin=any(x.origins))
   and nullif(english.route_targeted_reason(auth.uid(),x.question_id),'') is null
 order by wait_ord,x.next_fast_track_check nulls first,x.updated_at,x.question_id
 limit greatest(1,least(100,coalesce(p_count,30)))
)
select coalesce(jsonb_agg(
  english.question_payload(auth.uid(),r.question_id)||jsonb_build_object(
   'fastTrack',true,
   'fastTrackStatus',r.fast_track_status,
   'fastTrackOrigins',r.origins,
   'fastTrackReason',r.last_route_reason,
   'fastTrackNextCheck',r.next_fast_track_check,
   'fastTrackFailureDecision',r.pending_failure_decision,
   'retentionWatch',(r.fast_track_status='retention_watch')
  )
  order by r.wait_ord,r.next_fast_track_check nulls first,r.question_id
),'[]'::jsonb)
from r;
$function$;

create or replace function public.english_get_learning_route_overview()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as (select auth.uid() id),
ft as (
 select r.*,
   (
     r.fast_track_status='ready'
     or (r.fast_track_status in ('waiting','retention_watch') and r.next_fast_track_check<=now())
   ) ready_now
 from english.learning_route_state r cross join uid
 where r.user_id=uid.id and r.route='fast_track'
),
origin_rows as (
 select english.route_origin_label(o) origin,f.fast_track_status,f.question_id
 from ft f cross join lateral unnest(f.origins) o
),
origins as (
 select origin,count(distinct question_id)::int total,
   count(distinct question_id) filter(where fast_track_status='mastered')::int mastered,
   count(distinct question_id) filter(where fast_track_status='retention_watch')::int retention_watch,
   count(distinct question_id) filter(where fast_track_status<>'mastered')::int remaining
 from origin_rows where nullif(origin,'') is not null group by origin
),
starhist as (
 select count(distinct question_id) filter(where to_route='fast_track' and origin='From Starred')::int moved_fast,
        count(distinct question_id) filter(where to_route='targeted' and origin='From Starred')::int moved_targeted
 from english.learning_route_events e cross join uid where e.user_id=uid.id
),
saved as (
 select distinct si.practice_question_id question_id from english.saved_items si cross join uid
 where si.user_id=uid.id and si.active and nullif(btrim(si.practice_question_id),'') is not null
),
savestats as (
 select count(*)::int total,
  count(*) filter(where r.route='fast_track')::int fast_track,
  count(*) filter(where r.route='fast_track' and r.fast_track_status='mastered')::int fast_mastered,
  count(*) filter(where r.route='fast_track' and r.fast_track_status='retention_watch')::int retention_watch,
  count(*) filter(where r.route='fast_track' and r.fast_track_status<>'mastered')::int fast_remaining,
  count(*) filter(where r.route='targeted')::int targeted,
  count(*) filter(where r.route is null or r.route in ('unclassified','starred_unresolved'))::int unclassified
 from saved s
 left join english.learning_route_state r
   on r.user_id=(select id from uid) and r.question_id=s.question_id
),
savedhist as (
 select count(distinct e.question_id) filter(where e.to_route='targeted')::int ever_targeted,
        count(distinct e.question_id) filter(
          where e.to_route='targeted'
            and exists(
              select 1 from english.learning_route_state r
              where r.user_id=e.user_id and r.question_id=e.question_id and r.route<>'targeted'
            )
        )::int recovered
 from english.learning_route_events e
 join saved s on s.question_id=e.question_id
 cross join uid
 where e.user_id=uid.id
),
active_star as (
 select count(*)::int n from english.question_state s cross join uid
 where s.user_id=uid.id and s.last_marked and not s.mastered
),
targeted_first as (
 select e.question_id,min(e.event_at) targeted_at
 from english.learning_route_events e cross join uid
 where e.user_id=uid.id and e.to_route='targeted'
 group by e.question_id
),
recovery as (
 select t.question_id,t.targeted_at,
   exists(
     select 1 from english.learning_route_events e cross join uid
     where e.user_id=uid.id and e.question_id=t.question_id
       and e.to_route='fast_track' and e.event_type='RECOVER'
       and e.event_at>=t.targeted_at+interval '7 days'
       and e.event_at<=t.targeted_at+interval '14 days'
   ) recovered_window
 from targeted_first t
 where t.targeted_at<=now()-interval '7 days'
),
targeted_now as (
 select count(*)::int active from english.learning_route_state r cross join uid
 where r.user_id=uid.id and r.route='targeted'
)
select case
 when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
  'ok',true,
  'fastTrack',jsonb_build_object(
    'total',(select count(*) from ft),
    'readyToVerify',(select count(*) from ft where ready_now and fast_track_status<>'mastered'),
    'waiting',(select count(*) from ft where fast_track_status='waiting' and not ready_now),
    'retentionWatch',(select count(*) from ft where fast_track_status='retention_watch'),
    'retentionDue',(select count(*) from ft where fast_track_status='retention_watch' and ready_now),
    'mastered',(select count(*) from ft where fast_track_status='mastered'),
    'remaining',(select count(*) from ft where fast_track_status<>'mastered'),
    'origins',coalesce((
      select jsonb_agg(jsonb_build_object(
        'origin',origin,'total',total,'mastered',mastered,
        'retentionWatch',retention_watch,'remaining',remaining
      ) order by case origin
        when 'Bank Coverage' then 1
        when 'From Starred' then 2
        when 'From My Saved' then 3
        when 'Manual Fast Track' then 4
        when 'Recovered Weak' then 5
        when 'Recovered Persistent Weak' then 6
        when 'Recovered Difficult' then 7
        when 'Recovered Targeted' then 8 else 20 end,origin)
      from origins
    ),'[]'::jsonb)
  ),
  'starred',jsonb_build_object(
    'active',(select n from active_star),
    'movedFastTrack',sh.moved_fast,
    'movedTargeted',sh.moved_targeted,
    'fastTrackMastered',(select count(*) from ft where 'From Starred'=any(origins) and fast_track_status='mastered'),
    'fastTrackRemaining',(select count(*) from ft where 'From Starred'=any(origins) and fast_track_status<>'mastered')
  ),
  'saved',jsonb_build_object(
    'total',ss.total,'fastTrack',ss.fast_track,
    'fastTrackMastered',ss.fast_mastered,
    'retentionWatch',ss.retention_watch,
    'fastTrackRemaining',ss.fast_remaining,
    'targeted',ss.targeted,
    'everTargeted',coalesce(sh2.ever_targeted,0),
    'recoveredStable',coalesce(sh2.recovered,0),
    'stillLearning',ss.targeted,
    'unclassified',ss.unclassified
  ),
  'targeted',jsonb_build_object(
    'active',(select active from targeted_now),
    'eligible7Day',(select count(*) from recovery),
    'recovered7To14Day',(select count(*) from recovery where recovered_window),
    'recoveryRate',case
      when (select count(*) from recovery)>0
      then round((select count(*) from recovery where recovered_window)*100.0/(select count(*) from recovery),1)
      else null end
  )
 )
end
from starhist sh cross join savestats ss cross join savedhist sh2;
$function$;

-- ============================================================
-- 3. ROUTE-AWARE CENTRAL DUE COUNTERS
-- ============================================================

create or replace function public.english_get_central_intelligence()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as (select auth.uid() id),
q as (
 select qs.question_id,qs.status,qs.attempts,qs.wrong,qs.next_review,qs.mastered,qs.last_marked,
        coalesce(d.difficult,false) difficult,
        exists(
          select 1 from english.learning_route_state r
          where r.user_id=uid.id and r.question_id=qs.question_id and r.route='fast_track'
        ) fast_track,
        (
          qs.next_review is not null
          and qs.next_review<=(((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')
        ) due
 from english.question_state qs cross join uid
 left join english.difficult_state d on d.user_id=uid.id and d.question_id=qs.question_id
 where qs.user_id=uid.id
),
queues as (
 select
   count(*) filter(where not mastered and not fast_track and status='Persistent Weak')::int persistent_weak,
   count(*) filter(where not mastered and not fast_track and status='Weak')::int weak,
   count(*) filter(where not mastered and not fast_track and status='Fragile')::int fragile,
   count(*) filter(where not mastered and attempts>0 and due)::int raw_due,
   count(*) filter(where not mastered and not fast_track and attempts>0 and due)::int due,
   count(*) filter(where not mastered and fast_track and attempts>0 and due)::int fast_track_due,
   count(*) filter(where not mastered and not fast_track and difficult)::int difficult,
   count(*) filter(where not mastered and last_marked)::int starred,
   count(*) filter(where not mastered and not fast_track and status='Learning')::int learning,
   count(*) filter(where not mastered and not fast_track and status='Strong')::int strong,
   count(*) filter(where not mastered and status='Proven Mastered')::int proven_mastered,
   count(*) filter(where mastered)::int manual_mastered
 from q
),
daily as (
 select count(*)::int stored,
        count(*) filter(where lower(coalesce(status,''))='completed')::int completed
 from english.daily_current cross join uid where user_id=uid.id
),
daily_current as (
 select count(*) filter(where lower(coalesce(status,''))<>'completed')::int remaining
 from uid cross join lateral english.current_daily_items(uid.id)
),
core as (
 select count(*)::int total,
        count(*) filter(where coalesce(s.attempts,0)>0)::int exposed
 from english.questions x cross join uid
 left join english.question_state s on s.user_id=uid.id and s.question_id=x.question_id
 where english.is_genuine_bank_question(x)
),
penalties as (
 select category,penalty,seen_count,weak_count,first_attempt_accuracy,retention_accuracy,
        row_number() over(order by penalty desc,category)::int rn
 from uid cross join lateral english.daily_category_penalties(uid.id)
),
recommendation as (
 select case
   when dc.remaining>0
     then jsonb_build_object('route','daily','mode','resume','count',dc.remaining,'reason','Finish the current actionable Daily queue')
   when qu.persistent_weak>0
     then jsonb_build_object('route','revision','mode','smart','count',least(30,qu.persistent_weak+qu.weak+qu.fragile+qu.due),'reason','Persistent Weak items need priority recall')
   when qu.weak+qu.fragile>0
     then jsonb_build_object('route','revision','mode','smart','count',least(30,qu.weak+qu.fragile+qu.due),'reason','Weak and Fragile retention needs attention')
   when qu.due>0
     then jsonb_build_object('route','revision','mode','due','count',least(30,qu.due),'reason','Spaced reviews are due')
   when qu.difficult>0
     then jsonb_build_object('route','revision','mode','difficult','count',least(30,qu.difficult),'reason','No due backlog; revisit Difficult items')
   when c.exposed<c.total
     then jsonb_build_object('route','bankCoverage','mode','unseen','count',least(20,c.total-c.exposed),'reason','No urgent retention backlog; expand core-bank exposure')
   else jsonb_build_object('route','revision','mode','recall','count',20,'reason','All urgent queues are clear; maintain recall rotation')
 end value
 from queues qu cross join daily_current dc cross join core c
)
select case
 when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
  'ok',true,'version',2,'generatedAt',now(),
  'queues',jsonb_build_object(
    'persistentWeak',qu.persistent_weak,'weak',qu.weak,'fragile',qu.fragile,
    'due',qu.due,'actionableDue',qu.due,'rawDue',qu.raw_due,'fastTrackDue',qu.fast_track_due,
    'difficult',qu.difficult,'starred',qu.starred,'learning',qu.learning,'strong',qu.strong,
    'provenMastered',qu.proven_mastered,'manualMastered',qu.manual_mastered
  ),
  'daily',jsonb_build_object(
    'stored',d.stored,'completed',d.completed,'actionableRemaining',dc.remaining,
    'suppressed',greatest(0,d.stored-d.completed-dc.remaining),'targetIsMaximum',true
  ),
  'coreCoverage',jsonb_build_object(
    'total',c.total,'exposed',c.exposed,'left',greatest(0,c.total-c.exposed),
    'percent',case when c.total>0 then round(c.exposed*100.0/c.total,1) else 0 end
  ),
  'categoryPriorities',coalesce((
    select jsonb_agg(jsonb_build_object(
      'category',p.category,'penalty',round(p.penalty,4),'seen',p.seen_count,'weak',p.weak_count,
      'firstAttemptAccuracy',p.first_attempt_accuracy,'retentionAccuracy',p.retention_accuracy
    ) order by p.rn)
    from penalties p where p.rn<=5
  ),'[]'::jsonb),
  'recommended',(select value from recommendation)
 )
end
from queues qu cross join daily d cross join daily_current dc cross join core c;
$function$;

-- ============================================================
-- 4. SPRINT CORRECTNESS: VISITED + WRONG != UNANSWERED
-- ============================================================

create or replace function public.english_finish_sprint(
  p_session_id uuid,
  p_answers jsonb,
  p_duration_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
 uid uuid:=auth.uid();
 s english.sprint_sessions%rowtype;
 i record;
 a jsonb;
 selected text;
 t numeric;
 v_correct integer:=0;
 v_wrong integer:=0;
 v_unanswered integer:=0;
 v_score numeric:=0;
 v_accuracy numeric:=0;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into s from english.sprint_sessions
 where session_id=p_session_id and user_id=uid for update;
 if not found then raise exception 'Sprint not found'; end if;
 if s.status='completed' then return public.english_get_sprint_session(p_session_id); end if;
 if jsonb_typeof(coalesce(p_answers,'[]'::jsonb))<>'array' then raise exception 'Answers must be an array'; end if;

 for i in select * from english.sprint_items where session_id=p_session_id order by position loop
   select value into a
   from jsonb_array_elements(p_answers) value
   where coalesce((value->>'position')::integer,0)=i.position
   limit 1;

   selected:=upper(coalesce(a->>'selectedKey',''));
   t:=least(900,greatest(0,coalesce((a->>'timeSeconds')::numeric,0)));

   if selected not in ('A','B','C','D') then
     selected:=null; v_unanswered:=v_unanswered+1;
   elsif selected=i.correct_key then
     v_correct:=v_correct+1;
   else
     v_wrong:=v_wrong+1;
   end if;

   insert into english.sprint_answers(
     session_id,position,user_id,selected_key,correct,time_seconds,visited,updated_at
   ) values(
     p_session_id,i.position,uid,selected,coalesce(selected=i.correct_key,false),t,
     selected is not null,now()
   )
   on conflict(session_id,position) do update set
     selected_key=excluded.selected_key,
     correct=excluded.correct,
     time_seconds=excluded.time_seconds,
     visited=english.sprint_answers.visited or excluded.visited,
     updated_at=now();
 end loop;

 v_score:=v_correct*2-v_wrong*.5;
 v_accuracy:=case when v_correct+v_wrong>0 then round(v_correct*100.0/(v_correct+v_wrong),1) else 0 end;

 update english.sprint_sessions set
   status='completed',completed_at=now(),
   duration_seconds=least(900,greatest(0,coalesce(p_duration_seconds,0))),
   score=v_score,correct_count=v_correct,wrong_count=v_wrong,
   unanswered_count=v_unanswered,accuracy=v_accuracy
 where session_id=p_session_id and user_id=uid;

 update english.learning_route_state r set
   metadata=jsonb_set(
     coalesce(r.metadata,'{}'::jsonb),'{sprintCorrectEvidence}',
     to_jsonb(coalesce((r.metadata->>'sprintCorrectEvidence')::int,0)+1),true
   ),updated_at=now()
 from english.sprint_items si
 join english.sprint_answers sa
   on sa.session_id=si.session_id and sa.position=si.position
 where si.session_id=p_session_id
   and sa.selected_key is not null
   and sa.correct
   and si.canonical_question_id is not null
   and r.user_id=uid and r.question_id=si.canonical_question_id;

 return public.english_get_sprint_session(p_session_id);
end
$function$;

create or replace function public.english_get_sprint_analysis_context(p_session_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with s as (
  select * from english.sprint_sessions
  where session_id=p_session_id and user_id=auth.uid() and status='completed'
),
w as (
 select i.position,i.category,i.question_type,i.question,i.options,i.correct_key,
        i.explanation,i.source_type,i.canonical_question_id,a.selected_key,
   case when i.canonical_question_id is null then null else (
     select r.route from english.learning_route_state r
     where r.user_id=auth.uid() and r.question_id=i.canonical_question_id
   ) end route,
   case when i.canonical_question_id is null then null else (
     select qs.status from english.question_state qs
     where qs.user_id=auth.uid() and qs.question_id=i.canonical_question_id
   ) end learning_state
 from english.sprint_items i
 join english.sprint_answers a
   on a.session_id=i.session_id and a.position=i.position
 join s on s.session_id=i.session_id
 where a.selected_key is not null and not a.correct
)
select case
 when not exists(select 1 from s)
   then jsonb_build_object('ok',false,'error','Completed Sprint not found')
 else jsonb_build_object(
  'ok',true,'sessionId',p_session_id,
  'score',(select score from s),
  'durationSeconds',(select duration_seconds from s),
  'wrongItems',coalesce((
    select jsonb_agg(jsonb_build_object(
      'position',position,'category',category,'questionType',question_type,
      'question',question,'options',options,'selectedKey',selected_key,
      'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,
      'canonicalQuestionId',canonical_question_id,'route',route,'learningState',learning_state
    ) order by position)
    from w
  ),'[]'::jsonb),
  'diagnosisLabels',jsonb_build_array(
    'Knowledge Gap','Confusion','Rule Gap','Careless','Time Pressure','Misread','Distractor Trap'
  ),
  'actions',jsonb_build_array(
    'Targeted Mastery','Weakness Drill','Trap Practice','Execution Review','No Route Change'
  )
 )
end;
$function$;

-- ============================================================
-- 5. ADAPTIVE SPRINT GENERATION CONTEXT
-- ============================================================

create or replace function public.english_get_sprint_generation_context(p_mode text default 'standard')
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as (select auth.uid() id),
mode as (select lower(coalesce(p_mode,'standard')) m),
pen as (
 select category,penalty,seen_count,weak_count,first_attempt_accuracy,retention_accuracy,
        row_number() over(order by penalty desc,category) rn
 from uid cross join lateral english.daily_category_penalties(uid.id)
),
targeted as (
 select q.question_id,english.learning_category(q.topic) category,q.question,
        q.option_a,q.option_b,q.option_c,q.option_d,upper(q.correct) correct_key,
        q.explanation,q.question_type,
        coalesce(s.status,'New') state,coalesce(s.wrong,0) wrong,
        coalesce(d.difficult,false) difficult,
        row_number() over(order by
          case coalesce(s.status,'New')
            when 'Persistent Weak' then 7 when 'Weak' then 6 when 'Fragile' then 5 else 2 end desc,
          coalesce(s.wrong,0) desc,q.question_id
        ) rn
 from english.questions q cross join uid
 left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id
 left join english.difficult_state d on d.user_id=uid.id and d.question_id=q.question_id
 left join english.learning_route_state r on r.user_id=uid.id and r.question_id=q.question_id
 where q.active and not coalesce(s.mastered,false)
   and (r.route='targeted' or s.status in ('Persistent Weak','Weak','Fragile') or coalesce(d.difficult,false))
),
traps as (
 select coalesce(nullif(confused_with,''),diagnosis) trap,count(*)::int n,max(created_at) last_at
 from english.sprint_answers a cross join uid
 where a.user_id=uid.id
   and a.selected_key is not null
   and nullif(coalesce(confused_with,diagnosis),'') is not null
 group by 1
 order by n desc,last_at desc
 limit 8
),
previous as (
 select i.category,i.question_type,i.question,i.options,i.correct_key,i.explanation,
        i.canonical_question_id,a.diagnosis,a.confused_with,
        i.metadata->>'conceptKey' concept_key,s.completed_at,
        row_number() over(order by s.completed_at desc,i.position) rn
 from english.sprint_answers a
 join english.sprint_items i on i.session_id=a.session_id and i.position=a.position
 join english.sprint_sessions s on s.session_id=a.session_id
 cross join uid
 where a.user_id=uid.id
   and a.selected_key is not null
   and not a.correct
   and s.status='completed'
),
standard_hist as (
 select s.*,
        row_number() over(order by s.completed_at desc,s.session_id desc) rn,
        case when s.question_count>0 and coalesce(s.duration_seconds,0)>0
          then s.duration_seconds::numeric/s.question_count else null end sec_per_q
 from english.sprint_sessions s cross join uid
 where s.user_id=uid.id and s.status='completed' and s.mode='standard'
),
recent_standard as (select * from standard_hist where rn<=5),
standard_stats as (
 select
   count(*)::int sample_count,
   max(score) filter(where rn=1) last_score,
   max(accuracy) filter(where rn=1) last_accuracy,
   max(sec_per_q) filter(where rn=1) last_sec_per_q,
   round(avg(score),2) avg_score,
   round(avg(accuracy),1) avg_accuracy,
   round(avg(sec_per_q),1) avg_sec_per_q
 from recent_standard
),
streak as (
 select case
   when not exists(select 1 from standard_hist) then 0
   else coalesce(
     (select min(rn)-1 from standard_hist where score<45),
     (select count(*) from standard_hist)
   )::int
 end n
),
difficulty_level as (
 select case
   when ss.sample_count>=3 and coalesce(ss.avg_score,0)>=46
        and coalesce(ss.avg_accuracy,0)>=92 and coalesce(ss.avg_sec_per_q,999)<=20
        and (select n from streak)>=2 then 'high'
   when ss.sample_count>=2 and coalesce(ss.avg_score,0)>=45
        and coalesce(ss.avg_accuracy,0)>=90 and coalesce(ss.avg_sec_per_q,999)<=25 then 'elevated'
   else 'base'
 end level
 from standard_stats ss
),
difficulty_counts as (
 select case (select level from difficulty_level)
   when 'high' then 3 else case when (select level from difficulty_level)='elevated' then 4 else 5 end end easy,
   case (select level from difficulty_level)
   when 'high' then 11 else case when (select level from difficulty_level)='elevated' then 12 else 13 end end moderate,
   case (select level from difficulty_level)
   when 'high' then 11 else case when (select level from difficulty_level)='elevated' then 9 else 7 end end hard
),
today_concept as (
 select concept_key,correct,time_seconds,completed_at,
        row_number() over(partition by concept_key order by completed_at desc,position desc) rn
 from (
   select nullif(btrim(i.metadata->>'conceptKey'),'') concept_key,
          a.correct,a.time_seconds,s.completed_at,i.position
   from english.sprint_sessions s
   join english.sprint_items i on i.session_id=s.session_id
   join english.sprint_answers a
     on a.session_id=i.session_id and a.position=i.position and a.user_id=s.user_id
   cross join uid
   where s.user_id=uid.id and s.status='completed'
     and s.completed_at>=(((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata')
     and a.selected_key is not null
     and nullif(btrim(i.metadata->>'conceptKey'),'') is not null
 ) x
),
cooldown as (
 select concept_key from today_concept
 where rn=1 and correct and coalesce(time_seconds,0)>0 and time_seconds<=20
),
slow_correct as (
 select i.category,i.question_type,i.question,i.metadata->>'conceptKey' concept_key,
        a.time_seconds,s.completed_at,
        row_number() over(order by s.completed_at desc,a.time_seconds desc) rn
 from english.sprint_sessions s
 join english.sprint_items i on i.session_id=s.session_id
 join english.sprint_answers a
   on a.session_id=i.session_id and a.position=i.position and a.user_id=s.user_id
 cross join uid
 where s.user_id=uid.id and s.status='completed'
   and a.selected_key is not null and a.correct and a.time_seconds>=25
   and s.completed_at>=now()-interval '14 days'
)
select case
 when (select id from uid) is null
   then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
  'ok',true,
  'mode',(select m from mode),
  'count',english.sprint_expected_count((select m from mode)),
  'rules',jsonb_build_object(
    'minutes',15,'marks',50,'correctMarks',2,'wrongMarks',-.5,'readingComprehension',false,
    'exactlyOneDefensibleAnswer',true,'sameDayFastCorrectCooldown',true
  ),
  'blueprint',case (select m from mode)
    when 'standard' then jsonb_build_object(
      'balanced',17,'weakness',4,'freshChallenge',4,
      'guidance','68% exam-balanced coverage, 16% weakness transfer, 16% fresh challenge',
      'difficulty',jsonb_build_object(
        'level',(select level from difficulty_level),
        'easy',(select easy from difficulty_counts),
        'moderate',(select moderate from difficulty_counts),
        'hard',(select hard from difficulty_counts)
      ),
      'questionMix',jsonb_build_object('grammarTransformation',11,'lexicalUsage',14)
    )
    when 'weakness' then jsonb_build_object(
      'weakness',12,'transfer',3,
      'guidance','Fresh variants around genuine weaknesses; no verbatim replay',
      'difficulty',jsonb_build_object('easy',2,'moderate',8,'hard',5)
    )
    when 'trap' then jsonb_build_object(
      'trap',12,'transfer',3,
      'guidance','Adversarial close distractors around recurring traps',
      'difficulty',jsonb_build_object('easy',1,'moderate',7,'hard',7)
    )
    else jsonb_build_object(
      'previousMistakes',8,'transfer',2,
      'guidance','Fresh variants of genuine previous Sprint mistakes',
      'difficulty',jsonb_build_object('easy',2,'moderate',5,'hard',3)
    )
  end,
  'recentStandardPerformance',jsonb_build_object(
    'sampleCount',(select sample_count from standard_stats),
    'lastScore',(select last_score from standard_stats),
    'lastAccuracy',(select last_accuracy from standard_stats),
    'lastSecondsPerQuestion',(select round(last_sec_per_q,1) from standard_stats),
    'fiveSprintAverage',(select avg_score from standard_stats),
    'fiveSprintAccuracy',(select avg_accuracy from standard_stats),
    'fiveSprintSecondsPerQuestion',(select avg_sec_per_q from standard_stats),
    'goalStreak',(select n from streak),
    'difficultyLevel',(select level from difficulty_level)
  ),
  'weakCategories',coalesce((
    select jsonb_agg(jsonb_build_object(
      'category',category,'penalty',round(penalty,4),'seen',seen_count,'weak',weak_count,
      'firstAttemptAccuracy',first_attempt_accuracy,'retentionAccuracy',retention_accuracy
    ) order by rn) from pen where rn<=6
  ),'[]'::jsonb),
  'targetedSeeds',coalesce((
    select jsonb_agg(jsonb_build_object(
      'canonicalQuestionId',question_id,'category',category,'question',question,
      'options',jsonb_build_array(
        jsonb_build_object('key','A','text',option_a),
        jsonb_build_object('key','B','text',option_b),
        jsonb_build_object('key','C','text',option_c),
        jsonb_build_object('key','D','text',option_d)
      ),
      'correctKey',correct_key,'explanation',explanation,'questionType',question_type,
      'state',state,'wrong',wrong,'difficult',difficult
    ) order by rn) from targeted where rn<=14
  ),'[]'::jsonb),
  'trapProfile',coalesce((
    select jsonb_agg(jsonb_build_object('trap',trap,'count',n) order by n desc,last_at desc)
    from traps
  ),'[]'::jsonb),
  'previousMistakes',coalesce((
    select jsonb_agg(jsonb_build_object(
      'category',category,'questionType',question_type,'question',question,'options',options,
      'correctKey',correct_key,'explanation',explanation,'canonicalQuestionId',canonical_question_id,
      'conceptKey',concept_key,'diagnosis',diagnosis,'confusedWith',confused_with
    ) order by rn) from previous where rn<=10
  ),'[]'::jsonb),
  'cooldownConcepts',coalesce((
    select jsonb_agg(concept_key order by concept_key) from cooldown
  ),'[]'::jsonb),
  'slowCorrectSeeds',coalesce((
    select jsonb_agg(jsonb_build_object(
      'category',category,'questionType',question_type,'question',question,
      'conceptKey',concept_key,'timeSeconds',time_seconds
    ) order by rn) from slow_correct where rn<=12
  ),'[]'::jsonb),
  'allowedAreas',jsonb_build_array(
    'Vocabulary','Synonym','Antonym','Idioms & Phrases','One Word Substitution',
    'Phrasal Verbs','Fixed Preposition','Spelling','Error Detection','Grammar Usage',
    'Sentence Improvement','Fill in the Blank','Voice','Narration'
  )
 )
end;
$function$;

-- ============================================================
-- 6. DETERMINISTIC PRE-SERVE SPRINT CONTRACT
-- ============================================================

create or replace function public.english_create_sprint_session(
  p_mode text,
  p_items jsonb,
  p_blueprint jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
 uid uuid:=auth.uid();
 m text:=lower(coalesce(p_mode,'standard'));
 expected integer;
 sid uuid;
 x jsonb;
 pos integer:=0;
 opts jsonb;
 ck text;
 st text;
 qt text;
 qs text;
 cat text;
 expl text;
 itemkey text;
 cq text;
 meta jsonb;
 quality numeric;
 ambiguous boolean;
 tier text;
 domain_name text;
 discr numeric;
 trap_strength numeric;
 concept_key text;
 critic_passed boolean;
 v_easy integer:=0;
 v_moderate integer:=0;
 v_hard integer:=0;
 v_grammar integer:=0;
 v_lexical integer:=0;
 v_expected_easy integer;
 v_expected_moderate integer;
 v_expected_hard integer;
 v_expected_grammar integer;
 v_expected_lexical integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 expected:=english.sprint_expected_count(m);
 if expected=0 then raise exception 'Unknown Sprint mode'; end if;
 if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array'
    or jsonb_array_length(p_items)<>expected
   then raise exception 'Sprint requires exactly % questions',expected; end if;

 insert into english.sprint_sessions(user_id,mode,question_count,blueprint)
 values(uid,m,expected,coalesce(p_blueprint,'{}'::jsonb))
 returning session_id into sid;

 for x in select value from jsonb_array_elements(p_items) loop
   pos:=pos+1;
   opts:=coalesce(x->'options','[]'::jsonb);
   ck:=upper(coalesce(x->>'correctKey',''));
   st:=coalesce(nullif(x->>'sourceType',''),'GPT Generated');
   qt:=btrim(coalesce(x->>'questionType',''));
   qs:=btrim(coalesce(x->>'question',''));
   cat:=btrim(coalesce(x->>'category','English'));
   expl:=btrim(coalesce(x->>'explanation',''));
   itemkey:=coalesce(nullif(x->>'itemKey',''),'gpt-'||sid::text||'-'||pos);
   cq:=nullif(btrim(coalesce(x->>'canonicalQuestionId','')),'');
   meta:=coalesce(x->'metadata','{}'::jsonb);
   quality:=coalesce((x->>'qualityScore')::numeric,0);
   ambiguous:=coalesce((x->>'ambiguous')::boolean,true);

   tier:=coalesce(meta->>'difficultyTier','');
   domain_name:=coalesce(meta->>'domain','');
   concept_key:=btrim(coalesce(meta->>'conceptKey',''));
   critic_passed:=coalesce((meta->>'criticPassed')::boolean,false);

   if jsonb_typeof(meta->'discriminationScore') is distinct from 'number'
      or jsonb_typeof(meta->'trapStrength') is distinct from 'number'
     then raise exception 'Sprint item % is missing numeric discrimination metadata',pos; end if;
   discr:=(meta->>'discriminationScore')::numeric;
   trap_strength:=(meta->>'trapStrength')::numeric;

   if st not in ('SSC PYQ','Curated Bank','GPT Generated','GPT Variant of Known Concept')
      then raise exception 'Untruthful/unknown Sprint source label at %',pos; end if;
   if st='SSC PYQ' and coalesce(meta->>'verifiedPyq','false')<>'true'
      then raise exception 'GPT output cannot self-label as SSC PYQ'; end if;

   if qs='' or expl='' or not english.sprint_allowed_type(qt)
      or not english.sprint_validate_options(opts,ck)
      then raise exception 'Invalid Sprint item at %',pos; end if;
   if ambiguous or quality<0.80
      then raise exception 'Ambiguous or low-confidence Sprint item at %',pos; end if;

   if tier not in ('Easy','Moderate','Hard')
      then raise exception 'Invalid Sprint difficulty tier at %',pos; end if;
   if domain_name not in ('GrammarTransformation','LexicalUsage')
      then raise exception 'Invalid Sprint domain at %',pos; end if;
   if discr<0 or discr>1 or trap_strength<0 or trap_strength>1
      then raise exception 'Invalid Sprint discrimination metadata at %',pos; end if;
   if concept_key='' or btrim(coalesce(meta->>'trapTested',''))=''
      or btrim(coalesce(meta->>'generationReason',''))=''
      or not critic_passed
      then raise exception 'Incomplete Sprint quality metadata at %',pos; end if;

   if exists(
     select 1 from english.sprint_items oldi
     join english.sprint_sessions olds on olds.session_id=oldi.session_id
     where olds.user_id=uid and olds.status='completed'
       and olds.completed_at>=(((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata')
       and regexp_replace(lower(btrim(oldi.question)),'\s+',' ','g')
           =regexp_replace(lower(qs),'\s+',' ','g')
   ) then raise exception 'Same-day Sprint question repetition rejected at %',pos; end if;

   if exists(
     select 1
     from english.sprint_sessions olds
     join english.sprint_items oldi on oldi.session_id=olds.session_id
     join english.sprint_answers olda
       on olda.session_id=oldi.session_id and olda.position=oldi.position and olda.user_id=olds.user_id
     where olds.user_id=uid and olds.status='completed'
       and olds.completed_at>=(((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata')
       and nullif(btrim(oldi.metadata->>'conceptKey'),'')=concept_key
       and olda.selected_key is not null and olda.correct
       and olda.time_seconds>0 and olda.time_seconds<=20
       and not exists(
         select 1
         from english.sprint_sessions later_s
         join english.sprint_items later_i on later_i.session_id=later_s.session_id
         join english.sprint_answers later_a
           on later_a.session_id=later_i.session_id and later_a.position=later_i.position
         where later_s.user_id=uid and later_s.status='completed'
           and later_s.completed_at>olds.completed_at
           and nullif(btrim(later_i.metadata->>'conceptKey'),'')=concept_key
           and later_a.selected_key is not null and not later_a.correct
       )
   ) then raise exception 'Same-day fast-correct concept cooldown rejected at %',pos; end if;

   if exists(
     select 1 from english.sprint_items cur
     where cur.session_id=sid
       and (
         regexp_replace(lower(btrim(cur.question)),'\s+',' ','g')=regexp_replace(lower(qs),'\s+',' ','g')
         or nullif(btrim(cur.metadata->>'conceptKey'),'')=concept_key
       )
   ) then raise exception 'Duplicate Sprint question/concept at %',pos; end if;

   if cq is not null and not exists(select 1 from english.questions q where q.question_id=cq)
      then cq:=null; end if;

   insert into english.sprint_items(
     session_id,position,item_key,canonical_question_id,source_type,category,question_type,
     question,options,correct_key,explanation,metadata
   ) values(
     sid,pos,itemkey,cq,st,cat,qt,qs,opts,ck,expl,
     meta||jsonb_build_object('qualityScore',quality)
   );

   if tier='Easy' then v_easy:=v_easy+1;
   elsif tier='Moderate' then v_moderate:=v_moderate+1;
   else v_hard:=v_hard+1;
   end if;

   if domain_name='GrammarTransformation' then v_grammar:=v_grammar+1;
   else v_lexical:=v_lexical+1;
   end if;
 end loop;

 if m='standard' then
   v_expected_easy:=coalesce((p_blueprint->'difficulty'->>'easy')::int,5);
   v_expected_moderate:=coalesce((p_blueprint->'difficulty'->>'moderate')::int,13);
   v_expected_hard:=coalesce((p_blueprint->'difficulty'->>'hard')::int,7);
   v_expected_grammar:=coalesce((p_blueprint->'questionMix'->>'grammarTransformation')::int,11);
   v_expected_lexical:=coalesce((p_blueprint->'questionMix'->>'lexicalUsage')::int,14);

   if v_easy<>v_expected_easy or v_moderate<>v_expected_moderate or v_hard<>v_expected_hard
      then raise exception 'Standard Sprint difficulty distribution mismatch: got %/%/%, expected %/%/%',
        v_easy,v_moderate,v_hard,v_expected_easy,v_expected_moderate,v_expected_hard; end if;
   if v_grammar<>v_expected_grammar or v_lexical<>v_expected_lexical
      then raise exception 'Standard Sprint domain mix mismatch: got %/%, expected %/%',
        v_grammar,v_lexical,v_expected_grammar,v_expected_lexical; end if;
 end if;

 return public.english_get_sprint_session(sid);
exception when others then
 if sid is not null then delete from english.sprint_sessions where session_id=sid and user_id=uid; end if;
 raise;
end
$function$;

-- ============================================================
-- 7. EXAM PREP METRICS: ONLY TRUE WRONG ANSWERS ARE MISTAKES
-- ============================================================

create or replace function public.english_get_exam_preparation()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with uid as (select auth.uid() id),
settings as (
  select coalesce(e.target_date,(now() at time zone 'Asia/Kolkata')::date+30) target_date,
         coalesce(e.goal_marks,45) goal_marks
  from uid left join english.exam_settings e on e.user_id=uid.id
),
hist_all as (
  select s.*,row_number() over(order by completed_at desc,session_id desc) rn
  from english.sprint_sessions s cross join uid
  where s.user_id=uid.id and s.status='completed'
),
standard_hist as (
  select s.*,row_number() over(order by completed_at desc,session_id desc) rn
  from english.sprint_sessions s cross join uid
  where s.user_id=uid.id and s.status='completed' and s.mode='standard'
),
five as (select * from standard_hist where rn<=5),
streak as (
  select case when count(*)=0 then 0
    else coalesce(min(rn) filter(where score<(select goal_marks from settings))-1,count(*))::int end n
  from standard_hist
),
miss_all as (
  select a.*,i.category,i.canonical_question_id,s.completed_at,s.mode
  from english.sprint_answers a
  join english.sprint_items i on i.session_id=a.session_id and i.position=a.position
  join english.sprint_sessions s on s.session_id=a.session_id
  cross join uid
  where a.user_id=uid.id and s.status='completed'
    and a.selected_key is not null and not a.correct
),
miss_standard as (select * from miss_all where mode='standard'),
category as (
  select category,count(*)::int wrong,max(completed_at) last_at
  from miss_all group by category
  order by wrong desc,last_at desc limit 5
),
top_two as (
  select category,wrong,last_at from category order by wrong desc,last_at desc limit 2
),
traps as (
  select coalesce(nullif(confused_with,''),diagnosis) trap,count(*)::int n,max(created_at) last_at
  from english.sprint_answers a cross join uid
  where a.user_id=uid.id and a.selected_key is not null
    and nullif(coalesce(confused_with,diagnosis),'') is not null
  group by 1 order by n desc,last_at desc limit 5
),
sprint_targeted as (
  select count(distinct question_id)::int n
  from english.learning_route_events e cross join uid
  where e.user_id=uid.id and e.origin='Sprint' and e.to_route='targeted'
),
sprint_recovered as (
  select count(distinct e.question_id)::int n
  from english.learning_route_events e cross join uid
  where e.user_id=uid.id and e.origin='Sprint' and e.to_route='targeted'
    and exists(
      select 1 from english.learning_route_state r
      where r.user_id=uid.id and r.question_id=e.question_id and r.route<>'targeted'
    )
),
route as (select public.english_get_learning_route_overview() j),
intelligence as (select public.english_get_central_intelligence() j)
select case
 when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object(
  'ok',true,
  'targetDate',(select target_date from settings),
  'daysLeft',greatest(0,(select target_date from settings)-(now() at time zone 'Asia/Kolkata')::date),
  'goalMarks',(select goal_marks from settings),
  'standard',jsonb_build_object(
    'questions',25,'minutes',15,'marks',50,'wrongPenalty',-.5,'readingComprehension',false
  ),
  'readiness',jsonb_build_object(
    'lastSprint',(select score from standard_hist where rn=1),
    'fiveSprintAverage',(select round(avg(score),2) from five),
    'best',(select max(score) from standard_hist),
    'lowest',(select min(score) from standard_hist),
    'accuracy',(select round(avg(accuracy),1) from five),
    'timeSeconds',(select round(avg(duration_seconds))::int from five),
    'goalStreak',(select n from streak),
    'knownButMissed',(
      select count(*) from miss_standard m
      where m.canonical_question_id is not null and exists(
        select 1 from english.learning_route_state r
        where r.user_id=(select id from uid)
          and r.question_id=m.canonical_question_id and r.route='fast_track'
      )
    ),
    'targetedMissed',(
      select count(*) from miss_standard m
      where m.canonical_question_id is not null and exists(
        select 1 from english.learning_route_state r
        where r.user_id=(select id from uid)
          and r.question_id=m.canonical_question_id and r.route='targeted'
      )
    ),
    'preventableMarksLost',(
      select coalesce(round(count(*) filter(
        where diagnosis in ('Careless','Misread','Time Pressure')
      )*2.5,1),0) from miss_standard
    )
  ),
  'weaknesses',coalesce((
    select jsonb_agg(jsonb_build_object('category',category,'wrong',wrong)
      order by wrong desc,last_at desc) from category
  ),'[]'::jsonb),
  'traps',coalesce((
    select jsonb_agg(jsonb_build_object('trap',trap,'count',n)
      order by n desc,last_at desc) from traps
  ),'[]'::jsonb),
  'recentSprints',coalesce((
    select jsonb_agg(jsonb_build_object(
      'sessionId',session_id,'mode',mode,'score',score,
      'maxMarks',question_count*2,'questionCount',question_count,
      'correct',correct_count,'wrong',wrong_count,'unanswered',unanswered_count,
      'accuracy',accuracy,'durationSeconds',duration_seconds,'completedAt',completed_at
    ) order by completed_at desc)
    from hist_all where rn<=5
  ),'[]'::jsonb),
  'targetedFromSprints',jsonb_build_object(
    'needLearning',(select n from sprint_targeted),
    'recovered',(select n from sprint_recovered)
  ),
  'todayPlan',jsonb_build_object(
    'targetedRevision',coalesce((
      select (j->'queues'->>'persistentWeak')::int
           +(j->'queues'->>'weak')::int
           +(j->'queues'->>'fragile')::int
      from intelligence
    ),0),
    'fastTrackReady',coalesce((select (j->'fastTrack'->>'readyToVerify')::int from route),0),
    'sprintQuestions',25,
    'weaknessDrill',coalesce((
      select string_agg(category,' + ' order by wrong desc,last_at desc) from top_two
    ),'Current weak areas')
  )
 )
end;
$function$;

-- English V2: global Fast Track evidence contract.
-- Bank Coverage remains the only ordinary-module first-clean exception.
-- Every other ordinary module shares question-level historical evidence:
--   >= 10 meaningful checkpoints (one latest checkpoint per IST study day)
--   >= 80% checkpoint accuracy
--   last 4 meaningful checkpoints correct
--   Difficult = false
-- Stars/Saved/module labels are context only and do not block eligibility.

create or replace function english.fast_track_evidence(p_user_id uuid, p_question_id text)
returns table(
  meaningful_attempts integer,
  correct_checkpoints integer,
  accuracy_percent numeric,
  last4_correct integer,
  first_day date,
  last_day date,
  difficult boolean,
  eligible boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
with per_day as (
  select study_day, correct, attempted_at
  from (
    select
      (a.attempted_at at time zone 'Asia/Kolkata')::date as study_day,
      coalesce(a.correct,false) as correct,
      a.attempted_at,
      row_number() over (
        partition by (a.attempted_at at time zone 'Asia/Kolkata')::date
        order by a.attempted_at desc, a.attempt_id desc
      ) as rn
    from english.attempts a
    where a.user_id=p_user_id and a.question_id=p_question_id
  ) x
  where rn=1
), ranked as (
  select p.*,row_number() over(order by attempted_at desc) as recent_rank
  from per_day p
), stats as (
  select
    count(*)::int as meaningful_attempts,
    count(*) filter(where correct)::int as correct_checkpoints,
    case when count(*)=0 then 0::numeric
         else round(100.0*count(*) filter(where correct)/count(*),1) end as accuracy_percent,
    count(*) filter(where recent_rank<=4 and correct)::int as last4_correct,
    min(study_day) as first_day,
    max(study_day) as last_day
  from ranked
), flags as (
  select coalesce((
    select d.difficult
    from english.difficult_state d
    where d.user_id=p_user_id and d.question_id=p_question_id
  ),false) as difficult
)
select
  s.meaningful_attempts,s.correct_checkpoints,s.accuracy_percent,s.last4_correct,
  s.first_day,s.last_day,f.difficult,
  (s.meaningful_attempts>=10 and s.accuracy_percent>=80 and s.last4_correct=4 and not f.difficult) as eligible
from stats s cross join flags f;
$function$;

revoke all on function english.fast_track_evidence(uuid,text) from public, anon, authenticated;

create or replace function english.route_to_fast_track(
  p_user_id uuid,
  p_question_id text,
  p_origin text,
  p_reason text,
  p_force_recovery boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare
  old english.learning_route_state%rowtype;
  s english.question_state%rowtype;
  ev record;
  v_origins text[];
  v_wrong integer:=0;
  v_now timestamptz:=now();
  v_bank_exception boolean:=btrim(coalesce(p_origin,'')) in ('Bank Coverage','Historical Clean Bank');
begin
  select * into s from english.question_state where user_id=p_user_id and question_id=p_question_id;
  v_wrong:=coalesce(s.wrong,0);
  if coalesce(s.mastered,false) then
    return jsonb_build_object('ok',false,'reason','already-mastered');
  end if;

  select * into ev from english.fast_track_evidence(p_user_id,p_question_id);
  if not coalesce(p_force_recovery,false) and not v_bank_exception and not coalesce(ev.eligible,false) then
    return jsonb_build_object(
      'ok',false,'reason','insufficient-global-evidence',
      'meaningfulAttempts',coalesce(ev.meaningful_attempts,0),
      'accuracyPercent',coalesce(ev.accuracy_percent,0),
      'last4Correct',coalesce(ev.last4_correct,0),
      'difficult',coalesce(ev.difficult,false)
    );
  end if;

  select * into old from english.learning_route_state where user_id=p_user_id and question_id=p_question_id;
  v_origins:=english.route_add_origin(coalesce(old.origins,'{}'::text[]),p_origin);

  insert into english.learning_route_state(
    user_id,question_id,route,fast_track_status,origins,baseline_wrong,
    entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
    pending_failure_decision,kept_failure_count,targeted_recovered_at,last_route_reason,updated_at
  ) values(
    p_user_id,p_question_id,'fast_track','ready',v_origins,v_wrong,
    v_now,v_now,null,false,0,
    case when old.route='targeted' then v_now else old.targeted_recovered_at end,
    p_reason,v_now
  )
  on conflict(user_id,question_id) do update set
    route='fast_track',fast_track_status='ready',origins=v_origins,baseline_wrong=v_wrong,
    entered_fast_track_at=v_now,next_fast_track_check=v_now,fast_track_mastered_at=null,
    pending_failure_decision=false,kept_failure_count=0,
    targeted_recovered_at=case when english.learning_route_state.route='targeted' then v_now else english.learning_route_state.targeted_recovered_at end,
    last_route_reason=p_reason,updated_at=v_now;

  perform english.route_event(
    p_user_id,p_question_id,
    case when old.route='targeted' then 'RECOVER' else 'ROUTE' end,
    old.route,'fast_track',p_origin,p_reason,
    jsonb_build_object(
      'baselineWrong',v_wrong,
      'meaningfulAttempts',coalesce(ev.meaningful_attempts,0),
      'accuracyPercent',coalesce(ev.accuracy_percent,0),
      'last4Correct',coalesce(ev.last4_correct,0),
      'bankException',v_bank_exception,
      'forcedRecovery',coalesce(p_force_recovery,false)
    ),null
  );

  return jsonb_build_object(
    'ok',true,'route','fast_track','status','ready','origins',v_origins,
    'meaningfulAttempts',coalesce(ev.meaningful_attempts,0),
    'accuracyPercent',coalesce(ev.accuracy_percent,0),
    'last4Correct',coalesce(ev.last4_correct,0)
  );
end
$function$;

create or replace function english.route_after_attempt_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare
  q english.questions%rowtype;
  r english.learning_route_state%rowtype;
  d boolean:=false;
  ev record;
  v_module text:=lower(coalesce(new.module,''));
  v_attempts integer:=0;
  v_wrong integer:=0;
  v_ft_wrong integer:=0;
  v_ft_clean_days integer:=0;
  v_required integer:=1;
  v_saved boolean:=false;
begin
  select * into q from english.questions where question_id=new.question_id;
  if not found or not q.active then return new; end if;

  select * into r from english.learning_route_state where user_id=new.user_id and question_id=new.question_id;
  select coalesce(ds.difficult,false) into d
  from english.difficult_state ds where ds.user_id=new.user_id and ds.question_id=new.question_id;
  if not found then d:=false; end if;
  v_saved:=english.route_is_saved(new.user_id,new.question_id);

  select count(*)::int,count(*) filter(where not coalesce(correct,false))::int
  into v_attempts,v_wrong
  from english.attempts
  where user_id=new.user_id and question_id=new.question_id;

  if v_module='fasttrack' and r.route='fast_track' then
    if coalesce(new.correct,false) then
      select count(distinct (a.attempted_at at time zone 'Asia/Kolkata')::date)::int
      into v_ft_clean_days
      from english.attempts a
      where a.user_id=new.user_id and a.question_id=new.question_id
        and lower(coalesce(a.module,''))='fasttrack'
        and coalesce(a.correct,false)
        and a.attempted_at>=coalesce(r.entered_fast_track_at,'epoch'::timestamptz);

      v_required:=case when exists(
        select 1 from unnest(coalesce(r.origins,'{}'::text[])) x
        where x='From Starred' or x like 'Recovered %'
      ) then 2 else 1 end;

      update english.learning_route_state set
        pending_failure_decision=false,
        fast_track_status=case when v_ft_clean_days>=v_required then 'mastered' else 'waiting' end,
        next_fast_track_check=case when v_ft_clean_days>=v_required then null else now()+interval '2 days' end,
        fast_track_mastered_at=case when v_ft_clean_days>=v_required then coalesce(fast_track_mastered_at,now()) else fast_track_mastered_at end,
        last_route_reason=case when v_ft_clean_days>=v_required then 'Fast Track verification complete' else 'Waiting for spaced Fast Track check' end,
        updated_at=now()
      where user_id=new.user_id and question_id=new.question_id;

      perform english.route_event(new.user_id,new.question_id,'VERIFY','fast_track','fast_track',null,'Clean Fast Track recall',jsonb_build_object('cleanDays',v_ft_clean_days,'required',v_required),null);
    else
      select count(*)::int into v_ft_wrong
      from english.attempts a
      where a.user_id=new.user_id and a.question_id=new.question_id
        and lower(coalesce(a.module,''))='fasttrack'
        and not coalesce(a.correct,false)
        and a.attempted_at>=coalesce(r.entered_fast_track_at,'epoch'::timestamptz);

      update english.learning_route_state set last_failure_at=now(),updated_at=now()
      where user_id=new.user_id and question_id=new.question_id;
      perform english.route_event(new.user_id,new.question_id,'FAIL','fast_track','fast_track',null,'Fast Track recall missed',jsonb_build_object('failureCount',v_ft_wrong),null);

      if v_ft_wrong>=2 then
        perform english.route_to_targeted(new.user_id,new.question_id,'Fast Track Failure','Repeated Fast Track failure');
      else
        update english.learning_route_state set
          pending_failure_decision=true,fast_track_status='ready',next_fast_track_check=null,
          last_route_reason='Fast Track failure needs learner decision',updated_at=now()
        where user_id=new.user_id and question_id=new.question_id;
      end if;
    end if;
    return new;
  end if;

  if not coalesce(new.correct,false) then
    if r.route='fast_track' then
      perform english.route_to_targeted(new.user_id,new.question_id,'Fast Track','Negative evidence outside Fast Track verification');
    elsif v_saved then
      perform english.route_to_targeted(new.user_id,new.question_id,'From My Saved','Saved-item recall failed');
    elsif v_module='bankcoverage' then
      perform english.route_to_targeted(new.user_id,new.question_id,'Bank Coverage','Bank Coverage discovery failed');
    end if;
    return new;
  end if;

  -- The one ordinary-module exception: a genuine Bank Coverage question may
  -- enter Fast Track on its first-ever clean attempt.
  if v_module='bankcoverage' and v_attempts=1 and v_wrong=0
     and english.is_genuine_bank_question(q) and not d then
    perform english.route_to_fast_track(
      new.user_id,new.question_id,'Bank Coverage','First-time clean Bank Coverage discovery',false
    );
    return new;
  end if;

  -- Every other module shares one question-level evidence contract.
  -- Module/source/Starred/Saved labels do not affect qualification.
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

create or replace function english.route_after_question_state_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare
  r english.learning_route_state%rowtype;
  reason text;
  d boolean:=false;
  ev record;
  clean_days integer:=0;
  wrong_after integer:=0;
  recovery_origin text;
begin
  if coalesce(new.mastered,false) then return new; end if;

  select * into r from english.learning_route_state
  where user_id=new.user_id and question_id=new.question_id;
  select coalesce(ds.difficult,false) into d
  from english.difficult_state ds where ds.user_id=new.user_id and ds.question_id=new.question_id;
  if not found then d:=false; end if;

  -- Global historical evidence can graduate a question regardless of which
  -- ordinary module generated those checkpoints. Starred/Saved are not blockers.
  if not d and (r.question_id is null or r.route<>'fast_track') then
    select * into ev from english.fast_track_evidence(new.user_id,new.question_id);
    if coalesce(ev.eligible,false) then
      perform english.route_to_fast_track(
        new.user_id,new.question_id,'Global Evidence',
        '10 spaced checkpoints, >=80% accuracy and last 4 clean',false
      );
      return new;
    end if;
  end if;

  -- Dedicated Targeted recovery remains a valid recovery route and no longer
  -- requires Starred to be cleared/unstarred.
  if found and r.route='targeted' and new.status in ('Strong','Proven Mastered') and coalesce(new.last_result,false) then
    if not d then
      select
        count(distinct (a.attempted_at at time zone 'Asia/Kolkata')::date) filter(where coalesce(a.correct,false))::int,
        count(*) filter(where not coalesce(a.correct,false))::int
      into clean_days,wrong_after
      from english.attempts a
      where a.user_id=new.user_id and a.question_id=new.question_id
        and a.attempted_at>=coalesce(r.targeted_at,'epoch'::timestamptz);

      if clean_days>=2 and wrong_after=0 then
        recovery_origin:=english.route_recovery_origin(r.last_route_reason);
        perform english.route_to_fast_track(
          new.user_id,new.question_id,recovery_origin,
          'Targeted item recovered with spaced clean evidence',true
        );
        return new;
      end if;
    end if;
  end if;

  -- Starred is now a revision/bookmark attribute only; it no longer creates
  -- starred_unresolved routes or blocks/promotes Fast Track by itself.
  reason:=english.route_targeted_reason(new.user_id,new.question_id);
  if nullif(reason,'') is not null then
    perform english.route_to_targeted(
      new.user_id,new.question_id,
      case when reason='Difficult' then 'Difficult' else 'Central Intelligence' end,
      reason
    );
  end if;
  return new;
end
$function$;

create or replace function english.route_after_difficult_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare ev record;
begin
  if coalesce(new.difficult,false) then
    perform english.route_to_targeted(new.user_id,new.question_id,'Difficult','Learner marked Difficult');
    return new;
  end if;

  -- Removing Difficult immediately re-evaluates already-earned global evidence.
  if tg_op='UPDATE' and coalesce(old.difficult,false) and not coalesce(new.difficult,false) then
    select * into ev from english.fast_track_evidence(new.user_id,new.question_id);
    if coalesce(ev.eligible,false) then
      perform english.route_to_fast_track(
        new.user_id,new.question_id,'Global Evidence',
        'Difficult cleared; existing global spaced evidence qualifies',false
      );
    end if;
  end if;
  return new;
end
$function$;

-- Retrospective reconciliation. Historical attempts are never deleted/reset;
-- partial 2/4/6/8-day progress therefore continues naturally toward 10.
do $reconcile$
declare
  x record;
  ev record;
  v_star_action text;
  v_star_at timestamptz;
  v_resolved_at timestamptz;
begin
  -- 1) Remove old non-Bank Fast Track shortcuts that do not satisfy v2.
  for x in
    select r.*
    from english.learning_route_state r
    where r.route='fast_track'
      and not ('Historical Clean Bank'=any(coalesce(r.origins,'{}'::text[]))
               or 'Bank Coverage'=any(coalesce(r.origins,'{}'::text[])))
      and not (select e.eligible from english.fast_track_evidence(r.user_id,r.question_id) e)
  loop
    select * into ev from english.fast_track_evidence(x.user_id,x.question_id);

    update english.learning_route_state set
      route='unclassified',fast_track_status=null,
      entered_fast_track_at=null,next_fast_track_check=null,fast_track_mastered_at=null,
      pending_failure_decision=false,kept_failure_count=0,
      last_route_reason='Awaiting global Fast Track evidence: 10 spaced checkpoints, >=80% accuracy, last 4 clean',
      updated_at=now()
    where user_id=x.user_id and question_id=x.question_id;

    perform english.route_event(
      x.user_id,x.question_id,'RECONCILE','fast_track','unclassified','Global Evidence v2',
      'Old non-Bank shortcut removed; historical progress preserved',
      jsonb_build_object(
        'meaningfulAttempts',coalesce(ev.meaningful_attempts,0),
        'accuracyPercent',coalesce(ev.accuracy_percent,0),
        'last4Correct',coalesce(ev.last4_correct,0)
      ),
      'global-evidence-v2:rollback:'||x.user_id::text||':'||x.question_id
    );

    -- Restore a Star only when the latest UNSTAR was the automatic old
    -- STAR_RESOLVED action itself (never override a later manual UNSTAR).
    select s.action,s.event_at into v_star_action,v_star_at
    from english.star_events s
    where s.user_id=x.user_id and s.question_id=x.question_id
    order by s.event_at desc,s.id desc limit 1;

    select e.event_at into v_resolved_at
    from english.learning_route_events e
    where e.user_id=x.user_id and e.question_id=x.question_id
      and e.event_type='STAR_RESOLVED' and e.origin='From Starred'
    order by e.event_at desc limit 1;

    if v_star_action='UNSTAR' and v_resolved_at is not null
       and abs(extract(epoch from (v_star_at-v_resolved_at)))<1 then
      insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action)
      values(x.user_id,x.question_id,now(),(now() at time zone 'Asia/Kolkata')::date,null,'STAR');
      update english.learning_route_state set starred_resolved_at=null,updated_at=now()
      where user_id=x.user_id and question_id=x.question_id;
      perform english.recompute_question_state(x.user_id,x.question_id);
    end if;
  end loop;

  -- 2) Eliminate Starred as a route state. Keep the Star itself; route is
  -- governed by global evidence/Targeted/Difficult only.
  for x in
    select r.* from english.learning_route_state r where r.route='starred_unresolved'
  loop
    select * into ev from english.fast_track_evidence(x.user_id,x.question_id);
    if coalesce(ev.eligible,false) then
      perform english.route_to_fast_track(
        x.user_id,x.question_id,'Historical Global Evidence',
        'Retrospective v2: 10 spaced checkpoints, >=80% accuracy and last 4 clean',false
      );
    else
      update english.learning_route_state set
        route='unclassified',fast_track_status=null,next_fast_track_check=null,
        pending_failure_decision=false,kept_failure_count=0,
        last_route_reason='Star retained; awaiting global Fast Track evidence',updated_at=now()
      where user_id=x.user_id and question_id=x.question_id;
      perform english.route_event(
        x.user_id,x.question_id,'RECONCILE','starred_unresolved','unclassified','Global Evidence v2',
        'Star is no longer a learning-route blocker',
        jsonb_build_object(
          'meaningfulAttempts',coalesce(ev.meaningful_attempts,0),
          'accuracyPercent',coalesce(ev.accuracy_percent,0),
          'last4Correct',coalesce(ev.last4_correct,0)
        ),
        'global-evidence-v2:star-route:'||x.user_id::text||':'||x.question_id
      );
    end if;
  end loop;

  -- 3) Promote every historical non-mastered question that already satisfies
  -- the new global rule, regardless of which modules supplied the evidence.
  for x in
    select s.user_id,s.question_id
    from english.question_state s
    join english.questions q on q.question_id=s.question_id and q.active
    left join english.learning_route_state r on r.user_id=s.user_id and r.question_id=s.question_id
    where not coalesce(s.mastered,false)
      and coalesce(r.route,'unclassified')<>'fast_track'
      and (select e.eligible from english.fast_track_evidence(s.user_id,s.question_id) e)
  loop
    perform english.route_to_fast_track(
      x.user_id,x.question_id,'Historical Global Evidence',
      'Retrospective v2: 10 spaced checkpoints, >=80% accuracy and last 4 clean',false
    );
  end loop;
end
$reconcile$;

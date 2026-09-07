-- Fix PL/pgSQL ambiguity between the Sprint session score column and the Luna report score variable.
-- This is publication plumbing only; question selection, critic policy and learner history are unchanged.

create or replace function public.english_sprint_critic_worker_apply(p_token text,p_session_id uuid,p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  s english.sprint_sessions%rowtype;
  decision text:=upper(coalesce(p_report->>'decision',''));
  v_score numeric:=coalesce((p_report->>'score')::numeric,0);
  checks jsonb:=coalesce(p_report->'setChecks','{}'::jsonb);
  verdicts jsonb:=coalesce(p_report->'itemVerdicts','[]'::jsonb);
  repair_positions jsonb:=coalesce(p_report->'repairPositions','[]'::jsonb);
  historical_positions jsonb:='[]'::jsonb;
  merged_repairs jsonb:='[]'::jsonb;
  pass_checks boolean;
  pass_items boolean;
  malformed boolean;
  v_set integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'Unauthorized Sprint critic worker'; end if;
  select * into s from english.sprint_sessions where session_id=p_session_id for update;
  if not found then raise exception 'Sprint critic session not found'; end if;
  if s.status<>'critic_pending' then return jsonb_build_object('ok',true,'status',s.status,'setNo',s.set_no); end if;

  malformed:=jsonb_typeof(verdicts)<>'array' or jsonb_array_length(verdicts)<>25
    or (select count(distinct (x->>'position')::integer) from jsonb_array_elements(verdicts) x)<>25;

  pass_checks:=
    coalesce((checks->>'exactly25')::boolean,false)
    and coalesce((checks->>'exactlyOneDefensibleAnswer')::boolean,false)
    and coalesce((checks->>'sscCglLevel')::boolean,false)
    and coalesce((checks->>'difficultyCalibration')::boolean,false)
    and coalesce((checks->>'distractorQuality')::boolean,false)
    and coalesce((checks->>'noHistoricalRepeat')::boolean,false)
    and coalesce((checks->>'noWithinSetSemanticDuplicate')::boolean,false)
    and coalesce((checks->>'factualAccuracy')::boolean,false)
    and coalesce((checks->>'naturalEnglish')::boolean,false);

  pass_items:=not malformed and not exists(
    select 1 from jsonb_array_elements(verdicts) x
    where upper(coalesce(x->>'verdict',''))<>'PASS'
       or coalesce((x->>'pass')::boolean,false)=false
       or coalesce((x->>'sscLevelFit')::boolean,false)=false
       or coalesce((x->>'difficultyFit')::boolean,false)=false
       or coalesce((x->>'singleAnswer')::boolean,false)=false
       or coalesce((x->>'distractorsStrong')::boolean,false)=false
       or coalesce((x->>'factual')::boolean,false)=false
       or coalesce((x->>'fresh')::boolean,false)=false
       or coalesce((x->>'semanticDistinct')::boolean,false)=false
  );

  select coalesce(jsonb_agg(position order by position),'[]'::jsonb)
  into historical_positions
  from (
    select distinct ni.position
    from english.sprint_items ni
    join english.sprint_sessions ns on ns.session_id=ni.session_id
    where ns.session_id=p_session_id
      and exists(
        select 1 from english.sprint_sessions os
        join english.sprint_items oi on oi.session_id=os.session_id
        where os.user_id=ns.user_id and os.mode='standard' and os.status='completed'
          and english.sprint_normalized_question(oi.question)=english.sprint_normalized_question(ni.question)
      )
  ) d;

  select coalesce(jsonb_agg(pos order by pos),'[]'::jsonb)
  into merged_repairs
  from (
    select distinct value::integer pos from jsonb_array_elements_text(repair_positions)
    union
    select distinct value::integer pos from jsonb_array_elements_text(historical_positions)
    union
    select distinct (x->>'position')::integer pos
    from jsonb_array_elements(verdicts) x
    where upper(coalesce(x->>'verdict',''))='REPAIR'
       or coalesce((x->>'pass')::boolean,false)=false
       or coalesce((x->>'sscLevelFit')::boolean,false)=false
       or coalesce((x->>'difficultyFit')::boolean,false)=false
       or coalesce((x->>'singleAnswer')::boolean,false)=false
       or coalesce((x->>'distractorsStrong')::boolean,false)=false
       or coalesce((x->>'factual')::boolean,false)=false
       or coalesce((x->>'fresh')::boolean,false)=false
       or coalesce((x->>'semanticDistinct')::boolean,false)=false
  ) r where pos between 1 and 25;

  if decision='PASS' and v_score>=90 and pass_checks and pass_items and jsonb_array_length(historical_positions)=0 then
    perform pg_advisory_xact_lock(hashtext('english.sprint.set_no'),hashtext(s.user_id::text));
    if exists(select 1 from english.sprint_sessions where user_id=s.user_id and status in ('in_progress','paused') and session_id<>p_session_id) then
      raise exception 'Another Sprint became active while Luna was reviewing this set';
    end if;
    update english.sprint_sessions
    set status='abandoned',blueprint=blueprint||jsonb_build_object('supersededByLunaPassedSet',true,'supersededAt',now())
    where user_id=s.user_id and status='ready' and session_id<>p_session_id;

    select coalesce(max(ss.set_no),0)+1 into v_set
    from english.sprint_sessions ss where ss.user_id=s.user_id and ss.mode='standard' and ss.set_no is not null;

    update english.sprint_sessions
    set status='ready',set_no=v_set,critic_status='passed',luna_critic=coalesce(p_report,'{}'::jsonb),
        critic_error=null,critic_updated_at=now(),remaining_seconds=900,current_position=1,runtime_updated_at=now(),
        blueprint=blueprint||jsonb_build_object('lunaCriticPassed',true,'lunaCriticScore',v_score,'setNo',v_set,'questionWiseLunaRepair',true)
    where session_id=p_session_id;

    return jsonb_build_object('ok',true,'status','ready','setNo',v_set,'score',v_score,'repairRound',s.repair_round);
  end if;

  if malformed or coalesce((checks->>'exactly25')::boolean,false)=false
     or (decision='REJECT_GLOBAL' and jsonb_array_length(merged_repairs)=0) then
    update english.sprint_sessions
    set status='critic_failed',critic_status='rejected',luna_critic=coalesce(p_report,'{}'::jsonb),
        critic_error=coalesce(nullif(p_report->>'summary',''),'Luna found a non-isolatable set-level defect'),critic_updated_at=now()
    where session_id=p_session_id;
    return jsonb_build_object('ok',true,'status','critic_failed','setNo',null,'score',v_score,'globalReject',true);
  end if;

  if jsonb_array_length(merged_repairs)>0 then
    update english.sprint_sessions
    set status='critic_pending',critic_status='repair_needed',
        luna_critic=coalesce(p_report,'{}'::jsonb)||jsonb_build_object('repairPositions',merged_repairs,'decision','REPAIR'),
        critic_error=coalesce(nullif(p_report->>'summary',''),'Luna requested question-level repair'),critic_updated_at=now(),
        blueprint=blueprint||jsonb_build_object('questionWiseLunaRepair',true,'lastRepairRequestedAt',now())
    where session_id=p_session_id;
    return jsonb_build_object('ok',true,'status','critic_pending','criticStatus','repair_needed','setNo',null,'score',v_score,'repairPositions',merged_repairs,'repairRound',s.repair_round);
  end if;

  update english.sprint_sessions
  set status='critic_failed',critic_status='rejected',luna_critic=coalesce(p_report,'{}'::jsonb),
      critic_error='Luna set checks failed without identifiable repair positions',critic_updated_at=now()
  where session_id=p_session_id;
  return jsonb_build_object('ok',true,'status','critic_failed','setNo',null,'score',v_score,'globalReject',true);
end
$function$;

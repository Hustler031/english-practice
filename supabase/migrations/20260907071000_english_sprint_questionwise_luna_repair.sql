-- Question-wise Luna repair loop for ChatGPT-prepared SSC Sprint sets.
-- Luna still audits all 25 items together for cross-question quality, but isolated
-- defects now request repair of only the affected positions. Passed positions stay
-- frozen. A set becomes ready only after a subsequent full-set Luna PASS.

alter table english.sprint_sessions
  add column if not exists repair_round integer not null default 0,
  add column if not exists repair_history jsonb not null default '[]'::jsonb;

alter table english.sprint_sessions
  drop constraint if exists sprint_sessions_critic_status_check;
alter table english.sprint_sessions
  add constraint sprint_sessions_critic_status_check
  check (critic_status in ('none','queued','processing','repair_needed','passed','rejected','error'));

create or replace function english.sprint_repair_self_critic_passes(p_report jsonb,p_positions jsonb)
returns boolean
language sql
immutable
set search_path to 'pg_catalog'
as $function$
select
  jsonb_typeof(coalesce(p_report,'null'::jsonb))='object'
  and upper(coalesce(p_report->>'decision',''))='PASS'
  and coalesce((p_report->>'score')::numeric,0)>=90
  and jsonb_typeof(coalesce(p_report->'items','null'::jsonb))='array'
  and jsonb_typeof(coalesce(p_positions,'null'::jsonb))='array'
  and jsonb_array_length(p_report->'items')=jsonb_array_length(p_positions)
  and not exists(
    select 1
    from jsonb_array_elements(p_report->'items') x
    where upper(coalesce(x->>'verdict',''))<>'PASS'
       or not (x ? 'position')
       or not exists(
         select 1 from jsonb_array_elements_text(p_positions) p
         where p::integer=(x->>'position')::integer
       )
  )
  and not exists(
    select 1 from jsonb_array_elements_text(p_positions) p
    where not exists(
      select 1 from jsonb_array_elements(p_report->'items') x
      where (x->>'position')::integer=p::integer
    )
  );
$function$;

-- Connector-only repair boundary. ChatGPT may replace only the positions Luna
-- explicitly marked REPAIR. Passed positions cannot be edited through this path.
create or replace function english.repair_chatgpt_sprint(
  p_session_id uuid,
  p_repairs jsonb,
  p_self_critic jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  owner_id uuid;
  owner_count integer;
  s english.sprint_sessions%rowtype;
  expected jsonb;
  previous_luna jsonb;
  x jsonb;
  supplied_positions integer[]:=array[]::integer[];
  pos integer;
  opts jsonb;
  ck text;
  st text;
  qt text;
  qs text;
  cat text;
  expl text;
  cq text;
  meta jsonb;
  tier text;
  domain_name text;
  concept_key text;
  quality numeric;
  old_tier text;
  old_domain text;
  repaired integer:=0;
begin
  select count(*),max(id::text)::uuid into owner_count,owner_id
  from auth.users where deleted_at is null;
  if owner_count<>1 then raise exception 'ChatGPT Sprint repair requires exactly one active auth owner'; end if;

  select * into s
  from english.sprint_sessions
  where session_id=p_session_id and user_id=owner_id and mode='standard' and prepared_by='chatgpt'
  for update;
  if not found then raise exception 'ChatGPT Sprint repair session not found'; end if;
  if s.status<>'critic_pending' or s.critic_status<>'repair_needed' then
    raise exception 'Sprint is not waiting for question repair';
  end if;

  expected:=coalesce(s.luna_critic->'repairPositions','[]'::jsonb);
  previous_luna:=coalesce(s.luna_critic,'{}'::jsonb);
  if jsonb_typeof(expected)<>'array' or jsonb_array_length(expected)=0 then
    raise exception 'Luna repair positions are missing';
  end if;
  if jsonb_typeof(coalesce(p_repairs,'null'::jsonb))<>'array'
     or jsonb_array_length(p_repairs)<>jsonb_array_length(expected) then
    raise exception 'Repair payload must replace every Luna-requested position exactly once';
  end if;
  if not english.sprint_repair_self_critic_passes(p_self_critic,expected) then
    raise exception 'ChatGPT repair self-critic must PASS every requested repair with score >= 90';
  end if;

  perform pg_advisory_xact_lock(hashtext('english.repair_chatgpt_sprint'),hashtext(p_session_id::text));

  for x in select value from jsonb_array_elements(p_repairs) loop
    pos:=coalesce((x->>'position')::integer,0);
    if pos<1 or pos>25 then raise exception 'Invalid Sprint repair position %',pos; end if;
    if pos=any(supplied_positions) then raise exception 'Duplicate Sprint repair position %',pos; end if;
    if not exists(select 1 from jsonb_array_elements_text(expected) p where p::integer=pos) then
      raise exception 'Position % was not requested by Luna and is frozen',pos;
    end if;
    supplied_positions:=array_append(supplied_positions,pos);

    select coalesce(metadata->>'difficultyTier',''),coalesce(metadata->>'domain','')
      into old_tier,old_domain
    from english.sprint_items where session_id=p_session_id and position=pos;
    if not found then raise exception 'Sprint item % not found',pos; end if;

    opts:=coalesce(x->'options','[]'::jsonb);
    ck:=upper(coalesce(x->>'correctKey',''));
    st:=coalesce(nullif(x->>'sourceType',''),'GPT Generated');
    if st not in ('GPT Generated','GPT Variant of Known Concept') then st:='GPT Generated'; end if;
    qt:=btrim(coalesce(x->>'questionType',''));
    qs:=btrim(coalesce(x->>'question',''));
    cat:=btrim(coalesce(x->>'category','English'));
    expl:=btrim(coalesce(x->>'explanation',''));
    cq:=nullif(btrim(coalesce(x->>'canonicalQuestionId','')),'');
    meta:=coalesce(x->'metadata','{}'::jsonb);
    quality:=coalesce((x->>'qualityScore')::numeric,(meta->>'qualityScore')::numeric,0.90);
    tier:=coalesce(meta->>'difficultyTier','');
    domain_name:=coalesce(meta->>'domain','');
    concept_key:=btrim(coalesce(meta->>'conceptKey',''));

    if qs='' or expl='' or not english.sprint_allowed_type(qt) or not english.sprint_validate_options(opts,ck) then
      raise exception 'Invalid repaired Sprint item at position %',pos;
    end if;
    if tier<>old_tier or domain_name<>old_domain then
      raise exception 'Repair at position % must preserve target difficulty/domain (%/%)',pos,old_tier,old_domain;
    end if;
    if concept_key='' then raise exception 'Missing conceptKey in repaired position %',pos; end if;
    if btrim(coalesce(meta->>'trapTested',''))='' or btrim(coalesce(meta->>'generationReason',''))='' then
      raise exception 'Missing Sprint quality metadata in repaired position %',pos;
    end if;
    if jsonb_typeof(meta->'discriminationScore') is distinct from 'number'
       or jsonb_typeof(meta->'trapStrength') is distinct from 'number' then
      raise exception 'Missing numeric discrimination metadata in repaired position %',pos;
    end if;
    if quality<0.85 then raise exception 'Repaired Sprint item % has qualityScore below 0.85',pos; end if;

    if exists(
      select 1
      from english.sprint_sessions os
      join english.sprint_items oi on oi.session_id=os.session_id
      where os.user_id=owner_id and os.mode='standard' and os.status='completed'
        and english.sprint_normalized_question(oi.question)=english.sprint_normalized_question(qs)
    ) then raise exception 'Historical Sprint question repetition rejected at repaired position %',pos; end if;

    -- Compare with all frozen positions and any repaired positions already applied in this transaction.
    if exists(
      select 1 from english.sprint_items cur
      where cur.session_id=p_session_id and cur.position<>pos and (
        english.sprint_normalized_question(cur.question)=english.sprint_normalized_question(qs)
        or lower(btrim(coalesce(cur.metadata->>'conceptKey','')))=lower(concept_key)
      )
    ) then raise exception 'Duplicate Sprint question/concept after repair at position %',pos; end if;

    if cq is not null and not exists(select 1 from english.questions q where q.question_id=cq) then cq:=null; end if;

    update english.sprint_items
    set canonical_question_id=cq,
        source_type=st,
        category=cat,
        question_type=qt,
        question=qs,
        options=opts,
        correct_key=ck,
        explanation=expl,
        metadata=meta||jsonb_build_object(
          'qualityScore',quality,
          'chatgptSelfCriticPassed',true,
          'chatgptRepairSelfCriticPassed',true,
          'chatgptRepairRound',s.repair_round+1
        )
    where session_id=p_session_id and position=pos;
    repaired:=repaired+1;
  end loop;

  if repaired<>jsonb_array_length(expected) then
    raise exception 'Not all Luna-requested positions were repaired';
  end if;

  update english.sprint_sessions
  set repair_round=repair_round+1,
      repair_history=repair_history||jsonb_build_array(jsonb_build_object(
        'round',repair_round+1,
        'positions',expected,
        'lunaReport',previous_luna,
        'chatgptSelfCritic',coalesce(p_self_critic,'{}'::jsonb),
        'repairedAt',now()
      )),
      critic_status='queued',
      critic_attempts=0,
      critic_updated_at=now(),
      critic_error=null,
      luna_critic='{}'::jsonb,
      blueprint=blueprint||jsonb_build_object('lastQuestionRepairAt',now(),'questionWiseLunaRepair',true)
  where session_id=p_session_id;

  perform english.kick_sprint_critic_worker(p_session_id);
  return jsonb_build_object('ok',true,'sessionId',p_session_id,'status','critic_pending','criticStatus','queued','repairedPositions',expected,'repairRound',s.repair_round+1);
end
$function$;

revoke all on function english.repair_chatgpt_sprint(uuid,jsonb,jsonb) from public,anon,authenticated;
revoke all on function english.sprint_repair_self_critic_passes(jsonb,jsonb) from public,anon,authenticated;

create or replace function english.kick_sprint_critic_worker(p_session_id uuid)
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog','english','net'
as $function$
declare
  v_token text;
  req bigint;
begin
  if not exists(
    select 1 from english.sprint_sessions
    where session_id=p_session_id and status='critic_pending' and critic_attempts<3
      and (
        critic_status in ('queued','error')
        or (critic_status='processing' and coalesce(critic_updated_at,created_at)<now()-interval '4 minutes')
      )
  ) then return 0; end if;

  select token into v_token from english.context_ai_runtime_guard where singleton=true;
  if v_token is null then raise exception 'English runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-sprint-critic-worker',
    body:=jsonb_build_object('sessionId',p_session_id),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=90000
  ) into req;

  insert into english.context_worker_requests(request_id,lane,requested_at)
  values(req,'sprint_critic',now()) on conflict(request_id) do nothing;
  return req;
end
$function$;

create or replace function public.english_sprint_critic_worker_claim(p_token text,p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  s english.sprint_sessions%rowtype;
  payload jsonb;
  hist jsonb;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'Unauthorized Sprint critic worker'; end if;
  select * into s from english.sprint_sessions where session_id=p_session_id for update;
  if not found then return jsonb_build_object('ok',true,'claimed',false,'reason','not_found'); end if;
  if s.status<>'critic_pending' then return jsonb_build_object('ok',true,'claimed',false,'reason',s.status); end if;
  if s.critic_status='repair_needed' then return jsonb_build_object('ok',true,'claimed',false,'reason','repair_needed'); end if;
  if s.critic_status not in ('queued','error','processing') then return jsonb_build_object('ok',true,'claimed',false,'reason',s.critic_status); end if;
  if s.critic_attempts>=3 then
    update english.sprint_sessions set status='critic_failed',critic_status='rejected',critic_error='Luna critic transport retries exhausted',critic_updated_at=now() where session_id=p_session_id;
    return jsonb_build_object('ok',true,'claimed',false,'reason','retries_exhausted');
  end if;
  if s.critic_status='processing' and coalesce(s.critic_updated_at,s.created_at)>now()-interval '3 minutes' then
    return jsonb_build_object('ok',true,'claimed',false,'reason','busy');
  end if;

  update english.sprint_sessions
  set critic_status='processing',critic_attempts=critic_attempts+1,critic_updated_at=now(),critic_error=null
  where session_id=p_session_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'position',i.position,'category',i.category,'questionType',i.question_type,
    'question',i.question,'options',i.options,'correctKey',i.correct_key,
    'explanation',i.explanation,'metadata',i.metadata
  ) order by i.position),'[]'::jsonb)
  into payload from english.sprint_items i where i.session_id=p_session_id;

  with recent_sessions as (
    select session_id,completed_at
    from english.sprint_sessions
    where user_id=s.user_id and mode='standard' and status='completed'
    order by completed_at desc,session_id desc
    limit 8
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'question',i.question,
    'conceptKey',coalesce(i.metadata->>'conceptKey',''),
    'completedAt',rs.completed_at
  ) order by rs.completed_at desc,i.position),'[]'::jsonb)
  into hist
  from recent_sessions rs join english.sprint_items i on i.session_id=rs.session_id;

  return jsonb_build_object(
    'ok',true,'claimed',true,'sessionId',p_session_id,
    'items',payload,'blueprint',s.blueprint,'selfCritic',s.self_critic,
    'historicalItems',hist,'attempt',s.critic_attempts+1,'repairRound',s.repair_round
  );
end
$function$;

create or replace function public.english_sprint_critic_worker_apply(p_token text,p_session_id uuid,p_report jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  s english.sprint_sessions%rowtype;
  decision text:=upper(coalesce(p_report->>'decision',''));
  score numeric:=coalesce((p_report->>'score')::numeric,0);
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

  -- Deterministic historical replay guard remains authoritative. Convert any
  -- replay into position-level repair rather than rejecting the whole set.
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

  if decision='PASS' and score>=90 and pass_checks and pass_items and jsonb_array_length(historical_positions)=0 then
    perform pg_advisory_xact_lock(hashtext('english.sprint.set_no'),hashtext(s.user_id::text));
    if exists(select 1 from english.sprint_sessions where user_id=s.user_id and status in ('in_progress','paused') and session_id<>p_session_id) then
      raise exception 'Another Sprint became active while Luna was reviewing this set';
    end if;
    update english.sprint_sessions
    set status='abandoned',blueprint=blueprint||jsonb_build_object('supersededByLunaPassedSet',true,'supersededAt',now())
    where user_id=s.user_id and status='ready' and session_id<>p_session_id;

    select coalesce(max(set_no),0)+1 into v_set
    from english.sprint_sessions where user_id=s.user_id and mode='standard' and set_no is not null;

    update english.sprint_sessions
    set status='ready',set_no=v_set,critic_status='passed',luna_critic=coalesce(p_report,'{}'::jsonb),
        critic_error=null,critic_updated_at=now(),remaining_seconds=900,current_position=1,runtime_updated_at=now(),
        blueprint=blueprint||jsonb_build_object('lunaCriticPassed',true,'lunaCriticScore',score,'setNo',v_set,'questionWiseLunaRepair',true)
    where session_id=p_session_id;

    return jsonb_build_object('ok',true,'status','ready','setNo',v_set,'score',score,'repairRound',s.repair_round);
  end if;

  -- Global rejection is reserved for malformed/non-isolatable set-level failures.
  if malformed or coalesce((checks->>'exactly25')::boolean,false)=false
     or (decision='REJECT_GLOBAL' and jsonb_array_length(merged_repairs)=0) then
    update english.sprint_sessions
    set status='critic_failed',critic_status='rejected',luna_critic=coalesce(p_report,'{}'::jsonb),
        critic_error=coalesce(nullif(p_report->>'summary',''),'Luna found a non-isolatable set-level defect'),critic_updated_at=now()
    where session_id=p_session_id;
    return jsonb_build_object('ok',true,'status','critic_failed','setNo',null,'score',score,'globalReject',true);
  end if;

  -- Any isolated defect becomes a repair request. Do not re-run Luna on unchanged
  -- content; the retry scheduler excludes repair_needed until ChatGPT replaces it.
  if jsonb_array_length(merged_repairs)>0 then
    update english.sprint_sessions
    set status='critic_pending',critic_status='repair_needed',
        luna_critic=coalesce(p_report,'{}'::jsonb)||jsonb_build_object('repairPositions',merged_repairs,'decision','REPAIR'),
        critic_error=coalesce(nullif(p_report->>'summary',''),'Luna requested question-level repair'),critic_updated_at=now(),
        blueprint=blueprint||jsonb_build_object('questionWiseLunaRepair',true,'lastRepairRequestedAt',now())
    where session_id=p_session_id;
    return jsonb_build_object('ok',true,'status','critic_pending','criticStatus','repair_needed','setNo',null,'score',score,'repairPositions',merged_repairs,'repairRound',s.repair_round);
  end if;

  update english.sprint_sessions
  set status='critic_failed',critic_status='rejected',luna_critic=coalesce(p_report,'{}'::jsonb),
      critic_error='Luna set checks failed without identifiable repair positions',critic_updated_at=now()
  where session_id=p_session_id;
  return jsonb_build_object('ok',true,'status','critic_failed','setNo',null,'score',score,'globalReject',true);
end
$function$;

create or replace function english.retry_pending_sprint_critics()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $function$
declare r record; n integer:=0;
begin
  for r in
    select session_id
    from english.sprint_sessions
    where status='critic_pending' and critic_attempts<3
      and (
        critic_status in ('queued','error')
        or (critic_status='processing' and coalesce(critic_updated_at,created_at)<now()-interval '4 minutes')
      )
    order by created_at
    limit 3
  loop
    perform english.kick_sprint_critic_worker(r.session_id); n:=n+1;
  end loop;
  return n;
end
$function$;

create or replace function public.english_get_chatgpt_sprint_state()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with latest as (
  select * from english.sprint_sessions
  where user_id=auth.uid() and mode='standard' and prepared_by='chatgpt'
  order by created_at desc,session_id desc limit 1
), active as (
  select * from english.sprint_sessions
  where user_id=auth.uid() and mode='standard' and status in ('ready','in_progress','paused')
  order by created_at desc,session_id desc limit 1
)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object(
  'ok',true,
  'active',exists(select 1 from active),
  'sessionId',coalesce((select session_id from active),(select session_id from latest)),
  'status',coalesce((select status from active),(select status from latest),'idle'),
  'setNo',coalesce((select set_no from active),(select set_no from latest)),
  'criticStatus',(select critic_status from latest),
  'criticAttempts',coalesce((select critic_attempts from latest),0),
  'criticError',(select critic_error from latest),
  'criticScore',(select nullif(luna_critic->>'score','')::numeric from latest),
  'repairPositions',coalesce((select luna_critic->'repairPositions' from latest),'[]'::jsonb),
  'repairRound',coalesce((select repair_round from latest),0),
  'createdAt',(select created_at from latest),
  'preparedBy',(select prepared_by from latest)
) end;
$function$;

-- Keep the Sprint state endpoint signed-in only after replacing its definition.
revoke execute on function public.english_get_chatgpt_sprint_state() from public,anon;
grant execute on function public.english_get_chatgpt_sprint_state() to authenticated,service_role;

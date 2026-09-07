-- ChatGPT-prepared SSC Sprint sets.
-- Generation moves out of the app: ChatGPT prepares + self-critiques 25 items,
-- then this backend stages the set and an independent Luna worker performs the
-- final full-set pre-serve gate. Only Luna-passed sets become ready to start.

alter table english.sprint_sessions
  drop constraint if exists sprint_sessions_status_check;

alter table english.sprint_sessions
  add constraint sprint_sessions_status_check
  check (status = any (array[
    'critic_pending'::text,'critic_failed'::text,
    'ready'::text,'in_progress'::text,'paused'::text,
    'completed'::text,'abandoned'::text
  ]));

alter table english.sprint_sessions
  add column if not exists set_no integer,
  add column if not exists prepared_by text,
  add column if not exists self_critic jsonb not null default '{}'::jsonb,
  add column if not exists luna_critic jsonb not null default '{}'::jsonb,
  add column if not exists critic_status text not null default 'none',
  add column if not exists critic_attempts integer not null default 0,
  add column if not exists critic_updated_at timestamptz,
  add column if not exists critic_error text;

alter table english.sprint_sessions
  drop constraint if exists sprint_sessions_critic_status_check;
alter table english.sprint_sessions
  add constraint sprint_sessions_critic_status_check
  check (critic_status in ('none','queued','processing','passed','rejected','error'));

-- Give the five existing completed Standard attempts stable historical set numbers.
with ranked as (
  select session_id,
         row_number() over(partition by user_id order by completed_at,created_at,session_id)::integer rn
  from english.sprint_sessions
  where mode='standard' and status='completed'
)
update english.sprint_sessions s
set set_no=r.rn
from ranked r
where r.session_id=s.session_id and s.set_no is null;

create unique index if not exists english_sprint_standard_set_no_uidx
  on english.sprint_sessions(user_id,set_no)
  where mode='standard' and set_no is not null;

create index if not exists english_sprint_critic_queue_idx
  on english.sprint_sessions(status,critic_status,critic_updated_at)
  where status='critic_pending';

create or replace function english.sprint_normalized_question(p_question text)
returns text
language sql
immutable
set search_path to 'pg_catalog'
as $function$
select regexp_replace(lower(btrim(coalesce(p_question,''))),'\s+',' ','g');
$function$;

create or replace function english.sprint_self_critic_passes(p_report jsonb)
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
  and jsonb_array_length(p_report->'items')=25
  and not exists(
    select 1
    from jsonb_array_elements(p_report->'items') x
    where upper(coalesce(x->>'verdict',''))<>'PASS'
  );
$function$;

-- Connector-only staging owner. This intentionally does not depend on auth.uid():
-- the connected Supabase maintenance path is the publication boundary and the app
-- remains single-owner. The function is not granted to browser roles below.
create or replace function english.stage_chatgpt_sprint(
  p_items jsonb,
  p_blueprint jsonb default '{}'::jsonb,
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
  sid uuid:=gen_random_uuid();
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
  tier text;
  domain_name text;
  concept_key text;
  quality numeric;
  v_easy integer:=0;
  v_moderate integer:=0;
  v_hard integer:=0;
  v_grammar integer:=0;
  v_lexical integer:=0;
  expected_easy integer;
  expected_moderate integer;
  expected_hard integer;
  expected_grammar integer;
  expected_lexical integer;
begin
  select count(*),max(id::text)::uuid into owner_count,owner_id
  from auth.users where deleted_at is null;
  if owner_count<>1 then raise exception 'ChatGPT Sprint requires exactly one active auth owner'; end if;

  perform pg_advisory_xact_lock(hashtext('english.stage_chatgpt_sprint'),hashtext(owner_id::text));

  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)<>25 then
    raise exception 'ChatGPT Standard Sprint requires exactly 25 questions';
  end if;
  if not english.sprint_self_critic_passes(p_self_critic) then
    raise exception 'ChatGPT self-critic must PASS all 25 questions with score >= 90 before staging';
  end if;

  if exists(
    select 1 from english.sprint_sessions
    where user_id=owner_id and status in ('in_progress','paused')
  ) then raise exception 'Finish or abandon the active Sprint before preparing another set'; end if;

  -- An unstarted older ready set is safely superseded by the newly requested set.
  update english.sprint_sessions
  set status='abandoned',
      blueprint=blueprint||jsonb_build_object('supersededByChatgptSet',true,'supersededAt',now()),
      runtime_updated_at=now()
  where user_id=owner_id and status='ready';

  update english.sprint_sessions
  set status='critic_failed',critic_status='rejected',critic_error='Superseded by a newer ChatGPT set',critic_updated_at=now()
  where user_id=owner_id and status='critic_pending';

  insert into english.sprint_sessions(
    session_id,user_id,mode,status,question_count,started_at,remaining_seconds,current_position,
    blueprint,prepared_by,self_critic,critic_status,critic_attempts,critic_updated_at
  ) values(
    sid,owner_id,'standard','critic_pending',25,now(),900,1,
    coalesce(p_blueprint,'{}'::jsonb)||jsonb_build_object(
      'generationProvider','ChatGPT conversation',
      'chatgptSelfCritic',true,
      'startImmediately',false,
      'stagedAt',now()
    ),
    'chatgpt',coalesce(p_self_critic,'{}'::jsonb),'queued',0,now()
  );

  for x in select value from jsonb_array_elements(p_items) loop
    pos:=pos+1;
    opts:=coalesce(x->'options','[]'::jsonb);
    ck:=upper(coalesce(x->>'correctKey',''));
    st:=coalesce(nullif(x->>'sourceType',''),'GPT Generated');
    if st not in ('GPT Generated','GPT Variant of Known Concept') then st:='GPT Generated'; end if;
    qt:=btrim(coalesce(x->>'questionType',''));
    qs:=btrim(coalesce(x->>'question',''));
    cat:=btrim(coalesce(x->>'category','English'));
    expl:=btrim(coalesce(x->>'explanation',''));
    itemkey:=coalesce(nullif(x->>'itemKey',''),'chatgpt-'||substr(sid::text,1,8)||'-'||lpad(pos::text,2,'0'));
    cq:=nullif(btrim(coalesce(x->>'canonicalQuestionId','')),'');
    meta:=coalesce(x->'metadata','{}'::jsonb);
    quality:=coalesce((x->>'qualityScore')::numeric,(meta->>'qualityScore')::numeric,0.90);
    tier:=coalesce(meta->>'difficultyTier','');
    domain_name:=coalesce(meta->>'domain','');
    concept_key:=btrim(coalesce(meta->>'conceptKey',''));

    if qs='' or expl='' or not english.sprint_allowed_type(qt) or not english.sprint_validate_options(opts,ck) then
      raise exception 'Invalid ChatGPT Sprint item at position %',pos;
    end if;
    if tier not in ('Easy','Moderate','Hard') then raise exception 'Invalid difficulty tier at position %',pos; end if;
    if domain_name not in ('GrammarTransformation','LexicalUsage') then raise exception 'Invalid domain at position %',pos; end if;
    if concept_key='' then raise exception 'Missing conceptKey at position %',pos; end if;
    if btrim(coalesce(meta->>'trapTested',''))='' or btrim(coalesce(meta->>'generationReason',''))='' then
      raise exception 'Missing Sprint quality metadata at position %',pos;
    end if;
    if jsonb_typeof(meta->'discriminationScore') is distinct from 'number'
       or jsonb_typeof(meta->'trapStrength') is distinct from 'number' then
      raise exception 'Missing numeric discrimination metadata at position %',pos;
    end if;
    if quality<0.85 then raise exception 'ChatGPT item % has qualityScore below 0.85',pos; end if;

    -- Never replay an exact question the learner already completed in any Standard Sprint.
    if exists(
      select 1
      from english.sprint_sessions os
      join english.sprint_items oi on oi.session_id=os.session_id
      where os.user_id=owner_id and os.mode='standard' and os.status='completed'
        and english.sprint_normalized_question(oi.question)=english.sprint_normalized_question(qs)
    ) then raise exception 'Historical Sprint question repetition rejected at position %',pos; end if;

    -- Current-set exact and concept-key duplicates are deterministic hard failures.
    if exists(
      select 1 from english.sprint_items cur
      where cur.session_id=sid and (
        english.sprint_normalized_question(cur.question)=english.sprint_normalized_question(qs)
        or lower(btrim(coalesce(cur.metadata->>'conceptKey','')))=lower(concept_key)
      )
    ) then raise exception 'Duplicate Sprint question/concept at position %',pos; end if;

    if cq is not null and not exists(select 1 from english.questions q where q.question_id=cq) then cq:=null; end if;

    insert into english.sprint_items(
      session_id,position,item_key,canonical_question_id,source_type,category,question_type,
      question,options,correct_key,explanation,metadata
    ) values(
      sid,pos,itemkey,cq,st,cat,qt,qs,opts,ck,expl,
      meta||jsonb_build_object('qualityScore',quality,'chatgptSelfCriticPassed',true)
    );

    if tier='Easy' then v_easy:=v_easy+1;
    elsif tier='Moderate' then v_moderate:=v_moderate+1;
    else v_hard:=v_hard+1; end if;
    if domain_name='GrammarTransformation' then v_grammar:=v_grammar+1; else v_lexical:=v_lexical+1; end if;
  end loop;

  expected_easy:=coalesce((p_blueprint->'difficulty'->>'easy')::int,5);
  expected_moderate:=coalesce((p_blueprint->'difficulty'->>'moderate')::int,13);
  expected_hard:=coalesce((p_blueprint->'difficulty'->>'hard')::int,7);
  expected_grammar:=coalesce((p_blueprint->'questionMix'->>'grammarTransformation')::int,11);
  expected_lexical:=coalesce((p_blueprint->'questionMix'->>'lexicalUsage')::int,14);
  if v_easy<>expected_easy or v_moderate<>expected_moderate or v_hard<>expected_hard then
    raise exception 'Sprint difficulty distribution mismatch: got %/%/%, expected %/%/%',v_easy,v_moderate,v_hard,expected_easy,expected_moderate,expected_hard;
  end if;
  if v_grammar<>expected_grammar or v_lexical<>expected_lexical then
    raise exception 'Sprint domain mix mismatch: got %/%, expected %/%',v_grammar,v_lexical,expected_grammar,expected_lexical;
  end if;

  perform english.kick_sprint_critic_worker(sid);
  return jsonb_build_object('ok',true,'sessionId',sid,'status','critic_pending','critic','luna','setNo',null);
exception when others then
  if sid is not null then delete from english.sprint_sessions where session_id=sid; end if;
  raise;
end
$function$;

-- Worker kick. pg_net dispatches after transaction commit, so the staged rows are
-- visible before the Luna worker claims them.
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
  if s.critic_attempts>=3 then
    update english.sprint_sessions set status='critic_failed',critic_status='rejected',critic_error='Luna critic retries exhausted',critic_updated_at=now() where session_id=p_session_id;
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
    'historicalItems',hist,'attempt',s.critic_attempts+1
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
  pass_checks boolean;
  pass_items boolean;
  v_set integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'Unauthorized Sprint critic worker'; end if;
  select * into s from english.sprint_sessions where session_id=p_session_id for update;
  if not found then raise exception 'Sprint critic session not found'; end if;
  if s.status<>'critic_pending' then return jsonb_build_object('ok',true,'status',s.status,'setNo',s.set_no); end if;

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

  pass_items:=jsonb_typeof(coalesce(p_report->'itemVerdicts','null'::jsonb))='array'
    and jsonb_array_length(p_report->'itemVerdicts')=25
    and not exists(
      select 1 from jsonb_array_elements(p_report->'itemVerdicts') x
      where coalesce((x->>'pass')::boolean,false)=false
    );

  -- Re-run exact historical replay protection at the final publication boundary.
  if exists(
    select 1
    from english.sprint_items ni
    join english.sprint_sessions ns on ns.session_id=ni.session_id
    where ns.session_id=p_session_id
      and exists(
        select 1 from english.sprint_sessions os
        join english.sprint_items oi on oi.session_id=os.session_id
        where os.user_id=ns.user_id and os.mode='standard' and os.status='completed'
          and english.sprint_normalized_question(oi.question)=english.sprint_normalized_question(ni.question)
      )
  ) then
    pass_checks:=false;
  end if;

  if decision='PASS' and score>=90 and pass_checks and pass_items then
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
        blueprint=blueprint||jsonb_build_object('lunaCriticPassed',true,'lunaCriticScore',score,'setNo',v_set)
    where session_id=p_session_id;

    return jsonb_build_object('ok',true,'status','ready','setNo',v_set,'score',score);
  end if;

  update english.sprint_sessions
  set status='critic_failed',critic_status='rejected',luna_critic=coalesce(p_report,'{}'::jsonb),
      critic_error=coalesce(nullif(p_report->>'summary',''),'Luna critic rejected this set'),critic_updated_at=now()
  where session_id=p_session_id;
  return jsonb_build_object('ok',true,'status','critic_failed','setNo',null,'score',score);
end
$function$;

create or replace function public.english_sprint_critic_worker_error(p_token text,p_session_id uuid,p_error text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare attempts integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'Unauthorized Sprint critic worker'; end if;
  select critic_attempts into attempts from english.sprint_sessions where session_id=p_session_id for update;
  if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
  update english.sprint_sessions
  set status=case when coalesce(attempts,0)>=3 then 'critic_failed' else 'critic_pending' end,
      critic_status=case when coalesce(attempts,0)>=3 then 'rejected' else 'error' end,
      critic_error=left(coalesce(nullif(btrim(p_error),''),'Luna critic worker error'),1200),
      critic_updated_at=now()
  where session_id=p_session_id;
  return jsonb_build_object('ok',true,'retryable',coalesce(attempts,0)<3,'attempts',attempts);
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
      and (critic_status in ('queued','error') or coalesce(critic_updated_at,created_at)<now()-interval '4 minutes')
    order by created_at
    limit 3
  loop
    perform english.kick_sprint_critic_worker(r.session_id); n:=n+1;
  end loop;
  return n;
end
$function$;

-- Browser read model for the ChatGPT-set landing page.
create or replace function public.english_get_chatgpt_sprint_state()
returns jsonb
language sql
stable security definer
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
  'sessionId',(select session_id from active),
  'status',coalesce((select status from active),(select status from latest),'idle'),
  'setNo',coalesce((select set_no from active),(select set_no from latest)),
  'criticStatus',(select critic_status from latest),
  'criticAttempts',coalesce((select critic_attempts from latest),0),
  'criticError',(select critic_error from latest),
  'criticScore',(select nullif(luna_critic->>'score','')::numeric from latest),
  'createdAt',(select created_at from latest),
  'preparedBy',(select prepared_by from latest)
) end;
$function$;

-- Add stable set identity to the existing session payload.
create or replace function public.english_get_sprint_session(p_session_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with s as (
  select *,case
    when status='in_progress' then greatest(0,coalesce(remaining_seconds,900)-greatest(0,floor(extract(epoch from (now()-coalesce(runtime_updated_at,started_at))))::integer))
    else greatest(0,coalesce(remaining_seconds,900))
  end effective_remaining
  from english.sprint_sessions
  where session_id=p_session_id and user_id=auth.uid()
), i as (
  select x.*,a.selected_key,a.time_seconds,a.visited,a.marked_for_review,a.diagnosis,a.action,a.confused_with
  from english.sprint_items x join s on s.session_id=x.session_id
  left join english.sprint_answers a on a.session_id=x.session_id and a.position=x.position and a.user_id=auth.uid()
  order by x.position
)
select case when not exists(select 1 from s) then jsonb_build_object('ok',false,'error','Sprint not found')
else jsonb_build_object(
  'ok',true,'sessionId',(select session_id from s),'setNo',(select set_no from s),
  'mode',(select mode from s),'status',(select status from s),'criticStatus',(select critic_status from s),
  'startedAt',(select started_at from s),'completedAt',(select completed_at from s),'pausedAt',(select paused_at from s),
  'questionCount',(select question_count from s),'durationLimitSeconds',900,'remainingSeconds',(select effective_remaining from s),
  'currentPosition',least((select question_count from s),greatest(1,(select current_position from s))),
  'items',coalesce((select jsonb_agg(
    case when (select status from s)='completed' then jsonb_build_object(
      'position',position,'category',category,'questionType',question_type,'question',question,'options',options,
      'selectedKey',selected_key,'visited',coalesce(visited,false),'markedForReview',coalesce(marked_for_review,false),
      'timeSeconds',coalesce(time_seconds,0),'correctKey',correct_key,'explanation',explanation,'sourceType',source_type,
      'canonicalQuestionId',canonical_question_id,'diagnosis',diagnosis,'action',action,'confusedWith',confused_with
    ) else jsonb_build_object(
      'position',position,'category',category,'questionType',question_type,'question',question,'options',options,
      'selectedKey',selected_key,'visited',coalesce(visited,false),'markedForReview',coalesce(marked_for_review,false),
      'timeSeconds',coalesce(time_seconds,0)
    ) end order by position) from i),'[]'::jsonb),
  'result',case when (select status from s)='completed' then jsonb_build_object(
    'score',(select score from s),'maxMarks',(select question_count*2 from s),'correct',(select correct_count from s),
    'wrong',(select wrong_count from s),'unanswered',(select unanswered_count from s),'accuracy',(select accuracy from s),
    'durationSeconds',(select duration_seconds from s),'analysis',(select analysis from s)
  ) else null end
) end;
$function$;

-- Archive is permanent, not a 5-day view. Keep the existing p_days signature for
-- frontend compatibility while returning up to 100 completed Standard sets.
create or replace function public.english_get_recent_sprint_reports(p_days integer default 3650)
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with recent as (
  select s.* from english.sprint_sessions s
  where s.user_id=auth.uid() and s.status='completed' and s.mode='standard'
  order by s.set_no desc nulls last,s.completed_at desc,s.session_id desc
  limit 100
)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required')
else jsonb_build_object('ok',true,'days',3650,'items',coalesce((
  select jsonb_agg(jsonb_build_object(
    'sessionId',session_id,'setNo',set_no,'mode',mode,'score',score,'maxMarks',question_count*2,'questionCount',question_count,
    'correct',correct_count,'wrong',wrong_count,'unanswered',unanswered_count,'accuracy',accuracy,
    'durationSeconds',duration_seconds,'completedAt',completed_at
  ) order by set_no desc nulls last,completed_at desc,session_id desc) from recent
),'[]'::jsonb)) end;
$function$;

-- Extend the ChatGPT preparation context with hard historical replay evidence and
-- the exact next set number. ChatGPT should use this before generating a new set.
create or replace function public.english_get_chatgpt_sprint_context(p_mode text default 'standard'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  owner_id uuid; owner_count integer; base jsonb; recent jsonb; fingerprints jsonb; next_set integer;
begin
  select count(*),max(id::text)::uuid into owner_count,owner_id from auth.users where deleted_at is null;
  if owner_count<>1 then raise exception 'ChatGPT Sprint requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  base:=public.english_get_sprint_generation_context('standard');

  with rs as (
    select session_id,completed_at,set_no,row_number() over(order by completed_at desc,session_id desc) rn
    from english.sprint_sessions where user_id=owner_id and mode='standard' and status='completed'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'setNo',rs.set_no,'sessionId',i.session_id,'position',i.position,'category',i.category,'questionType',i.question_type,
    'question',i.question,'conceptKey',coalesce(i.metadata->>'conceptKey',''),'completedAt',rs.completed_at
  ) order by rs.completed_at desc,i.position),'[]'::jsonb)
  into recent from rs join english.sprint_items i on i.session_id=rs.session_id where rs.rn<=8;

  select coalesce(jsonb_agg(distinct md5(english.sprint_normalized_question(i.question))),'[]'::jsonb)
  into fingerprints
  from english.sprint_sessions s join english.sprint_items i on i.session_id=s.session_id
  where s.user_id=owner_id and s.mode='standard' and s.status='completed';

  select coalesce(max(set_no),0)+1 into next_set
  from english.sprint_sessions where user_id=owner_id and mode='standard' and set_no is not null;

  return base||jsonb_build_object(
    'manualChatgpt',true,'nextSetNumber',next_set,'recentSprintItems',recent,'historicalQuestionFingerprints',fingerprints,
    'chatgptSelfCriticContract',jsonb_build_object(
      'required',true,'decision','PASS','minimumScore',90,'itemVerdicts',25,
      'checks',jsonb_build_array('factual accuracy','exactly one answer','SSC CGL level','difficulty fit','close distractors','historical freshness','within-set semantic diversity')
    ),
    'publicationContract','Generate 25 in ChatGPT, run one full self-critic pass, then call english.stage_chatgpt_sprint. Luna independently gates the full set before it becomes ready.'
  );
end
$function$;

-- Disable the old app-side automatic generator. Analysis action remains on the old
-- Edge Function after a completed set; only creation is moved to ChatGPT.
create or replace function public.english_start_sprint_generation(p_mode text)
returns jsonb
language sql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null
  then jsonb_build_object('ok',false,'error','Authentication required')
  else jsonb_build_object('ok',false,'deprecated',true,'error','Sprint creation now happens in ChatGPT. Type create sprint in ChatGPT to prepare the next 25-question set.')
end;
$function$;

-- Old direct-ready ChatGPT publication is no longer a valid bypass around Luna.
create or replace function public.english_publish_chatgpt_sprint(p_mode text,p_items jsonb,p_blueprint jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
begin
  raise exception 'Direct Sprint publication is disabled. Use english.stage_chatgpt_sprint with a ChatGPT self-critic report; Luna must pass the set before Start Now.';
end
$function$;

revoke all on function english.stage_chatgpt_sprint(jsonb,jsonb,jsonb) from public,anon,authenticated;
revoke all on function english.kick_sprint_critic_worker(uuid) from public,anon,authenticated;
revoke all on function english.retry_pending_sprint_critics() from public,anon,authenticated;
revoke all on function public.english_sprint_critic_worker_claim(text,uuid) from public,anon,authenticated;
revoke all on function public.english_sprint_critic_worker_apply(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.english_sprint_critic_worker_error(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_sprint_critic_worker_claim(text,uuid) to service_role;
grant execute on function public.english_sprint_critic_worker_apply(text,uuid,jsonb) to service_role;
grant execute on function public.english_sprint_critic_worker_error(text,uuid,text) to service_role;
grant execute on function public.english_get_chatgpt_sprint_state() to authenticated;
grant execute on function public.english_get_recent_sprint_reports(integer) to authenticated;
grant execute on function public.english_get_sprint_session(uuid) to authenticated;

-- Retry only provider/transport errors; content rejections stay rejected and require a
-- newly prepared ChatGPT set. Ten-minute cadence is a safety net, not the fast path.
do $do$
declare v_jobid bigint;
begin
  select jobid into v_jobid from cron.job where jobname='english-sprint-critic-retry';
  if v_jobid is not null then perform cron.unschedule(v_jobid); end if;
  perform cron.schedule('english-sprint-critic-retry','*/10 * * * *','select english.retry_pending_sprint_critics();');
end
$do$;

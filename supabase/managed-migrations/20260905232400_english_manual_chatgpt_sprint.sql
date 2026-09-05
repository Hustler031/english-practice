-- Manual foreground ChatGPT Sprint publication.
-- Reuses the existing Sprint session validator and current ready -> start lifecycle.

create or replace function public.english_get_chatgpt_sprint_context(p_mode text default 'standard')
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  owner_id uuid;
  owner_count integer;
  base jsonb;
  recent jsonb;
begin
  if not english.ai_feature_enabled('chatgpt_sprint_v1') then
    raise exception 'Manual ChatGPT Sprint feature is disabled';
  end if;
  select count(*),max(id::text)::uuid into owner_count,owner_id
  from auth.users where deleted_at is null;
  if owner_count<>1 then raise exception 'Manual Sprint requires exactly one active auth owner'; end if;

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  base:=public.english_get_sprint_generation_context(p_mode);

  with five as (
    select session_id,completed_at,
      row_number() over(order by completed_at desc,session_id desc) rn
    from english.sprint_sessions
    where user_id=owner_id and status='completed'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'sessionId',i.session_id,
    'position',i.position,
    'category',i.category,
    'questionType',i.question_type,
    'question',i.question,
    'conceptKey',coalesce(i.metadata->>'conceptKey',''),
    'fingerprint',md5(regexp_replace(lower(btrim(i.question)),'\s+',' ','g')),
    'completedAt',f.completed_at
  ) order by f.completed_at desc,i.position),'[]'::jsonb)
  into recent
  from five f join english.sprint_items i on i.session_id=f.session_id
  where f.rn<=5;

  return base||jsonb_build_object(
    'manualChatgpt',true,
    'qualityThreshold',85,
    'recentSprintItems',coalesce(recent,'[]'::jsonb),
    'publicationContract','Use english_publish_chatgpt_sprint; current Sprint UI/lifecycle is reused.'
  );
end $$;
revoke all on function public.english_get_chatgpt_sprint_context(text) from public, anon, authenticated;
grant execute on function public.english_get_chatgpt_sprint_context(text) to service_role;

create or replace function public.english_publish_chatgpt_sprint(
  p_mode text,
  p_items jsonb,
  p_blueprint jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  owner_id uuid;
  owner_count integer;
  x jsonb;
  normalized jsonb:='[]'::jsonb;
  score numeric;
  meta jsonb;
  result jsonb;
  sid uuid;
  recent_ids uuid[];
begin
  if not english.ai_feature_enabled('chatgpt_sprint_v1') then
    raise exception 'Manual ChatGPT Sprint feature is disabled';
  end if;
  select count(*),max(id::text)::uuid into owner_count,owner_id
  from auth.users where deleted_at is null;
  if owner_count<>1 then raise exception 'Manual Sprint requires exactly one active auth owner'; end if;

  if exists(select 1 from english.sprint_sessions where user_id=owner_id and status in ('ready','in_progress','paused')) then
    raise exception 'An active Sprint already exists';
  end if;
  if exists(select 1 from english.sprint_generation_jobs where user_id=owner_id and status in ('queued','generating','ready') and expires_at>now()) then
    raise exception 'An automatic Sprint generation job is already active';
  end if;

  perform english.assert_generated_items_quality(p_items,false);

  select array_agg(session_id) into recent_ids
  from (
    select session_id from english.sprint_sessions
    where user_id=owner_id and status='completed'
    order by completed_at desc,session_id desc limit 5
  ) s;

  for x in select value from jsonb_array_elements(p_items) loop
    if exists(
      select 1 from english.sprint_items i
      where i.session_id=any(coalesce(recent_ids,'{}'::uuid[]))
        and regexp_replace(lower(btrim(i.question)),'\s+',' ','g')
          =regexp_replace(lower(btrim(x->>'question')),'\s+',' ','g')
    ) then raise exception 'Recent Sprint question duplicate rejected'; end if;

    score:=(x->'quality'->>'score')::numeric;
    meta:=coalesce(x->'metadata','{}'::jsonb)||jsonb_build_object(
      'criticPassed',true,
      'generationProvider','ChatGPT foreground',
      'manualQualityScore',score,
      'manualHardGates',x->'quality'->'hardGates'
    );
    normalized:=normalized||jsonb_build_array(
      (x-'quality')||jsonb_build_object(
        'qualityScore',score/100.0,
        'ambiguous',false,
        'sourceType',coalesce(nullif(x->>'sourceType',''),'GPT Generated'),
        'metadata',meta
      )
    );
  end loop;

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  result:=public.english_create_sprint_session(
    p_mode,
    normalized,
    coalesce(p_blueprint,'{}'::jsonb)||jsonb_build_object('generationProvider','ChatGPT foreground','manualPrepared',true)
  );
  sid:=nullif(result->>'sessionId','')::uuid;
  if sid is null then raise exception 'Sprint publication did not return a session'; end if;

  update english.sprint_sessions
  set status='ready',current_position=1,remaining_seconds=900,paused_at=null,runtime_updated_at=now()
  where session_id=sid and user_id=owner_id;

  insert into english.content_generation_audits(
    lane,entity_key,generator_provider,quality_score,critic_decision,publication_result,metadata
  ) values(
    'sprint',sid::text,'chatgpt_foreground',
    (select min((e.value->'quality'->>'score')::numeric) from jsonb_array_elements(p_items) e(value)),
    'PASS','ready',jsonb_build_object('mode',p_mode,'questionCount',jsonb_array_length(p_items))
  );

  return public.english_get_sprint_session(sid);
end $$;
revoke all on function public.english_publish_chatgpt_sprint(text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.english_publish_chatgpt_sprint(text,jsonb,jsonb) to service_role;

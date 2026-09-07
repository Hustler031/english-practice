-- Per-word My Saved enrichment telemetry + bounded retry backoff.
-- Keeps Pending GPT retryable while making provider failures visible to the learner.

create table if not exists english.saved_enrichment_item_state (
  user_id uuid not null,
  saved_id text not null,
  state text not null default 'pending' check (state in ('pending','processing','retrying','ready')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  lease_id uuid,
  last_attempt_at timestamptz,
  last_error text,
  last_error_at timestamptz,
  next_attempt_at timestamptz,
  last_success_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id,saved_id)
);

revoke all on table english.saved_enrichment_item_state from public, anon, authenticated;
grant select,insert,update,delete on table english.saved_enrichment_item_state to service_role;

-- Seed the currently known failed item(s), if any, so the UI is informative immediately
-- and the next kick can work on newer pending items instead of hammering the same provider failure.
insert into english.saved_enrichment_item_state(
  user_id,saved_id,state,attempt_count,last_attempt_at,last_error,last_error_at,next_attempt_at,updated_at
)
select s.user_id,s.saved_id,'retrying',1,w.last_finished_at,left(w.last_error,1200),w.last_finished_at,
       greatest(now(),coalesce(w.last_finished_at,now()) + interval '10 minutes'),now()
from english.saved_items s
cross join english.saved_enrichment_worker_state w
where w.singleton=true
  and nullif(btrim(coalesce(w.last_error,'')),'') is not null
  and position(s.saved_id in w.last_error)>0
  and s.active
on conflict(user_id,saved_id) do update set
  state='retrying',
  attempt_count=greatest(english.saved_enrichment_item_state.attempt_count,1),
  last_attempt_at=excluded.last_attempt_at,
  last_error=excluded.last_error,
  last_error_at=excluded.last_error_at,
  next_attempt_at=excluded.next_attempt_at,
  updated_at=now();

create or replace function english.maintenance_saved_enrichment_batch(p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_limit integer:=greatest(1,least(25,coalesce(p_limit,10)));
  v_items jsonb;
begin
  select count(*),max(o.user_id::text)::uuid
  into v_owner_count,v_owner
  from (select distinct s.user_id from english.saved_items s where s.active) o;

  if v_owner_count=0 then
    return jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb);
  end if;
  if v_owner_count<>1 then
    raise exception 'Saved enrichment maintenance requires exactly one active owner';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb)
  into v_items
  from (
    select
      s.saved_id as "savedId",
      coalesce(s.word,'') as word,
      coalesce(s.meaning,'') as meaning,
      coalesce(s.context,'') as context,
      coalesce(s.origin_question_id,'') as "originQuestionId",
      coalesce(s.origin_module,'') as "originModule",
      coalesce(s.source,'') as source,
      coalesce(s.part_of_speech,'') as "partOfSpeech",
      coalesce(s.synonyms,'') as synonyms,
      coalesce(s.antonyms,'') as antonyms,
      coalesce(s.example,'') as example,
      coalesce(s.explanation,'') as explanation,
      coalesce(s.question,'') as question,
      coalesce(s.option_a,'') as "optionA",
      coalesce(s.option_b,'') as "optionB",
      coalesce(s.option_c,'') as "optionC",
      coalesce(s.option_d,'') as "optionD",
      coalesce(s.correct_option,'') as "correctOption",
      coalesce(s.gpt_status,'Pending GPT') as "gptStatus",
      coalesce(t.capture_type,'AUTO') as "captureType",
      coalesce(t.resolved_type,english.resolve_saved_type('AUTO',s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation)) as "resolvedType",
      s.created_at,s.updated_at,s.gpt_updated_at
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    where s.active and s.user_id=v_owner
      and not (coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
      and (
        btrim(coalesce(s.gpt_status,''))=''
        or lower(btrim(coalesce(s.gpt_status,''))) in ('pending gpt','needs enrichment')
        or (
          lower(btrim(coalesce(s.gpt_status,'')))='needs review'
          and (s.gpt_updated_at is null or coalesce(s.updated_at,s.created_at)>s.gpt_updated_at+interval '1 second')
        )
        or (
          lower(btrim(coalesce(s.gpt_status,'')))='ready'
          and (
            btrim(coalesce(s.meaning,''))=''
            or btrim(coalesce(s.question,''))=''
            or btrim(coalesce(s.option_a,''))=''
            or btrim(coalesce(s.option_b,''))=''
            or btrim(coalesce(s.option_c,''))=''
            or btrim(coalesce(s.option_d,''))=''
            or upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D')
            or btrim(coalesce(s.explanation,''))=''
          )
        )
      )
    order by
      case
        when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 0
        when lower(btrim(coalesce(s.gpt_status,'')))='pending gpt' then 1
        when btrim(coalesce(s.gpt_status,''))='' then 1
        when lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment' then 2
        else 3
      end,
      s.created_at asc nulls last
    limit v_limit
  ) x;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end
$function$;

create or replace function public.english_saved_enrichment_worker_claim(p_token text,p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_lease uuid;
  v_expires timestamptz;
  v_new_lease uuid;
  v_batch jsonb;
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;

  select lease_id,lease_expires_at into v_lease,v_expires
  from english.saved_enrichment_worker_state where singleton=true for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  v_batch:=english.maintenance_saved_enrichment_batch(greatest(1,least(10,coalesce(p_limit,10))));
  if coalesce((v_batch->>'count')::integer,0)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch || jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,lease_expires_at=now()+interval '10 minutes',last_started_at=now(),last_error=null,updated_at=now()
  where singleton=true;

  insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,next_attempt_at,updated_at)
  select s.user_id,j->>'savedId','processing',1,v_new_lease,now(),null,now()
  from jsonb_array_elements(coalesce(v_batch->'items','[]'::jsonb)) j
  join english.saved_items s on s.saved_id=j->>'savedId' and s.active
  on conflict(user_id,saved_id) do update set
    state='processing',
    attempt_count=english.saved_enrichment_item_state.attempt_count+1,
    lease_id=excluded.lease_id,
    last_attempt_at=excluded.last_attempt_at,
    next_attempt_at=null,
    updated_at=now();

  return v_batch || jsonb_build_object('busy',false,'leaseId',v_new_lease);
end
$function$;

create or replace function public.english_saved_enrichment_worker_finish(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_verified jsonb := jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb);
  v_success_count integer := cardinality(coalesce(p_saved_ids,'{}'::text[]));
  v_error text := nullif(left(btrim(coalesce(p_error,'')),1200),'');
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;

  if not exists(select 1 from english.saved_enrichment_worker_state where singleton=true and lease_id=p_lease_id) then
    raise exception 'saved enrichment worker lease mismatch';
  end if;

  if v_success_count > 0 then
    v_verified := english.maintenance_verify_saved_enrichment(p_saved_ids);

    update english.saved_enrichment_item_state es
    set state='ready',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,last_success_at=now(),updated_at=now()
    where es.saved_id=any(p_saved_ids)
      and es.lease_id=p_lease_id;
  end if;

  -- Anything claimed by this lease but not successfully applied stays Pending GPT,
  -- gets a visible retry reason, and cools down briefly before another provider call.
  update english.saved_enrichment_item_state es
  set state='retrying',
      lease_id=null,
      last_error=coalesce(v_error,'AI enrichment attempt did not complete.'),
      last_error_at=now(),
      next_attempt_at=now()+interval '10 minutes',
      updated_at=now()
  where es.lease_id=p_lease_id
    and not (es.saved_id=any(coalesce(p_saved_ids,'{}'::text[])));

  update english.saved_enrichment_worker_state
  set lease_id=null,lease_expires_at=null,last_finished_at=now(),last_count=v_success_count,last_error=v_error,updated_at=now()
  where singleton=true and lease_id=p_lease_id;

  if v_success_count > 0 and v_error is null then
    begin
      perform english.kick_saved_enrichment_worker(1);
    exception when others then
      raise warning 'My Saved follow-up enrichment kick failed: %',sqlerrm;
    end;
  end if;

  return v_verified;
end
$function$;

create or replace function public.english_get_saved_items()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
 'id',s.saved_id,
 'word',coalesce(s.word,''),
 'meaning',coalesce(s.meaning,''),
 'context',coalesce(s.context,''),
 'questionId',coalesce(s.origin_question_id,''),
 'module',coalesce(s.origin_module,''),
 'source',coalesce(s.source,''),
 'status',coalesce(s.status,'Saved'),
 'practiceQuestionId',coalesce(s.practice_question_id,''),
 'created',s.created_at,
 'updated',s.updated_at,
 'partOfSpeech',coalesce(s.part_of_speech,''),
 'synonyms',coalesce(s.synonyms,''),
 'antonyms',coalesce(s.antonyms,''),
 'example',coalesce(s.example,''),
 'explanation',coalesce(s.explanation,''),
 'question',coalesce(s.question,''),
 'optionA',coalesce(s.option_a,''),
 'optionB',coalesce(s.option_b,''),
 'optionC',coalesce(s.option_c,''),
 'optionD',coalesce(s.option_d,''),
 'correctOption',coalesce(s.correct_option,''),
 'gptStatus',coalesce(s.gpt_status,'Pending GPT'),
 'gptUpdated',s.gpt_updated_at,
 'gptSource',coalesce(s.gpt_source,''),
 'captureType',coalesce(t.capture_type,'AUTO'),
 'resolvedType',coalesce(t.resolved_type,english.resolve_saved_type('AUTO',s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation)),
 'generatorProvider',coalesce(a.generator_provider,''),
 'generatorModel',coalesce(a.generator_model,''),
 'criticProvider',coalesce(a.critic_provider,''),
 'criticModel',coalesce(a.critic_model,''),
 'criticScore',a.quality_score,
 'criticDecision',coalesce(a.critic_decision,''),
 'generationRepairCount',coalesce(a.repair_count,0),
 'enrichmentState',coalesce(es.state,case when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 'ready' else 'pending' end),
 'enrichmentAttemptCount',coalesce(es.attempt_count,0),
 'enrichmentLastAttempt',es.last_attempt_at,
 'enrichmentLastError',coalesce(es.last_error,''),
 'enrichmentNextAttempt',es.next_attempt_at
) order by s.created_at desc nulls last),'[]'::jsonb) end
from english.saved_items s
left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
left join lateral (
  select cga.generator_provider,cga.generator_model,cga.critic_provider,cga.critic_model,cga.quality_score,cga.critic_decision,cga.repair_count
  from english.content_generation_audits cga
  where cga.lane='saved' and cga.entity_key=s.saved_id
  order by cga.created_at desc
  limit 1
) a on true
where s.user_id=auth.uid() and s.active;
$function$;

revoke all on function public.english_get_saved_items() from public,anon;
grant execute on function public.english_get_saved_items() to authenticated,service_role;

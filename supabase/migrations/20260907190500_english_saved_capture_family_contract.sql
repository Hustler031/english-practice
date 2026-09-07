-- Make explicit My Saved capture categories authoritative for generated content.
-- In particular, SM is a spelling-mistake lane and must never publish as a synonym/meaning MCQ.

create or replace function public.english_saved_enrichment_worker_apply(
  p_token text,
  p_lease_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  x jsonb;
  v_saved_id text;
  v_capture text;
  v_question text;
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;
  if not exists(
    select 1 from english.saved_enrichment_worker_state
    where singleton=true and lease_id=p_lease_id and lease_expires_at>now()
  ) then raise exception 'saved enrichment worker lease is missing or expired'; end if;

  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' then
    raise exception 'Saved enrichment items must be an array';
  end if;

  -- Defense in depth: the database checks the learner-selected capture family again.
  -- A model cannot publish a synonym question merely by returning captureType='SM'.
  for x in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    v_saved_id := btrim(coalesce(x->>'savedId',''));
    select coalesce(t.capture_type,'AUTO')
      into v_capture
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    where s.saved_id=v_saved_id and s.active
    limit 1;

    if not found then raise exception 'Saved enrichment item % does not exist',v_saved_id; end if;

    if v_capture in ('V','SM','OWS','PV','IP')
       and upper(btrim(coalesce(x->>'captureType',''))) <> v_capture then
      raise exception 'Saved item % capture type mismatch: expected %, got %',v_saved_id,v_capture,coalesce(x->>'captureType','');
    end if;

    if v_capture='SM' then
      v_question := btrim(coalesce(x->>'question',''));
      if v_question !~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)' then
        raise exception 'Saved item % is SM but generated question is not spelling-family',v_saved_id;
      end if;
    end if;
  end loop;

  if english.ai_feature_enabled('groq_critic_v1') then
    perform english.assert_generated_items_quality(p_items,true);
  end if;
  return english.maintenance_apply_saved_enrichment(p_items);
end
$function$;

create or replace function public.english_set_saved_item_type(p_saved_id text,p_capture_type text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid();
  s english.saved_items%rowtype;
  v_capture text:=upper(btrim(coalesce(p_capture_type,'')));
  v_resolved text;
  v_old_capture text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_capture not in ('AUTO','V','SM','OWS','PV','IP') then raise exception 'Invalid capture type'; end if;
  select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid;
  if not found then raise exception 'Saved item not found'; end if;

  select capture_type into v_old_capture
  from english.saved_item_types
  where user_id=uid and saved_id=s.saved_id;

  v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,s.context,s.part_of_speech,s.question,s.explanation);
  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
  values(uid,s.saved_id,v_capture,v_resolved,now())
  on conflict(user_id,saved_id) do update
    set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

  -- Changing the learner's category invalidates any question created for the old family.
  if v_old_capture is distinct from v_capture then
    update english.saved_items
    set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
    where user_id=uid and saved_id=s.saved_id;

    update english.saved_enrichment_item_state
    set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now()
    where user_id=uid and saved_id=s.saved_id;

    begin
      perform english.kick_saved_enrichment_worker(1);
    exception when others then
      raise warning 'My Saved category-change enrichment kick failed for %: %',s.saved_id,sqlerrm;
    end;
  end if;

  return jsonb_build_object('ok',true,'id',s.saved_id,'capture_type',v_capture,'resolved_type',v_resolved,'reenrichmentQueued',v_old_capture is distinct from v_capture);
end
$function$;

-- Repair any already-published explicit SM item whose question family contradicts SM.
with bad as (
  select s.user_id,s.saved_id
  from english.saved_items s
  join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
  where s.active
    and t.capture_type='SM'
    and lower(btrim(coalesce(s.gpt_status,'')))='ready'
    and btrim(coalesce(s.question,'')) !~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)'
)
update english.saved_items s
set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
from bad b
where s.user_id=b.user_id and s.saved_id=b.saved_id;

update english.saved_enrichment_item_state es
set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now()
where exists(
  select 1
  from english.saved_items s
  join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
  where s.user_id=es.user_id and s.saved_id=es.saved_id
    and s.active and t.capture_type='SM'
    and lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment'
);

-- Best-effort immediate repair; the existing hourly job remains the safety net.
do $block$
begin
  perform english.kick_saved_enrichment_worker(10);
exception when others then
  raise warning 'My Saved SM repair kick failed: %',sqlerrm;
end
$block$;

revoke all on function public.english_set_saved_item_type(text,text) from public,anon;
grant execute on function public.english_set_saved_item_type(text,text) to authenticated,service_role;

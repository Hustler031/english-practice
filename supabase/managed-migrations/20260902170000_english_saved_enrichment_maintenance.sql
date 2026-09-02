-- Service-only maintenance path for scheduled My Saved enrichment.
-- The scheduler must not impersonate a learner in connector SQL. These private helpers
-- establish the single-owner invariant inside the database, then reuse the validated
-- authenticated enrichment/promotion RPCs without exposing a new learner-facing API.

create or replace function english.maintenance_saved_enrichment_batch(
  p_limit integer default 10
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid;
  v_owner_count integer;
  v_limit integer:=greatest(1,least(25,coalesce(p_limit,10)));
  v_items jsonb;
begin
  select count(distinct s.user_id),min(s.user_id)
  into v_owner_count,v_owner
  from english.saved_items s
  where s.active;

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
      s.created_at,
      s.updated_at,
      s.gpt_updated_at
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    where s.active
      and s.user_id=v_owner
      and (
        btrim(coalesce(s.gpt_status,''))=''
        or lower(btrim(coalesce(s.gpt_status,''))) in ('pending gpt','needs enrichment')
        or (
          lower(btrim(coalesce(s.gpt_status,'')))='needs review'
          and (s.gpt_updated_at is null or coalesce(s.updated_at,s.created_at)>s.gpt_updated_at+interval '1 second')
        )
      )
    order by
      case lower(btrim(coalesce(s.gpt_status,''))) when 'pending gpt' then 0 when '' then 0 when 'needs enrichment' then 1 else 2 end,
      s.created_at asc nulls last
    limit v_limit
  ) x;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end $$;

create or replace function english.maintenance_apply_saved_enrichment(
  p_items jsonb
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid;
  v_owner_count integer;
  v_item jsonb;
  v_saved_id text;
  v_capture text;
  v_status text;
  v_result jsonb;
  v_results jsonb:='[]'::jsonb;
  v_promoted jsonb;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception 'p_items must be a JSON array';
  end if;
  if jsonb_array_length(p_items)>25 then
    raise exception 'At most 25 saved items may be applied per batch';
  end if;

  select count(distinct s.user_id),min(s.user_id)
  into v_owner_count,v_owner
  from english.saved_items s
  where s.active;
  if v_owner_count<>1 then
    raise exception 'Saved enrichment maintenance requires exactly one active owner';
  end if;

  -- Local to this transaction/function. The connector never supplies or handles a learner JWT.
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_saved_id:=btrim(coalesce(v_item->>'savedId',''));
    if v_saved_id='' then raise exception 'savedId is required'; end if;
    if not exists(select 1 from english.saved_items s where s.saved_id=v_saved_id and s.user_id=v_owner and s.active) then
      raise exception 'Saved item is not active for the maintenance owner: %',v_saved_id;
    end if;

    v_status:=coalesce(nullif(btrim(v_item->>'gptStatus'),''),'Ready');
    v_result:=public.english_set_saved_enrichment(
      v_saved_id,
      coalesce(v_item->>'meaning',''),
      coalesce(v_item->>'partOfSpeech',''),
      coalesce(v_item->>'synonyms',''),
      coalesce(v_item->>'antonyms',''),
      coalesce(v_item->>'example',''),
      coalesce(v_item->>'explanation',''),
      coalesce(v_item->>'question',''),
      coalesce(v_item->>'optionA',''),
      coalesce(v_item->>'optionB',''),
      coalesce(v_item->>'optionC',''),
      coalesce(v_item->>'optionD',''),
      upper(coalesce(v_item->>'correctOption','')),
      coalesce(v_item->>'source','Scheduled My Saved enrichment'),
      v_status
    );

    v_capture:=upper(btrim(coalesce(v_item->>'captureType','')));
    if v_capture in ('AUTO','V','SM','OWS','PV','IP') then
      perform public.english_set_saved_item_type(v_saved_id,v_capture);
    end if;

    v_promoted:=null;
    if lower(v_status)='ready'
       and coalesce((select s.practice_question_id from english.saved_items s where s.saved_id=v_saved_id),'')='' then
      v_promoted:=public.english_promote_saved_item(v_saved_id);
    end if;

    v_results:=v_results||jsonb_build_array(jsonb_build_object(
      'savedId',v_saved_id,
      'enrichment',v_result,
      'promotion',v_promoted
    ));
  end loop;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_results),'results',v_results);
end $$;

create or replace function english.maintenance_verify_saved_enrichment(
  p_saved_ids text[]
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid;
  v_owner_count integer;
  v_items jsonb;
begin
  select count(distinct s.user_id),min(s.user_id)
  into v_owner_count,v_owner
  from english.saved_items s
  where s.active;
  if v_owner_count<>1 then
    raise exception 'Saved enrichment maintenance requires exactly one active owner';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'savedId',s.saved_id,
    'active',s.active,
    'gptStatus',coalesce(s.gpt_status,''),
    'captureType',coalesce(t.capture_type,'AUTO'),
    'resolvedType',coalesce(t.resolved_type,''),
    'practiceQuestionId',coalesce(s.practice_question_id,''),
    'questionReady',btrim(coalesce(s.question,''))<>''
      and btrim(coalesce(s.option_a,''))<>''
      and btrim(coalesce(s.option_b,''))<>''
      and btrim(coalesce(s.option_c,''))<>''
      and btrim(coalesce(s.option_d,''))<>''
      and upper(btrim(coalesce(s.correct_option,''))) in ('A','B','C','D'),
    'updatedAt',s.updated_at
  ) order by s.created_at),'[]'::jsonb)
  into v_items
  from english.saved_items s
  left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
  where s.user_id=v_owner
    and s.saved_id=any(coalesce(p_saved_ids,'{}'::text[]));

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end $$;

revoke all on function english.maintenance_saved_enrichment_batch(integer) from public,anon,authenticated;
revoke all on function english.maintenance_apply_saved_enrichment(jsonb) from public,anon,authenticated;
revoke all on function english.maintenance_verify_saved_enrichment(text[]) from public,anon,authenticated;
grant usage on schema english to service_role;
grant execute on function english.maintenance_saved_enrichment_batch(integer) to service_role;
grant execute on function english.maintenance_apply_saved_enrichment(jsonb) to service_role;
grant execute on function english.maintenance_verify_saved_enrichment(text[]) to service_role;

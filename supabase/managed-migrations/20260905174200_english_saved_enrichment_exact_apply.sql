-- When a previously linked Saved item is re-enriched (for example after a legacy
-- malformed Ready row is recovered), promote the validated Ready payload again.
-- Exact promotion is idempotent for unchanged content and creates a new immutable
-- owner-scoped variant when the learner-visible payload genuinely changed.

create or replace function english.maintenance_apply_saved_enrichment(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
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

  select count(*),max(o.user_id::text)::uuid
  into v_owner_count,v_owner
  from (select distinct s.user_id from english.saved_items s where s.active) o;

  if v_owner_count<>1 then
    raise exception 'Saved enrichment maintenance requires exactly one active owner';
  end if;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_saved_id:=btrim(coalesce(v_item->>'savedId',''));
    if v_saved_id='' then raise exception 'savedId is required'; end if;
    if not exists(
      select 1 from english.saved_items s
      where s.saved_id=v_saved_id and s.user_id=v_owner and s.active
    ) then
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
    if lower(v_status)='ready' then
      v_promoted:=public.english_promote_saved_item(v_saved_id);
    end if;

    v_results:=v_results||jsonb_build_array(jsonb_build_object(
      'savedId',v_saved_id,
      'enrichment',v_result,
      'promotion',v_promoted
    ));
  end loop;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_results),'results',v_results);
end
$function$;

revoke execute on function english.maintenance_apply_saved_enrichment(jsonb) from public,anon,authenticated;
grant execute on function english.maintenance_apply_saved_enrichment(jsonb) to service_role;

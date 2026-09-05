-- Legacy My Saved data can contain rows marked Ready even though a required learning
-- field is blank. Treat those rows as enrichment backlog again so the ChatGPT-owned
-- private queue can self-heal them and the existing apply helper can promote them.

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
    where s.active and s.user_id=v_owner and (
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

revoke all on function english.maintenance_saved_enrichment_batch(integer) from public,anon,authenticated;
grant execute on function english.maintenance_saved_enrichment_batch(integer) to service_role;

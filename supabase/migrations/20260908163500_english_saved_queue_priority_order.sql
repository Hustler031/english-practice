-- Preserve Saved enrichment priority when materializing the maintenance batch.
-- Previous outer jsonb_agg(... order by created_at) accidentally overwrote the
-- intended status priority, allowing old Needs Enrichment rows to starve newer
-- Pending GPT items such as Coalesce.

create or replace function english.maintenance_saved_enrichment_batch(p_limit integer default 10)
returns jsonb
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
  select count(*),max(o.user_id::text)::uuid into v_owner_count,v_owner
  from (select distinct s.user_id from english.saved_items s where s.active) o;
  if v_owner_count=0 then return jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb); end if;
  if v_owner_count<>1 then raise exception 'Saved enrichment maintenance requires exactly one active owner'; end if;

  select coalesce(
    jsonb_agg((to_jsonb(x) - '_priority') order by x._priority,x.created_at asc nulls last),
    '[]'::jsonb
  ) into v_items
  from (
    select
      s.saved_id as "savedId",coalesce(s.word,'') as word,coalesce(s.meaning,'') as meaning,coalesce(s.context,'') as context,
      coalesce(s.origin_question_id,'') as "originQuestionId",coalesce(q.topic,'') as "originTopic",
      coalesce(s.origin_module,'') as "originModule",coalesce(s.source,'') as source,
      coalesce(s.part_of_speech,'') as "partOfSpeech",coalesce(s.synonyms,'') as synonyms,coalesce(s.antonyms,'') as antonyms,
      coalesce(s.example,'') as example,coalesce(s.explanation,'') as explanation,coalesce(s.question,'') as question,
      coalesce(s.option_a,'') as "optionA",coalesce(s.option_b,'') as "optionB",coalesce(s.option_c,'') as "optionC",coalesce(s.option_d,'') as "optionD",
      coalesce(s.correct_option,'') as "correctOption",coalesce(s.gpt_status,'Pending GPT') as "gptStatus",
      coalesce(t.capture_type,'AUTO') as "captureType",
      english.resolve_saved_type_for_enrichment(
        coalesce(t.capture_type,'AUTO'),coalesce(t.learning_intent,'AUTO'),s.word,s.context,coalesce(q.topic,'')
      ) as "resolvedType",
      coalesce(t.learning_intent,'AUTO') as "learningIntent",
      coalesce(t.learning_intent_origin,'LEGACY_UNKNOWN') as "learningIntentOrigin",
      english.resolve_saved_learning_intent_authoritative(
        coalesce(t.learning_intent,'AUTO'),
        s.word,
        english.resolve_saved_type_for_enrichment(
          coalesce(t.capture_type,'AUTO'),coalesce(t.learning_intent,'AUTO'),s.word,s.context,coalesce(q.topic,'')
        )
      ) as "requiredLearningIntent",
      case
        when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 0
        when lower(btrim(coalesce(s.gpt_status,'')))='pending gpt' then 1
        when btrim(coalesce(s.gpt_status,''))='' then 1
        when lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment' then 2
        else 3
      end as _priority,
      s.created_at,s.updated_at,s.gpt_updated_at
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    left join english.questions q on q.question_id=s.origin_question_id
    where s.active and s.user_id=v_owner
      and not(coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
      and (
        btrim(coalesce(s.gpt_status,''))=''
        or lower(btrim(coalesce(s.gpt_status,''))) in ('pending gpt','needs enrichment')
        or (lower(btrim(coalesce(s.gpt_status,'')))='needs review'
            and (s.gpt_updated_at is null or coalesce(s.updated_at,s.created_at)>s.gpt_updated_at+interval '1 second'))
        or (lower(btrim(coalesce(s.gpt_status,'')))='ready' and (
          btrim(coalesce(s.meaning,''))='' or btrim(coalesce(s.question,''))='' or
          btrim(coalesce(s.option_a,''))='' or btrim(coalesce(s.option_b,''))='' or
          btrim(coalesce(s.option_c,''))='' or btrim(coalesce(s.option_d,''))='' or
          upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D') or
          btrim(coalesce(s.explanation,''))=''
        ))
      )
    limit v_limit
  ) x;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end;
$$;

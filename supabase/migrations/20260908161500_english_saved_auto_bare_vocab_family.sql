-- Saved enrichment: prevent origin-topic contamination from turning a bare lexical
-- AUTO+MEANING item into CU, and preserve complete single-flight cascade errors.

create or replace function english.resolve_saved_type_for_enrichment(
  p_capture_type text,
  p_learning_intent text,
  p_word text,
  p_context text,
  p_origin_topic text
)
returns text
language plpgsql
immutable
set search_path to 'pg_catalog','public','english'
as $$
declare
  v_capture text:=upper(btrim(coalesce(p_capture_type,'AUTO')));
  v_word text:=btrim(coalesce(p_word,''));
  v_base text;
  v_intent text;
begin
  v_base:=english.resolve_saved_type_authoritative(p_capture_type,p_word,p_context,p_origin_topic);
  if v_capture<>'AUTO' then return v_base; end if;

  v_intent:=english.resolve_saved_learning_intent_authoritative(p_learning_intent,p_word,v_base);

  -- Narrow override: only repair the known contamination case where a clean one-word
  -- lexical target inherited CU from an unrelated grammar/fixed-preposition origin.
  -- Do not override SM/OWS/PV/IP, explicit user types, USAGE, or CONFUSION.
  if v_base='CU'
     and v_intent='MEANING'
     and length(v_word) between 1 and 70
     and v_word ~ '^[[:alpha:]][[:alpha:]''-]*$'
  then
    return 'V';
  end if;

  return v_base;
end;
$$;

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

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb) into v_items
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
    order by case
      when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 0
      when lower(btrim(coalesce(s.gpt_status,'')))='pending gpt' then 1
      when btrim(coalesce(s.gpt_status,''))='' then 1
      when lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment' then 2
      else 3 end,
      s.created_at asc nulls last
    limit v_limit
  ) x;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end;
$$;

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
as $$
declare
  v_failures jsonb:='[]'::jsonb;
  v_error text:=nullif(left(btrim(coalesce(p_error,'')),1200),'');
  v_open_count integer:=0;
  seg text;
  sid text;
  msg text;
  pos integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;

  select count(*) into v_open_count
  from english.saved_enrichment_item_state es
  where es.lease_id=p_lease_id
    and not (es.saved_id=any(coalesce(p_saved_ids,'{}'::text[])));

  -- Saved is single-flight. Preserve the complete cascade trace verbatim so model-tier
  -- separators inside the error cannot be mistaken for separate item failures.
  if v_error is not null and v_open_count=1 then
    select jsonb_agg(jsonb_build_object('savedId',es.saved_id,'error',v_error))
    into v_failures
    from english.saved_enrichment_item_state es
    where es.lease_id=p_lease_id
      and not (es.saved_id=any(coalesce(p_saved_ids,'{}'::text[])));
  elsif v_error is not null then
    for seg in select regexp_split_to_table(v_error,E'\\s+\\|\\s+') loop
      pos:=position(': ' in seg);
      if pos>1 then
        sid:=btrim(substr(seg,1,pos-1));
        msg:=btrim(substr(seg,pos+2));
        if exists(
          select 1 from english.saved_enrichment_item_state es
          where es.saved_id=sid and es.lease_id=p_lease_id
            and not (es.saved_id=any(coalesce(p_saved_ids,'{}'::text[])))
        ) then
          v_failures:=v_failures||jsonb_build_array(jsonb_build_object('savedId',sid,'error',msg));
        end if;
      end if;
    end loop;
  end if;

  if v_error is not null and jsonb_array_length(coalesce(v_failures,'[]'::jsonb))=0 then
    select coalesce(jsonb_agg(jsonb_build_object('savedId',es.saved_id,'error',v_error)),'[]'::jsonb)
    into v_failures
    from english.saved_enrichment_item_state es
    where es.lease_id=p_lease_id
      and not (es.saved_id=any(coalesce(p_saved_ids,'{}'::text[])));
  end if;

  return public.english_saved_enrichment_worker_finish_v2(p_token,p_lease_id,p_saved_ids,coalesce(v_failures,'[]'::jsonb));
end;
$$;

-- Hindu/current-news is a flexible daily editorial-English lane.
-- Every backend-approved vocabulary proposal (up to 30) may publish on the same day.
-- Phrasal exact-20 invariants are intentionally untouched.

create or replace function english.maintenance_hindu_status()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_source_id text := 'HINDU_'||to_char(v_day,'YYYYMMDD');
  v_count integer;
  v_complete boolean;
begin
  select count(*) into v_count from english.hindu_words h where h.word_date=v_day and h.active;
  select exists(
    select 1 from english.sources s
    where s.source_id=v_source_id and s.active
      and coalesce(s.question_count,0)=v_count
      and lower(coalesce(s.import_status,''))='complete'
  ) into v_complete;

  return jsonb_build_object(
    'ok',true,'date',v_day,'sourceId',v_source_id,
    'sourceFile','The Hindu Daily '||to_char(v_day,'DD-Mon-YYYY'),
    'existingToday',v_count,
    'dailyMinProposal',25,
    'dailyMax',30,
    -- Once a submitted batch has been applied it is complete even if critic rejection
    -- leaves fewer than 25 publishable items. Capacity is not a fill target.
    'missing',case when v_complete then 0 else greatest(0,30-v_count) end,
    'capacityRemaining',greatest(0,30-v_count),
    'sourceComplete',v_complete,
    'existingWords',(select coalesce(jsonb_agg(jsonb_build_object('hinduId',h.hindu_id,'word',h.word,'sourceUrl',h.source_url) order by h.hindu_id),'[]'::jsonb)
                     from english.hindu_words h where h.word_date=v_day and h.active)
  );
end
$$;

create or replace function english.maintenance_verify_hindu_daily()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_source_id text := 'HINDU_'||to_char(v_day,'YYYYMMDD');
  v_h integer; v_q integer; v_m integer; v_bad integer; v_complete boolean;
begin
  select count(*) into v_h from english.hindu_words h where h.word_date=v_day and h.active;
  select count(*) into v_q from english.questions q where q.active and q.source_id=v_source_id and q.topic='The Hindu Vocabulary';
  select count(*) into v_m from english.questions q join english.question_concept_mappings m on m.question_id=q.question_id and m.concept_id=q.concept_id where q.active and q.source_id=v_source_id;
  select count(*) into v_bad from english.questions q where q.active and q.source_id=v_source_id and (
    btrim(q.question)='' or btrim(coalesce(q.option_a,''))='' or btrim(coalesce(q.option_b,''))='' or btrim(coalesce(q.option_c,''))='' or btrim(coalesce(q.option_d,''))=''
    or upper(coalesce(q.correct,'')) not in ('A','B','C','D') or btrim(coalesce(q.explanation,''))='' or q.concept_id is null or btrim(coalesce(q.source_url,''))=''
  );
  select exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=v_h and lower(coalesce(s.import_status,''))='complete') into v_complete;

  return jsonb_build_object(
    'ok',(v_h=v_q and v_q=v_m and v_bad=0 and v_h<=30),
    'date',v_day,'sourceId',v_source_id,'hinduCount',v_h,'questionCount',v_q,'mappedCount',v_m,'badCount',v_bad,
    'dailyMinProposal',25,'dailyMax',30,
    'sourceComplete',v_complete,
    'completeBatch',(v_complete and v_h=v_q and v_q=v_m and v_bad=0),
    'complete20',(v_h=20 and v_q=20 and v_m=20 and v_bad=0)
  );
end
$$;

create or replace function english.maintenance_apply_hindu_daily(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_source_id text := 'HINDU_'||to_char(v_day,'YYYYMMDD');
  v_source_file text := 'The Hindu Daily '||to_char(v_day,'DD-Mon-YYYY');
  v_existing integer;
  v_capacity integer;
  v_item jsonb;
  v_ord integer := 0;
  v_slot integer;
  v_hindu_id text;
  v_qid text;
  v_word text;
  v_norm text;
  v_concept text;
  v_correct text;
  v_family_keys text[];
  v_duplicate boolean;
  v_distinct_exception boolean;
  v_review_note text;
  v_usage_note text;
  v_related_words text;
  v_count integer;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'p_items must be a JSON array'; end if;
  if jsonb_array_length(p_items)>30 then raise exception 'At most 30 Hindu vocabulary items may be applied'; end if;
  perform pg_advisory_xact_lock(hashtext('english.maintenance_hindu_daily'));

  select count(*) into v_existing from english.hindu_words h where h.word_date=v_day and h.active;
  v_capacity := greatest(0,30-v_existing);
  if jsonb_array_length(p_items)>v_capacity then raise exception 'Payload exceeds remaining Hindu capacity: % > %',jsonb_array_length(p_items),v_capacity; end if;
  if v_capacity=0 then return english.maintenance_verify_hindu_daily(); end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_ord := v_ord+1;
    v_word := upper(btrim(coalesce(v_item->>'word','')));
    v_norm := regexp_replace(lower(v_word),'[^a-z0-9]','','g');
    v_correct := upper(btrim(coalesce(v_item->>'correctKey','')));
    v_distinct_exception := coalesce((v_item->>'distinctSenseException')::boolean,false);
    v_review_note := btrim(coalesce(v_item->>'reviewNotes',''));

    if btrim(coalesce(v_item->>'examValueReason',''))<>'' then
      v_review_note := concat_ws(' | ',nullif(v_review_note,''),'Exam value: '||btrim(v_item->>'examValueReason'));
    end if;
    if btrim(coalesce(v_item->>'candidateType',''))<>'' then
      v_review_note := concat_ws(' | ',nullif(v_review_note,''),'Candidate type: '||btrim(v_item->>'candidateType'));
    end if;
    v_usage_note := btrim(coalesce(v_item->>'usageNote',''));
    if btrim(coalesce(v_item->>'fixedPreposition',''))<>'' then
      v_usage_note := concat_ws(' | ',nullif(v_usage_note,''),'Fixed preposition: '||btrim(v_item->>'fixedPreposition'));
    end if;
    v_related_words := btrim(coalesce(v_item->>'relatedWords',''));
    if btrim(coalesce(v_item->>'confusableWith',''))<>'' then
      v_related_words := concat_ws(' | ',nullif(v_related_words,''),'Confusable: '||btrim(v_item->>'confusableWith'));
    end if;

    if v_word='' or btrim(coalesce(v_item->>'meaning',''))='' or btrim(coalesce(v_item->>'question',''))='' or btrim(coalesce(v_item->>'explanation',''))='' then
      raise exception 'Hindu word/meaning/question/explanation are required at item %',v_ord;
    end if;
    if btrim(coalesce(v_item->>'sourceUrl',''))='' or btrim(coalesce(v_item->>'articleTitle',''))='' or btrim(coalesce(v_item->>'sourceName',''))='' then
      raise exception 'Hindu source metadata is required for %',v_word;
    end if;
    if btrim(coalesce(v_item->>'optionA',''))='' or btrim(coalesce(v_item->>'optionB',''))='' or btrim(coalesce(v_item->>'optionC',''))='' or btrim(coalesce(v_item->>'optionD',''))='' or v_correct not in ('A','B','C','D') then
      raise exception 'Hindu MCQ requires four options and A-D key for %',v_word;
    end if;

    select coalesce(array_agg(distinct k),array[v_norm]::text[]) into v_family_keys
    from (
      select regexp_replace(lower(value),'[^a-z0-9]','','g') k from jsonb_array_elements_text(coalesce(v_item->'familyKeys','[]'::jsonb))
      union all select v_norm
    ) x where k<>'';

    if exists(select 1 from english.hindu_words h where h.active and regexp_replace(lower(h.word),'[^a-z0-9]','','g')=v_norm)
       or exists(select 1 from english.questions q where q.active and q.word is not null and regexp_replace(lower(q.word),'[^a-z0-9]','','g')=v_norm) then
      raise exception 'Exact historical Hindu/canonical target already exists: %',v_word;
    end if;

    select exists(
      select 1 from english.hindu_words h where h.active and coalesce(h.word_family,'')<>''
      and exists(select 1 from unnest(v_family_keys) k where k<>v_norm and regexp_replace(lower(h.word_family),'[^a-z0-9]','','g') like '%'||k||'%')
      union all
      select 1 from english.questions q where q.active and q.word is not null
      and exists(select 1 from unnest(v_family_keys) k where k<>v_norm and regexp_replace(lower(q.word),'[^a-z0-9]','','g')=k)
      union all
      select 1 from english.questions q where q.active and coalesce(q.related_words,'')<>''
      and exists(select 1 from unnest(v_family_keys) k where k<>v_norm and regexp_replace(lower(q.related_words),'[^a-z0-9]','','g') like '%'||k||'%')
    ) into v_duplicate;
    if v_duplicate and (not v_distinct_exception or v_review_note='') then
      raise exception 'Historical family collision requires documented distinct-sense exception: %',v_word;
    end if;

    if exists(select 1 from jsonb_array_elements(p_items) e where e.value<>v_item and regexp_replace(lower(coalesce(e.value->>'word','')),'[^a-z0-9]','','g')=v_norm) then
      raise exception 'Duplicate word inside Hindu payload: %',v_word;
    end if;

    select s into v_slot from generate_series(1,30) s
    where not exists(select 1 from english.hindu_words h where h.hindu_id='HINDU'||to_char(v_day,'YYYYMMDD')||'_'||lpad(s::text,2,'0'))
    order by s limit 1;
    if v_slot is null then raise exception 'No Hindu slot available'; end if;

    v_hindu_id := 'HINDU'||to_char(v_day,'YYYYMMDD')||'_'||lpad(v_slot::text,2,'0');
    v_qid := 'HV'||to_char(v_day,'YYYYMMDD')||'_'||lpad(v_slot::text,3,'0');
    v_concept := 'HINDU_WORD_'||trim(both '_' from regexp_replace(upper(v_word),'[^A-Z0-9]+','_','g'));
    if exists(select 1 from english.questions q where q.question_id=v_qid) then raise exception 'Hindu Question_ID already exists: %',v_qid; end if;

    insert into english.hindu_words(
      hindu_id,word_date,word,part_of_speech,meaning,synonyms,antonyms,example_sentence,word_family,usage_note,tip,memory_aid,
      article_title,source_url,source_name,learning_status,content_status,active
    ) values (
      v_hindu_id,v_day,v_word,nullif(v_item->>'partOfSpeech',''),v_item->>'meaning',coalesce(v_item->>'synonyms',''),coalesce(v_item->>'antonyms',''),
      coalesce(v_item->>'example',''),coalesce(v_item->>'wordFamily',''),v_usage_note,coalesce(v_item->>'tip',''),coalesce(v_item->>'memoryAid',''),
      v_item->>'articleTitle',v_item->>'sourceUrl',v_item->>'sourceName','New','Active',true
    );

    insert into english.questions(
      question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,
      source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,tip,usage_note,
      example_sentence,memory_aid,related_words,source_url,review_notes,active,created_at,updated_at
    ) values (
      v_qid,'The Hindu Vocabulary',v_word,v_item->>'question',v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',v_item->>'optionD',v_correct,v_item->>'explanation',
      'Daily News Vocabulary',coalesce(nullif(v_item->>'questionType',''),'Vocabulary MCQ'),v_source_file,coalesce(v_item->>'sourcePage',''),v_concept,
      coalesce(nullif(v_item->>'difficulty',''),'Hard'),v_source_id,'New','Active','SSC CGL',coalesce(v_item->>'tip',''),v_usage_note,
      coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),v_related_words,v_item->>'sourceUrl',
      case when v_distinct_exception then concat_ws(' | ','Daily Hindu distinct-sense exception: '||v_review_note,v_review_note) else v_review_note end,true,now(),now()
    );

    insert into english.concepts(concept_id,domain,skill_family,name,description,confidence,exam_relevance,priority_score,coverage_state,is_atomic,active,metadata)
    values(v_concept,'English','The Hindu Vocabulary','Daily News Vocabulary',v_item->>'meaning','high','high',80,'unseen',true,true,
      jsonb_build_object('sourceId',v_source_id,'word',v_word,'sourceUrl',v_item->>'sourceUrl','candidateType',coalesce(v_item->>'candidateType','vocabulary'),
                         'fixedPreposition',coalesce(v_item->>'fixedPreposition',''),'confusableWith',coalesce(v_item->>'confusableWith',''),
                         'examValueReason',coalesce(v_item->>'examValueReason','')))
    on conflict(concept_id) do update set active=true,description=excluded.description,metadata=english.concepts.metadata||excluded.metadata,updated_at=now();

    insert into english.question_concept_mappings(question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type)
    values(v_qid,v_concept,1,'deterministic_metadata','mapped','primary')
    on conflict(question_id) do update set concept_id=excluded.concept_id,mapping_confidence=1,mapping_method='deterministic_metadata',review_status='mapped',updated_at=now();
  end loop;

  select count(*) into v_count from english.hindu_words h where h.word_date=v_day and h.active;
  insert into english.sources(source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,source_ref,notes,import_status,new_count,duplicate_count,category_summary,processed_on)
  values(v_source_id,'Daily News Vocabulary',v_source_file,v_source_file,v_day,true,now(),v_count,'ChatGPT private OIDC Hindu bridge',
    'Current-news editorial English supplied by ChatGPT; deterministic duplicate gates, independent critic and Central Intelligence mapping remain authoritative.',
    'Complete',v_count,0,'The Hindu Vocabulary: '||v_count,now())
  on conflict(source_id) do update set question_count=excluded.question_count,active=true,source_ref=excluded.source_ref,notes=excluded.notes,
    import_status='Complete',new_count=excluded.new_count,duplicate_count=0,category_summary=excluded.category_summary,processed_on=now();

  if exists(
    select 1 from english.hindu_words h
    where h.word_date=v_day and h.active and not exists(
      select 1 from english.questions q
      where q.question_id='HV'||to_char(v_day,'YYYYMMDD')||'_'||lpad(substring(h.hindu_id from '([0-9]{2})$'),3,'0')
        and q.active and q.topic='The Hindu Vocabulary' and q.source_id=v_source_id
        and exists(select 1 from english.question_concept_mappings m where m.question_id=q.question_id and m.concept_id=q.concept_id)
    )
  ) then raise exception 'Hindu daily cross-table/Central Intelligence mapping verification failed'; end if;

  return english.maintenance_verify_hindu_daily();
end
$$;

create or replace function public.english_hindu_task_apply(p_run_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
  v_source_id text := 'HINDU_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD');
  v_generator text := lower(coalesce(p_items->0->>'generatorProvider',''));
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='hindu' for update;
  if not found then raise exception 'Unknown Hindu run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status not in ('claimed','checked') then raise exception 'Hindu run is not applicable: %',r.status; end if;

  if english.ai_feature_enabled('groq_critic_v1') then perform english.assert_generated_items_quality(p_items,false); end if;
  v_apply := english.maintenance_apply_hindu_daily(p_items);

  if v_generator in ('chatgpt','openai') then
    update english.sources set
      source_ref='ChatGPT scheduled Sheet-first generation + private GitHub OIDC bridge + independent backend critic',
      notes='Current-news editorial English researched and fully authored by the ChatGPT scheduled task, staged in Google Sheets, then duplicate/quality-gated and mapped by the English V2 backend.'
    where source_id=v_source_id;
  elsif english.ai_feature_enabled('gemini_content_v1') then
    update english.sources set
      source_ref='Gemini grounded current-news generation + Groq independent critic',
      notes='Current-news vocabulary generated from grounded source evidence by Gemini and independently quality-gated by Groq.'
    where source_id=v_source_id;
  end if;

  v_verify := english.maintenance_verify_hindu_daily();
  if not coalesce((v_verify->>'ok')::boolean,false) then raise exception 'Hindu verification failed after apply'; end if;
  update english.chatgpt_content_task_runs
    set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify),applied_at=now(),updated_at=now()
    where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify);
end
$$;
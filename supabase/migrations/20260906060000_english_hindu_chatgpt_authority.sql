-- Hindu/current-news Sheet-first lane: Scheduled ChatGPT is the content editor.
-- Backend remains authoritative for deterministic structure, duplicate/family safety,
-- Central Intelligence mapping and canonical publication. No second AI critic is required.
-- Phrasal/My Saved critic behavior is intentionally untouched.

-- Multiple recovery/refill submissions may occur on the same date. Preserve each run's ledger.
alter table english.hindu_candidate_backlog
  drop constraint if exists hindu_candidate_backlog_batch_date_submitted_index_key;

alter table english.hindu_candidate_backlog
  drop constraint if exists hindu_candidate_backlog_run_id_submitted_index_key;

alter table english.hindu_candidate_backlog
  add constraint hindu_candidate_backlog_run_id_submitted_index_key unique(run_id, submitted_index);

create or replace function public.english_hindu_candidate_backlog_upsert(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare
  x jsonb;
  v_count integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be an array';
  end if;
  if jsonb_array_length(p_rows) > 30 then
    raise exception 'At most 30 Hindu backlog rows are allowed';
  end if;

  for x in select value from jsonb_array_elements(p_rows) loop
    insert into english.hindu_candidate_backlog(
      batch_date,run_id,submitted_index,word,normalized_word,status,payload,
      quality_score,critic_decision,critic_model,rejection_stage,rejection_reason,updated_at
    ) values (
      (x->>'batchDate')::date,
      nullif(x->>'runId','')::uuid,
      (x->>'submittedIndex')::integer,
      coalesce(x->>'word',''),
      coalesce(x->>'normalizedWord',''),
      x->>'status',
      coalesce(x->'payload','{}'::jsonb),
      nullif(x->>'qualityScore','')::numeric,
      nullif(x->>'criticDecision',''),
      nullif(x->>'criticModel',''),
      nullif(x->>'rejectionStage',''),
      nullif(x->>'rejectionReason',''),
      now()
    )
    on conflict(run_id,submitted_index) do update set
      batch_date=excluded.batch_date,
      word=excluded.word,
      normalized_word=excluded.normalized_word,
      status=excluded.status,
      payload=excluded.payload,
      quality_score=excluded.quality_score,
      critic_decision=excluded.critic_decision,
      critic_model=excluded.critic_model,
      rejection_stage=excluded.rejection_stage,
      rejection_reason=excluded.rejection_reason,
      updated_at=now();
    v_count:=v_count+1;
  end loop;

  return jsonb_build_object('ok',true,'count',v_count);
end
$$;

revoke all on function public.english_hindu_candidate_backlog_upsert(jsonb) from public, anon, authenticated;
grant execute on function public.english_hindu_candidate_backlog_upsert(jsonb) to service_role;

-- A Hindu day is complete only after at least 25 canonical items exist.
-- The lane may contain up to 30. This allows deterministic refill after duplicate rejection
-- or transport recovery without treating a small partial apply as a completed day.
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
  select (
    v_count between 25 and 30
    and exists(
      select 1 from english.sources s
      where s.source_id=v_source_id and s.active and coalesce(s.question_count,0)=v_count
    )
  ) into v_complete;

  return jsonb_build_object(
    'ok',true,'date',v_day,'sourceId',v_source_id,
    'sourceFile','The Hindu Daily '||to_char(v_day,'DD-Mon-YYYY'),
    'existingToday',v_count,
    'dailyMinProposal',25,
    'dailyMax',30,
    'missing',case when v_complete then 0 else greatest(0,25-v_count) end,
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
  select (
    v_h between 25 and 30
    and exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=v_h)
  ) into v_complete;

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

-- Canonical apply no longer requires an AI-generated quality object. The submitted item
-- has already been authored/refined by Scheduled ChatGPT and is still subject to all
-- deterministic structural, duplicate/family and mapping checks inside maintenance_apply_hindu_daily.
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
  v_count integer;
begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='hindu' for update;
  if not found then raise exception 'Unknown Hindu run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status not in ('claimed','checked') then raise exception 'Hindu run is not applicable: %',r.status; end if;

  v_apply:=english.maintenance_apply_hindu_daily(p_items);

  select count(*) into v_count from english.hindu_words h
  where h.word_date=(now() at time zone 'Asia/Kolkata')::date and h.active;

  update english.sources set
    source_ref='Scheduled ChatGPT research + deterministic Central Intelligence publication',
    notes='Current-news editorial English is researched, selected, enriched and refined by Scheduled ChatGPT. Backend authority is deterministic: structural validation, canonical duplicate/family safety and Central Intelligence concept mapping. No second AI critic is used in the Hindu publication path.',
    import_status=case when v_count>=25 then 'Complete' else 'Partial' end,
    question_count=v_count,
    new_count=v_count,
    processed_on=now()
  where source_id=v_source_id;

  v_verify:=english.maintenance_verify_hindu_daily();
  if not coalesce((v_verify->>'ok')::boolean,false) then raise exception 'Hindu verification failed after apply'; end if;

  update english.chatgpt_content_task_runs
    set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify),applied_at=now(),updated_at=now()
    where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify);
end
$$;

-- Tone/mood rows are also authored by Scheduled ChatGPT. Keep deterministic shape guards,
-- but do not require a second AI critic or a synthetic quality payload.
create or replace function public.english_apply_editorial_tone_items(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare
  x jsonb;
  n integer:=0;
  inserted integer:=0;
  fp text;
  v_keys text[];
  v_texts text[];
begin
  if not english.ai_feature_enabled('hindu_tone_v1') then raise exception 'Editorial tone feature is disabled'; end if;
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)>3 then
    raise exception 'At most 3 editorial tone items are allowed';
  end if;

  for x in select value from jsonb_array_elements(p_items) loop
    n:=n+1;
    if btrim(coalesce(x->>'contextParaphrase',''))='' or btrim(coalesce(x->>'question',''))='' or btrim(coalesce(x->>'explanation',''))='' then
      raise exception 'Tone item % requires context, question and explanation',n;
    end if;
    if length(coalesce(x->>'contextParaphrase',''))>700 then raise exception 'Tone context % is too long',n; end if;
    if btrim(coalesce(x->>'sourceName',''))='' or btrim(coalesce(x->>'sourceUrl',''))='' then raise exception 'Tone item % requires source metadata',n; end if;
    if upper(coalesce(x->>'correctKey','')) not in ('A','B','C','D') then raise exception 'Tone item % has invalid correct key',n; end if;
    if jsonb_typeof(coalesce(x->'options','null'::jsonb))<>'array' or jsonb_array_length(x->'options')<>4 then
      raise exception 'Tone item % requires four options',n;
    end if;

    select array_agg(upper(coalesce(o->>'key','')) order by ord), array_agg(lower(btrim(coalesce(o->>'text',''))) order by ord)
      into v_keys,v_texts
    from jsonb_array_elements(x->'options') with ordinality t(o,ord);
    if array_length(array(select distinct unnest(v_keys)),1)<>4 or array_length(array(select distinct unnest(v_texts)),1)<>4 or ''=any(v_texts) then
      raise exception 'Tone item % requires four distinct keyed option texts',n;
    end if;

    fp:=coalesce(nullif(x->>'fingerprint',''),md5(lower(regexp_replace(coalesce(x->>'question','')||' '||coalesce(x->>'contextParaphrase',''),'\s+',' ','g'))));
    insert into english.editorial_tone_items(
      source_date,source_name,source_url,tone_kind,context_paraphrase,question,options,correct_key,explanation,quality,fingerprint
    ) values(
      coalesce((x->>'sourceDate')::date,(now() at time zone 'Asia/Kolkata')::date),
      coalesce(nullif(x->>'sourceName',''),'Current editorial'),nullif(x->>'sourceUrl',''),
      coalesce(nullif(x->>'toneKind',''),'actual'),x->>'contextParaphrase',x->>'question',x->'options',
      upper(x->>'correctKey'),x->>'explanation',
      jsonb_build_object('editor','scheduled_chatgpt','secondAiCritic',false,'deterministicValidated',true),fp
    ) on conflict(fingerprint) do nothing;
    if found then inserted:=inserted+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'received',n,'inserted',inserted);
end
$$;

revoke all on function public.english_hindu_task_apply(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.english_hindu_task_apply(uuid,jsonb) to service_role;
revoke all on function public.english_apply_editorial_tone_items(jsonb) from public, anon, authenticated;
grant execute on function public.english_apply_editorial_tone_items(jsonb) to service_role;

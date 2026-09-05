-- Zero-extra-OpenAI-API bridge for ChatGPT-owned Phrasal and Hindu workflows.
-- ChatGPT generates/researches content; private GitHub Actions OIDC transports payloads;
-- Supabase keeps deterministic selection, duplicate gates, atomic writes, provenance,
-- Central Intelligence mapping and verification.

create table if not exists english.chatgpt_content_task_runs (
  run_id uuid primary key default gen_random_uuid(),
  lane text not null check (lane in ('phrasal','hindu')),
  batch_date date not null,
  status text not null default 'claimed' check (status in ('claimed','checked','applied','superseded','failed')),
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  applied_at timestamptz
);
create index if not exists chatgpt_content_task_runs_lane_date_idx
  on english.chatgpt_content_task_runs(lane,batch_date,created_at desc);
alter table english.chatgpt_content_task_runs enable row level security;
revoke all on english.chatgpt_content_task_runs from public,anon,authenticated;
grant select,insert,update,delete on english.chatgpt_content_task_runs to service_role;

create or replace function english.maintenance_hindu_status()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text:='HINDU_'||to_char(v_day,'YYYYMMDD');
  v_count integer;
begin
  select count(*) into v_count from english.hindu_words h where h.word_date=v_day and h.active;
  return jsonb_build_object(
    'ok',true,'date',v_day,'sourceId',v_source_id,
    'sourceFile','The Hindu Daily '||to_char(v_day,'DD-Mon-YYYY'),
    'existingToday',v_count,'missing',greatest(0,20-v_count),
    'sourceComplete',exists(
      select 1 from english.sources s where s.source_id=v_source_id and s.active
        and coalesce(s.question_count,0)=v_count and lower(coalesce(s.import_status,''))='complete'
    ),
    'existingWords',(select coalesce(jsonb_agg(jsonb_build_object('hinduId',h.hindu_id,'word',h.word,'sourceUrl',h.source_url) order by h.hindu_id),'[]'::jsonb)
                     from english.hindu_words h where h.word_date=v_day and h.active)
  );
end
$function$;

create or replace function english.maintenance_hindu_check_candidates(p_candidates jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_item jsonb;
  v_word text;
  v_norm text;
  v_keys text[];
  v_key text;
  v_hits jsonb;
  v_rows jsonb:='[]'::jsonb;
begin
  if p_candidates is null or jsonb_typeof(p_candidates)<>'array' then raise exception 'p_candidates must be a JSON array'; end if;
  if jsonb_array_length(p_candidates)>60 then raise exception 'At most 60 Hindu candidates may be checked'; end if;

  for v_item in select value from jsonb_array_elements(p_candidates) loop
    v_word:=btrim(coalesce(v_item->>'word',''));
    if v_word='' then raise exception 'Candidate word is required'; end if;
    v_norm:=regexp_replace(lower(v_word),'[^a-z0-9]','','g');
    select coalesce(array_agg(distinct k),array[v_norm]::text[]) into v_keys
    from (
      select regexp_replace(lower(value),'[^a-z0-9]','','g') k
      from jsonb_array_elements_text(coalesce(v_item->'familyKeys','[]'::jsonb))
      union all select v_norm
    ) x where k<>'';

    select coalesce(jsonb_agg(hit),'[]'::jsonb) into v_hits from (
      select distinct jsonb_build_object('kind','hindu_word','id',h.hindu_id,'word',h.word) hit
      from english.hindu_words h
      where h.active and exists(select 1 from unnest(v_keys) k where regexp_replace(lower(h.word),'[^a-z0-9]','','g')=k)
      union
      select distinct jsonb_build_object('kind','question_word','id',q.question_id,'word',q.word) hit
      from english.questions q
      where q.active and q.word is not null and exists(select 1 from unnest(v_keys) k where regexp_replace(lower(q.word),'[^a-z0-9]','','g')=k)
      union
      select distinct jsonb_build_object('kind','hindu_family','id',h.hindu_id,'word',h.word) hit
      from english.hindu_words h
      where h.active and coalesce(h.word_family,'')<>''
        and exists(select 1 from unnest(v_keys) k where k<>v_norm and regexp_replace(lower(h.word_family),'[^a-z0-9]','','g') like '%'||k||'%')
      union
      select distinct jsonb_build_object('kind','related_word','id',q.question_id,'word',q.word) hit
      from english.questions q
      where q.active and coalesce(q.related_words,'')<>''
        and exists(select 1 from unnest(v_keys) k where k<>v_norm and regexp_replace(lower(q.related_words),'[^a-z0-9]','','g') like '%'||k||'%')
    ) h;

    v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
      'word',v_word,'normalized',v_norm,'familyKeys',to_jsonb(v_keys),
      'duplicate',jsonb_array_length(v_hits)>0,'hits',v_hits
    ));
  end loop;
  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_rows),'items',v_rows);
end
$function$;

create or replace function english.maintenance_apply_hindu_daily(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text:='HINDU_'||to_char(v_day,'YYYYMMDD');
  v_source_file text:='The Hindu Daily '||to_char(v_day,'DD-Mon-YYYY');
  v_existing integer;
  v_missing integer;
  v_item jsonb;
  v_ord integer:=0;
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
  v_created text[]:='{}'::text[];
  v_count integer;
  v_bad integer;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'p_items must be a JSON array'; end if;
  if jsonb_array_length(p_items)>20 then raise exception 'At most 20 Hindu items may be applied'; end if;
  perform pg_advisory_xact_lock(hashtext('english.maintenance_hindu_daily'));

  select count(*) into v_existing from english.hindu_words h where h.word_date=v_day and h.active;
  v_missing:=greatest(0,20-v_existing);
  if jsonb_array_length(p_items)>v_missing then raise exception 'Payload exceeds remaining Hindu slots: % > %',jsonb_array_length(p_items),v_missing; end if;
  if v_missing=0 then return english.maintenance_verify_hindu_daily(); end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_ord:=v_ord+1;
    v_word:=upper(btrim(coalesce(v_item->>'word','')));
    v_norm:=regexp_replace(lower(v_word),'[^a-z0-9]','','g');
    v_correct:=upper(btrim(coalesce(v_item->>'correctKey','')));
    v_distinct_exception:=coalesce((v_item->>'distinctSenseException')::boolean,false);
    v_review_note:=btrim(coalesce(v_item->>'reviewNotes',''));

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
      select regexp_replace(lower(value),'[^a-z0-9]','','g') k
      from jsonb_array_elements_text(coalesce(v_item->'familyKeys','[]'::jsonb))
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

    if exists(
      select 1 from jsonb_array_elements(p_items) e
      where e.value<>v_item and regexp_replace(lower(coalesce(e.value->>'word','')),'[^a-z0-9]','','g')=v_norm
    ) then raise exception 'Duplicate word inside Hindu payload: %',v_word; end if;

    select s into v_slot from generate_series(1,20) s
    where not exists(select 1 from english.hindu_words h where h.hindu_id='HINDU'||to_char(v_day,'YYYYMMDD')||'_'||lpad(s::text,2,'0'))
    order by s limit 1;
    if v_slot is null then raise exception 'No Hindu slot available'; end if;

    v_hindu_id:='HINDU'||to_char(v_day,'YYYYMMDD')||'_'||lpad(v_slot::text,2,'0');
    v_qid:='HV'||to_char(v_day,'YYYYMMDD')||'_'||lpad(v_slot::text,3,'0');
    v_concept:='HINDU_WORD_'||trim(both '_' from regexp_replace(upper(v_word),'[^A-Z0-9]+','_','g'));

    if exists(select 1 from english.questions q where q.question_id=v_qid) then raise exception 'Hindu Question_ID already exists: %',v_qid; end if;

    insert into english.hindu_words(
      hindu_id,word_date,word,part_of_speech,meaning,synonyms,antonyms,example_sentence,word_family,usage_note,tip,memory_aid,
      article_title,source_url,source_name,learning_status,content_status,active
    ) values (
      v_hindu_id,v_day,v_word,nullif(v_item->>'partOfSpeech',''),v_item->>'meaning',coalesce(v_item->>'synonyms',''),coalesce(v_item->>'antonyms',''),
      coalesce(v_item->>'example',''),coalesce(v_item->>'wordFamily',''),coalesce(v_item->>'usageNote',''),coalesce(v_item->>'tip',''),coalesce(v_item->>'memoryAid',''),
      v_item->>'articleTitle',v_item->>'sourceUrl',v_item->>'sourceName','New','Active',true
    );

    insert into english.questions(
      question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,
      source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,tip,usage_note,
      example_sentence,memory_aid,related_words,source_url,review_notes,active,created_at,updated_at
    ) values (
      v_qid,'The Hindu Vocabulary',v_word,v_item->>'question',v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',v_item->>'optionD',v_correct,v_item->>'explanation',
      'Daily News Vocabulary',coalesce(nullif(v_item->>'questionType',''),'Vocabulary MCQ'),v_source_file,coalesce(v_item->>'sourcePage',''),v_concept,
      coalesce(nullif(v_item->>'difficulty',''),'Hard'),v_source_id,'New','Active','SSC CGL',coalesce(v_item->>'tip',''),coalesce(v_item->>'usageNote',''),
      coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),coalesce(v_item->>'relatedWords',''),v_item->>'sourceUrl',
      case when v_distinct_exception then 'Daily Hindu distinct-sense exception: '||v_review_note else coalesce(v_review_note,'') end,true,now(),now()
    );

    insert into english.concepts(concept_id,domain,skill_family,name,description,confidence,exam_relevance,priority_score,coverage_state,is_atomic,active,metadata)
    values(v_concept,'English','The Hindu Vocabulary','Daily News Vocabulary',v_item->>'meaning','high','high',80,'unseen',true,true,
           jsonb_build_object('sourceId',v_source_id,'word',v_word,'sourceUrl',v_item->>'sourceUrl'))
    on conflict(concept_id) do update set active=true,description=excluded.description,updated_at=now();

    insert into english.question_concept_mappings(question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type)
    values(v_qid,v_concept,1,'deterministic_metadata','mapped','primary')
    on conflict(question_id) do update set concept_id=excluded.concept_id,mapping_confidence=1,mapping_method='deterministic_metadata',review_status='mapped',updated_at=now();

    v_created:=array_append(v_created,v_qid);
  end loop;

  select count(*) into v_count from english.hindu_words h where h.word_date=v_day and h.active;
  insert into english.sources(source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,source_ref,notes,import_status,new_count,duplicate_count,category_summary,processed_on)
  values(v_source_id,'Daily News Vocabulary',v_source_file,v_source_file,v_day,true,now(),v_count,'ChatGPT private OIDC Hindu bridge',
    'Current-news vocabulary researched by ChatGPT; canonical writes use deterministic duplicate gates and Central Intelligence mapping.',
    case when v_count=20 then 'Complete' else 'Partial' end,v_count,0,'The Hindu Vocabulary: '||v_count,now())
  on conflict(source_id) do update set question_count=excluded.question_count,active=true,source_ref=excluded.source_ref,notes=excluded.notes,
    import_status=excluded.import_status,new_count=excluded.new_count,duplicate_count=0,category_summary=excluded.category_summary,processed_on=now();

  select count(*) into v_bad
  from english.hindu_words h
  left join english.questions q on q.question_id='HV'||to_char(v_day,'YYYYMMDD')||'_'||right(h.hindu_id,2)::int::text
  where false;
  -- Explicit cross-table integrity uses deterministic IDs and mappings.
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
$function$;

create or replace function english.maintenance_verify_hindu_daily()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text:='HINDU_'||to_char(v_day,'YYYYMMDD');
  v_h integer; v_q integer; v_m integer; v_bad integer;
begin
  select count(*) into v_h from english.hindu_words h where h.word_date=v_day and h.active;
  select count(*) into v_q from english.questions q where q.active and q.source_id=v_source_id and q.topic='The Hindu Vocabulary';
  select count(*) into v_m from english.questions q join english.question_concept_mappings m on m.question_id=q.question_id and m.concept_id=q.concept_id where q.active and q.source_id=v_source_id;
  select count(*) into v_bad from english.questions q where q.active and q.source_id=v_source_id and (
    btrim(q.question)='' or btrim(coalesce(q.option_a,''))='' or btrim(coalesce(q.option_b,''))='' or btrim(coalesce(q.option_c,''))='' or btrim(coalesce(q.option_d,''))=''
    or upper(coalesce(q.correct,'')) not in ('A','B','C','D') or btrim(coalesce(q.explanation,''))='' or q.concept_id is null or btrim(coalesce(q.source_url,''))=''
  );
  return jsonb_build_object(
    'ok',(v_h=v_q and v_q=v_m and v_bad=0 and v_h<=20),
    'date',v_day,'sourceId',v_source_id,'hinduCount',v_h,'questionCount',v_q,'mappedCount',v_m,'badCount',v_bad,
    'sourceComplete',exists(select 1 from english.sources s where s.source_id=v_source_id and s.active and s.question_count=v_h and lower(coalesce(s.import_status,''))=case when v_h=20 then 'complete' else 'partial' end),
    'complete20',(v_h=20 and v_q=20 and v_m=20 and v_bad=0)
  );
end
$function$;

create or replace function public.english_phrasal_task_claim()
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','english' as $function$
declare v_day date:=(now() at time zone 'Asia/Kolkata')::date; v_verify jsonb; v_batch jsonb; v_run uuid; v_active uuid; begin
  perform pg_advisory_xact_lock(hashtext('english.phrasal_chatgpt_task'));
  v_verify:=english.maintenance_verify_phrasal_daily();
  if coalesce((v_verify->>'ok')::boolean,false) then return jsonb_build_object('ok',true,'count',0,'complete',true,'verification',v_verify); end if;
  update english.chatgpt_content_task_runs set status='superseded',updated_at=now() where lane='phrasal' and batch_date=v_day and status='claimed' and created_at<now()-interval '2 hours';
  select run_id into v_active from english.chatgpt_content_task_runs where lane='phrasal' and batch_date=v_day and status='claimed' order by created_at desc limit 1;
  if v_active is not null then return jsonb_build_object('ok',true,'busy',true,'runId',v_active); end if;
  v_batch:=english.maintenance_phrasal_batch(20); v_run:=gen_random_uuid();
  insert into english.chatgpt_content_task_runs(run_id,lane,batch_date,status) values(v_run,'phrasal',v_day,'claimed');
  return v_batch||jsonb_build_object('runId',v_run,'busy',false);
end $function$;

create or replace function public.english_phrasal_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','english' as $function$
declare r english.chatgpt_content_task_runs%rowtype; v_apply jsonb; v_verify jsonb; begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='phrasal' for update;
  if not found then raise exception 'Unknown Phrasal run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status<>'claimed' then raise exception 'Phrasal run is not claimable: %',r.status; end if;
  v_apply:=english.maintenance_apply_phrasal_daily(p_items); v_verify:=english.maintenance_verify_phrasal_daily();
  if not coalesce((v_verify->>'ok')::boolean,false) then raise exception 'Phrasal verification failed after apply'; end if;
  update english.chatgpt_content_task_runs set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify),applied_at=now(),updated_at=now() where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify);
end $function$;

create or replace function public.english_hindu_task_claim()
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','english' as $function$
declare v_day date:=(now() at time zone 'Asia/Kolkata')::date; v_status jsonb; v_run uuid; v_active uuid; begin
  perform pg_advisory_xact_lock(hashtext('english.hindu_chatgpt_task'));
  v_status:=english.maintenance_hindu_status();
  if coalesce((v_status->>'missing')::int,0)=0 then return v_status||jsonb_build_object('count',0,'complete',true); end if;
  update english.chatgpt_content_task_runs set status='superseded',updated_at=now() where lane='hindu' and batch_date=v_day and status in ('claimed','checked') and created_at<now()-interval '4 hours';
  select run_id into v_active from english.chatgpt_content_task_runs where lane='hindu' and batch_date=v_day and status in ('claimed','checked') order by created_at desc limit 1;
  if v_active is not null then return jsonb_build_object('ok',true,'busy',true,'runId',v_active,'status',v_status); end if;
  v_run:=gen_random_uuid(); insert into english.chatgpt_content_task_runs(run_id,lane,batch_date,status) values(v_run,'hindu',v_day,'claimed');
  return v_status||jsonb_build_object('runId',v_run,'busy',false,'count',coalesce((v_status->>'missing')::int,0));
end $function$;

create or replace function public.english_hindu_task_check_candidates(p_run_id uuid,p_candidates jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','english' as $function$
declare r english.chatgpt_content_task_runs%rowtype; v jsonb; begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='hindu' for update;
  if not found or r.status not in ('claimed','checked') then raise exception 'Hindu run is not available for candidate check'; end if;
  v:=english.maintenance_hindu_check_candidates(p_candidates);
  update english.chatgpt_content_task_runs set status='checked',updated_at=now() where run_id=p_run_id;
  return v||jsonb_build_object('runId',p_run_id);
end $function$;

create or replace function public.english_hindu_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','english' as $function$
declare r english.chatgpt_content_task_runs%rowtype; v_apply jsonb; v_verify jsonb; begin
  select * into r from english.chatgpt_content_task_runs where run_id=p_run_id and lane='hindu' for update;
  if not found then raise exception 'Unknown Hindu run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status not in ('claimed','checked') then raise exception 'Hindu run is not applicable: %',r.status; end if;
  v_apply:=english.maintenance_apply_hindu_daily(p_items); v_verify:=english.maintenance_verify_hindu_daily();
  if not coalesce((v_verify->>'ok')::boolean,false) then raise exception 'Hindu verification failed after apply'; end if;
  update english.chatgpt_content_task_runs set status='applied',result=jsonb_build_object('apply',v_apply,'verify',v_verify),applied_at=now(),updated_at=now() where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify);
end $function$;

revoke all on function english.maintenance_hindu_status() from public,anon,authenticated;
revoke all on function english.maintenance_hindu_check_candidates(jsonb) from public,anon,authenticated;
revoke all on function english.maintenance_apply_hindu_daily(jsonb) from public,anon,authenticated;
revoke all on function english.maintenance_verify_hindu_daily() from public,anon,authenticated;
grant execute on function english.maintenance_hindu_status() to service_role;
grant execute on function english.maintenance_hindu_check_candidates(jsonb) to service_role;
grant execute on function english.maintenance_apply_hindu_daily(jsonb) to service_role;
grant execute on function english.maintenance_verify_hindu_daily() to service_role;
revoke all on function public.english_phrasal_task_claim() from public,anon,authenticated;
revoke all on function public.english_phrasal_task_apply(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.english_hindu_task_claim() from public,anon,authenticated;
revoke all on function public.english_hindu_task_check_candidates(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.english_hindu_task_apply(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.english_phrasal_task_claim() to service_role;
grant execute on function public.english_phrasal_task_apply(uuid,jsonb) to service_role;
grant execute on function public.english_hindu_task_claim() to service_role;
grant execute on function public.english_hindu_task_check_candidates(uuid,jsonb) to service_role;
grant execute on function public.english_hindu_task_apply(uuid,jsonb) to service_role;

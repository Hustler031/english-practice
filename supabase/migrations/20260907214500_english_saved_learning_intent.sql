-- My Saved learning intent is independent from capture category.
-- AUTO resolution uses only the raw saved request + authoritative question family, never generated enrichment.

alter table english.saved_item_types
  add column if not exists learning_intent text not null default 'AUTO',
  add column if not exists learning_intent_origin text not null default 'LEGACY_UNKNOWN';

alter table english.saved_item_types drop constraint if exists saved_item_types_learning_intent_check;
alter table english.saved_item_types add constraint saved_item_types_learning_intent_check
  check (learning_intent in ('AUTO','MEANING','USAGE','CONFUSION'));
alter table english.saved_item_types drop constraint if exists saved_item_types_learning_intent_origin_check;
alter table english.saved_item_types add constraint saved_item_types_learning_intent_origin_check
  check (learning_intent_origin in ('AUTO','USER_EXPLICIT','LEGACY_UNKNOWN'));

create or replace function english.resolve_saved_learning_intent_authoritative(
  p_learning_intent text,
  p_word text,
  p_family text
)
returns text
language plpgsql
immutable
set search_path to pg_catalog, public, english
as $function$
declare
  v_intent text:=upper(btrim(coalesce(p_learning_intent,'AUTO')));
  v_raw text:=lower(btrim(coalesce(p_word,'')));
  v_family text:=upper(btrim(coalesce(p_family,'V')));
begin
  if v_intent in ('MEANING','USAGE','CONFUSION') then return v_intent; end if;

  if v_raw ~ '(confus|difference|different|distinguish|mix[ -]?up|similar[[:space:]]+words?|farak|fark|versus|(^|[[:space:]])vs([[:space:]]|$))' then
    return 'CONFUSION';
  end if;
  if v_raw ~ '(sentence[[:space:]]*(me|mein)?|use[[:space:]]+(it[[:space:]]+)?in[[:space:]]+(a[[:space:]]+)?sentence|how[[:space:]]+to[[:space:]]+use|usage|use[[:space:]]*(kro|karo)|example[[:space:]]+sentence)' then
    return 'USAGE';
  end if;

  if v_family in ('V','SM','OWS','CU')
     and length(v_raw) <= 180
     and (
       v_raw ~ '(^|[[:space:]])and([[:space:]]|$)'
       or position(',' in v_raw)>0
       or position('/' in v_raw)>0
       or position(';' in v_raw)>0
     )
  then
    return 'CONFUSION';
  end if;

  return 'MEANING';
end;
$function$;

create or replace function public.english_save_word_with_intent(
  p_word text,
  p_context text default ''::text,
  p_question_id text default ''::text,
  p_module text default ''::text,
  p_source text default ''::text,
  p_capture_type text default 'AUTO'::text,
  p_learning_intent text default 'AUTO'::text
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  uid uuid:=auth.uid();
  v_word text:=btrim(coalesce(p_word,''));
  v_requested_capture text:=upper(btrim(coalesce(p_capture_type,'AUTO')));
  v_requested_intent text:=upper(btrim(coalesce(p_learning_intent,'AUTO')));
  v_capture text;
  v_capture_origin text;
  v_existing_capture text;
  v_existing_capture_origin text;
  v_intent text;
  v_intent_origin text;
  v_existing_intent text;
  v_existing_intent_origin text;
  v_old_family text;
  v_old_required_intent text;
  v_origin_topic text:='';
  v_family text;
  v_required_intent text;
  v_requeue boolean:=false;
  s english.saved_items%rowtype;
  v_id text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_word='' then raise exception 'Enter a word first.'; end if;
  if v_requested_capture not in ('AUTO','V','SM','OWS','PV','IP','CU') then raise exception 'Invalid capture type'; end if;
  if v_requested_intent not in ('AUTO','MEANING','USAGE','CONFUSION') then raise exception 'Invalid learning intent'; end if;

  select * into s
  from english.saved_items
  where user_id=uid and active and lower(btrim(coalesce(word,'')))=lower(v_word)
  order by created_at desc nulls last
  limit 1;

  if found then
    select t.capture_type,t.capture_origin,t.resolved_type,t.learning_intent,t.learning_intent_origin
      into v_existing_capture,v_existing_capture_origin,v_old_family,v_existing_intent,v_existing_intent_origin
    from english.saved_item_types t
    where t.user_id=uid and t.saved_id=s.saved_id;

    if v_requested_capture='AUTO' and v_existing_capture in ('V','SM','OWS','PV','IP','CU') then
      v_capture:=v_existing_capture;
      v_capture_origin:=coalesce(v_existing_capture_origin,'LEGACY_UNKNOWN');
    else
      v_capture:=v_requested_capture;
      v_capture_origin:=case when v_requested_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
    end if;

    if v_requested_intent='AUTO' and v_existing_intent in ('MEANING','USAGE','CONFUSION')
       and coalesce(v_existing_intent_origin,'LEGACY_UNKNOWN')='USER_EXPLICIT' then
      v_intent:=v_existing_intent;
      v_intent_origin:='USER_EXPLICIT';
    else
      v_intent:=v_requested_intent;
      v_intent_origin:=case when v_requested_intent='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
    end if;

    update english.saved_items
    set context=case when btrim(coalesce(p_context,''))<>'' then btrim(p_context) else context end,
        origin_question_id=case when btrim(coalesce(p_question_id,''))<>'' then btrim(p_question_id) else origin_question_id end,
        origin_module=case when btrim(coalesce(p_module,''))<>'' then btrim(p_module) else origin_module end,
        source=case when btrim(coalesce(p_source,''))<>'' then btrim(p_source) else source end,
        updated_at=now()
    where user_id=uid and saved_id=s.saved_id
    returning * into s;

    select coalesce(q.topic,'') into v_origin_topic
    from english.questions q where q.question_id=s.origin_question_id limit 1;

    v_family:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
    v_required_intent:=english.resolve_saved_learning_intent_authoritative(v_intent,s.word,v_family);
    v_old_required_intent:=english.resolve_saved_learning_intent_authoritative(coalesce(v_existing_intent,'AUTO'),s.word,coalesce(v_old_family,v_family));
    v_requeue:=coalesce(v_old_family,'') is distinct from v_family
               or v_old_required_intent is distinct from v_required_intent;

    insert into english.saved_item_types(
      user_id,saved_id,capture_type,resolved_type,capture_origin,
      learning_intent,learning_intent_origin,updated_at
    )
    values(uid,s.saved_id,v_capture,v_family,v_capture_origin,v_intent,v_intent_origin,now())
    on conflict(user_id,saved_id) do update set
      capture_type=excluded.capture_type,
      resolved_type=excluded.resolved_type,
      capture_origin=excluded.capture_origin,
      learning_intent=excluded.learning_intent,
      learning_intent_origin=excluded.learning_intent_origin,
      updated_at=excluded.updated_at;

    if v_requeue then
      update english.saved_items
      set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
      where user_id=uid and saved_id=s.saved_id;
      insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_error,last_error_at,next_attempt_at,updated_at)
      values(uid,s.saved_id,'pending',0,null,null,null,null,now())
      on conflict(user_id,saved_id) do update set
        state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now();
    end if;

    if v_requeue or lower(btrim(coalesce(s.gpt_status,''))) in ('','pending gpt','needs enrichment') then
      begin perform english.kick_saved_enrichment_worker(1);
      exception when others then raise warning 'My Saved enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
    end if;

    return jsonb_build_object(
      'ok',true,'id',s.saved_id,'duplicate',true,'status',coalesce(s.status,'Saved'),
      'gpt_status',case when v_requeue then 'Needs Enrichment' else coalesce(s.gpt_status,'Pending GPT') end,
      'capture_type',v_capture,'resolved_type',v_family,'capture_origin',v_capture_origin,
      'learning_intent',v_intent,'resolved_learning_intent',v_required_intent,
      'learning_intent_origin',v_intent_origin,'reenrichmentQueued',v_requeue
    );
  end if;

  v_capture:=v_requested_capture;
  v_capture_origin:=case when v_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
  v_intent:=v_requested_intent;
  v_intent_origin:=case when v_intent='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
  v_id:='MW_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD_HH24MISS')||'_'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  insert into english.saved_items(
    saved_id,user_id,word,meaning,context,origin_question_id,origin_module,source,
    created_at,updated_at,status,practice_question_id,active,part_of_speech,synonyms,antonyms,example,
    explanation,question,option_a,option_b,option_c,option_d,correct_option,gpt_status,gpt_updated_at,gpt_source
  )
  values(
    v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),nullif(btrim(coalesce(p_question_id,'')),''),
    nullif(btrim(coalesce(p_module,'')),''),nullif(btrim(coalesce(p_source,'')),''),
    now(),now(),'Saved',null,true,'','','','','','','','','','','','Pending GPT',null,''
  )
  returning * into s;

  select coalesce(q.topic,'') into v_origin_topic
  from english.questions q where q.question_id=s.origin_question_id limit 1;

  v_family:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
  v_required_intent:=english.resolve_saved_learning_intent_authoritative(v_intent,s.word,v_family);

  insert into english.saved_item_types(
    user_id,saved_id,capture_type,resolved_type,capture_origin,
    learning_intent,learning_intent_origin,updated_at
  )
  values(uid,v_id,v_capture,v_family,v_capture_origin,v_intent,v_intent_origin,now());

  begin perform english.kick_saved_enrichment_worker(1);
  exception when others then raise warning 'My Saved immediate enrichment kick failed for %: %',v_id,sqlerrm; end;

  return jsonb_build_object(
    'ok',true,'id',v_id,'duplicate',false,'status','Saved','gpt_status','Pending GPT',
    'capture_type',v_capture,'resolved_type',v_family,'capture_origin',v_capture_origin,
    'learning_intent',v_intent,'resolved_learning_intent',v_required_intent,
    'learning_intent_origin',v_intent_origin
  );
end;
$function$;

create or replace function public.english_save_word(
  p_word text,
  p_context text default ''::text,
  p_question_id text default ''::text,
  p_module text default ''::text,
  p_source text default ''::text,
  p_capture_type text default 'AUTO'::text
)
returns jsonb
language sql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
  select public.english_save_word_with_intent(
    p_word,p_context,p_question_id,p_module,p_source,p_capture_type,'AUTO'
  );
$function$;

create or replace function public.english_set_saved_learning_intent(p_saved_id text,p_learning_intent text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  uid uuid:=auth.uid();
  s english.saved_items%rowtype;
  v_intent text:=upper(btrim(coalesce(p_learning_intent,'')));
  v_old_intent text;
  v_old_required text;
  v_new_required text;
  v_family text;
  v_origin text;
  v_changed boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_intent not in ('AUTO','MEANING','USAGE','CONFUSION') then raise exception 'Invalid learning intent'; end if;

  select * into s from english.saved_items
  where saved_id=btrim(p_saved_id) and user_id=uid and active;
  if not found then raise exception 'Saved item not found'; end if;

  select coalesce(t.learning_intent,'AUTO'),coalesce(t.resolved_type,'V')
    into v_old_intent,v_family
  from english.saved_item_types t
  where t.user_id=uid and t.saved_id=s.saved_id;

  v_old_required:=english.resolve_saved_learning_intent_authoritative(v_old_intent,s.word,v_family);
  v_new_required:=english.resolve_saved_learning_intent_authoritative(v_intent,s.word,v_family);
  v_origin:=case when v_intent='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
  v_changed:=v_old_intent is distinct from v_intent or v_old_required is distinct from v_new_required;

  update english.saved_item_types
  set learning_intent=v_intent,learning_intent_origin=v_origin,updated_at=now()
  where user_id=uid and saved_id=s.saved_id;

  if v_changed then
    update english.saved_items
    set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
    where user_id=uid and saved_id=s.saved_id;
    insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_error,last_error_at,next_attempt_at,updated_at)
    values(uid,s.saved_id,'pending',0,null,null,null,null,now())
    on conflict(user_id,saved_id) do update set
      state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now();
    begin perform english.kick_saved_enrichment_worker(1);
    exception when others then raise warning 'My Saved learning-intent enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
  end if;

  return jsonb_build_object(
    'ok',true,'id',s.saved_id,'learning_intent',v_intent,
    'resolved_learning_intent',v_new_required,'learning_intent_origin',v_origin,
    'reenrichmentQueued',v_changed
  );
end;
$function$;

create or replace function english.maintenance_saved_enrichment_batch(p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
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
      english.resolve_saved_type_authoritative(coalesce(t.capture_type,'AUTO'),s.word,s.context,coalesce(q.topic,'')) as "resolvedType",
      coalesce(t.learning_intent,'AUTO') as "learningIntent",
      coalesce(t.learning_intent_origin,'LEGACY_UNKNOWN') as "learningIntentOrigin",
      english.resolve_saved_learning_intent_authoritative(
        coalesce(t.learning_intent,'AUTO'),
        s.word,
        english.resolve_saved_type_authoritative(coalesce(t.capture_type,'AUTO'),s.word,s.context,coalesce(q.topic,''))
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
$function$;

grant execute on function public.english_save_word_with_intent(text,text,text,text,text,text,text) to authenticated,service_role;
grant execute on function public.english_set_saved_learning_intent(text,text) to authenticated,service_role;
grant execute on function english.resolve_saved_learning_intent_authoritative(text,text,text) to authenticated,service_role;

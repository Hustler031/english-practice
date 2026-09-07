-- My Saved category integrity: AUTO remains learner intent, resolved_type drives generation.
-- Also exposes CU as a first-class selectable capture type and strengthens deterministic AUTO inference.

create or replace function english.resolve_saved_type(
  p_capture_type text,
  p_word text,
  p_meaning text,
  p_context text,
  p_part_of_speech text,
  p_question text,
  p_explanation text
)
returns text
language sql
immutable
set search_path to pg_catalog, english
as $function$
with x as (
  select
    upper(btrim(coalesce(p_capture_type,'AUTO'))) as capture,
    lower(btrim(coalesce(p_word,''))) as word,
    lower(coalesce(p_part_of_speech,'')) as pos,
    lower(concat_ws(' ',p_word,p_context,p_meaning,p_question,p_explanation)) as txt
)
select case
  when capture in ('V','SM','OWS','PV','IP','CU') then capture

  -- Spelling must win over generic "confusion"/"usage" signals.
  when pos ~ '(spelling|misspell)'
    or txt ~ '(origin[ -]?topic[: ]+(spelling|spelling mistakes)|\mspell(ing|ed|t)?\M|misspell|correct spelling|incorrect spelling|wrong spelling)'
    then 'SM'

  -- Strong phrasal-verb evidence from origin/topic/POS or common verb+particle forms.
  when pos ~ 'phrasal[[:space:]]+verb'
    or txt ~ 'origin[ -]?topic[: ]+phrasal verbs?'
    or word ~ '^(back|bear|beat|blow|break|bring|brush|call|carry|check|clear|close|come|count|cross|cut|do|drop|end|fall|fill|find|get|give|go|hand|hang|hold|keep|leave|let|live|look|make|move|pass|pay|pick|point|pull|put|read|run|see|set|show|speak|split|stand|step|stick|take|throw|try|turn|walk|wear|work|write)[[:space:]]+(about|across|after|along|around|aside|away|back|by|down|for|forth|forward|in|into|off|on|out|over|through|to|up|upon|with)([[:space:]]+(about|across|after|along|around|away|back|down|for|from|in|into|of|off|on|out|over|through|to|up|with))?$'
    then 'PV'

  when pos ~ '(one[- ]word[[:space:]]+substitution|\mows\M)'
    or txt ~ 'origin[ -]?topic[: ]+one word substitution|one[- ]word[[:space:]]+substitution'
    then 'OWS'

  when pos ~ '(idiom|idiomatic)'
    or txt ~ 'origin[ -]?topic[: ]+(idioms?[[:space:]]*&[[:space:]]*phrases|idiom)|\midiom(at(ic)?)?\M'
    then 'IP'

  -- CU = grammar / usage / confusable-rule lane. This deliberately includes
  -- fixed prepositions and rule statements such as "many a + singular noun + singular verb".
  when pos ~ '(concept[[:space:]]*/[[:space:]]*usage|grammar[[:space:]]*[-/]?[[:space:]]*usage|(^|\W)cu(\W|$))'
    or txt ~ '(origin[ -]?topic[: ]+(grammar / usage|fixed preposition|error detection)|grammar|usage|confusable|confusion|countable|uncountable|subject[- ]verb|subject verb|agreement|singular[[:space:]]+(noun|verb)|plural[[:space:]]+(noun|verb)|many[[:space:]]+a\M|article|determiner|pronoun|fixed[[:space:]]+preposition|preposition[[:space:]]+(rule|usage)|tense|active[[:space:]]+voice|passive[[:space:]]+voice|narration|reported[[:space:]]+speech|conditional|modifier|parallelism|error[[:space:]]+(detection|spotting)|sentence[[:space:]]+correction|figurative|metaphor|tone|passage|belief[[:space:]]+vs[[:space:]]+believe|\mvs\M.*\musage\M)'
    then 'CU'

  else 'V'
end
from x;
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
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  uid uuid := auth.uid();
  v_word text := btrim(coalesce(p_word,''));
  v_requested_capture text := upper(btrim(coalesce(p_capture_type,'AUTO')));
  v_capture text;
  v_existing_capture text;
  v_origin_topic text := '';
  s english.saved_items%rowtype;
  v_id text;
  v_resolved text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_word = '' then raise exception 'Enter a word first.'; end if;
  if v_requested_capture not in ('AUTO','V','SM','OWS','PV','IP','CU') then raise exception 'Invalid capture type'; end if;

  select * into s
  from english.saved_items
  where user_id=uid and active and lower(btrim(coalesce(word,'')))=lower(v_word)
  order by created_at desc nulls last
  limit 1;

  if found then
    select t.capture_type into v_existing_capture
    from english.saved_item_types t
    where t.user_id=uid and t.saved_id=s.saved_id;

    -- Re-saving a duplicate with the default AUTO button must not silently erase
    -- a learner's earlier explicit category. Explicit -> explicit remains an intentional recategorization.
    v_capture := case
      when v_requested_capture='AUTO' and v_existing_capture in ('V','SM','OWS','PV','IP','CU') then v_existing_capture
      else v_requested_capture
    end;

    update english.saved_items
    set context=case when btrim(coalesce(p_context,''))<>'' then btrim(p_context) else context end,
        origin_question_id=case when btrim(coalesce(p_question_id,''))<>'' then btrim(p_question_id) else origin_question_id end,
        origin_module=case when btrim(coalesce(p_module,''))<>'' then btrim(p_module) else origin_module end,
        source=case when btrim(coalesce(p_source,''))<>'' then btrim(p_source) else source end,
        updated_at=now(),
        gpt_status=case when coalesce(btrim(gpt_status),'')='' and coalesce(btrim(practice_question_id),'')='' then 'Pending GPT' else gpt_status end
    where saved_id=s.saved_id
    returning * into s;

    select coalesce(q.topic,'') into v_origin_topic
    from english.questions q
    where q.question_id=s.origin_question_id
    limit 1;

    v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,concat_ws(' ',s.context,case when v_origin_topic<>'' then 'Origin topic: '||v_origin_topic end),s.part_of_speech,s.question,s.explanation);
    insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
    values(uid,s.saved_id,v_capture,v_resolved,now())
    on conflict(user_id,saved_id) do update
      set capture_type=excluded.capture_type,
          resolved_type=excluded.resolved_type,
          updated_at=excluded.updated_at;

    if lower(btrim(coalesce(s.gpt_status,''))) in ('','pending gpt','needs enrichment') then
      begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved immediate enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
    end if;

    return jsonb_build_object('ok',true,'id',s.saved_id,'duplicate',true,'status',coalesce(s.status,'Saved'),'gpt_status',coalesce(s.gpt_status,'Pending GPT'),'capture_type',v_capture,'resolved_type',v_resolved);
  end if;

  v_capture:=v_requested_capture;
  v_id:='MW_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD_HH24MISS')||'_'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  insert into english.saved_items(
    saved_id,user_id,word,meaning,context,origin_question_id,origin_module,source,
    created_at,updated_at,status,practice_question_id,active,part_of_speech,synonyms,
    antonyms,example,explanation,question,option_a,option_b,option_c,option_d,
    correct_option,gpt_status,gpt_updated_at,gpt_source
  ) values (
    v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),
    nullif(btrim(coalesce(p_question_id,'')),''),nullif(btrim(coalesce(p_module,'')),''),
    nullif(btrim(coalesce(p_source,'')),''),now(),now(),'Saved',null,true,
    '','','','','','','','','','','','Pending GPT',null,''
  )
  returning * into s;

  select coalesce(q.topic,'') into v_origin_topic
  from english.questions q
  where q.question_id=s.origin_question_id
  limit 1;

  v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,concat_ws(' ',s.context,case when v_origin_topic<>'' then 'Origin topic: '||v_origin_topic end),s.part_of_speech,s.question,s.explanation);
  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
  values(uid,v_id,v_capture,v_resolved,now());

  begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved immediate enrichment kick failed for %: %',v_id,sqlerrm; end;

  return jsonb_build_object('ok',true,'id',v_id,'duplicate',false,'status','Saved','gpt_status','Pending GPT','capture_type',v_capture,'resolved_type',v_resolved);
end;
$function$;

create or replace function public.english_set_saved_item_type(p_saved_id text,p_capture_type text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  uid uuid:=auth.uid();
  s english.saved_items%rowtype;
  v_capture text:=upper(btrim(coalesce(p_capture_type,'')));
  v_resolved text;
  v_old_capture text;
  v_origin_topic text:='';
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_capture not in ('AUTO','V','SM','OWS','PV','IP','CU') then raise exception 'Invalid capture type'; end if;
  select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid;
  if not found then raise exception 'Saved item not found'; end if;

  select capture_type into v_old_capture from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
  select coalesce(q.topic,'') into v_origin_topic from english.questions q where q.question_id=s.origin_question_id limit 1;

  v_resolved:=english.resolve_saved_type(v_capture,s.word,s.meaning,concat_ws(' ',s.context,case when v_origin_topic<>'' then 'Origin topic: '||v_origin_topic end),s.part_of_speech,s.question,s.explanation);
  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
  values(uid,s.saved_id,v_capture,v_resolved,now())
  on conflict(user_id,saved_id) do update
    set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

  if v_old_capture is distinct from v_capture then
    update english.saved_items set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now() where user_id=uid and saved_id=s.saved_id;
    update english.saved_enrichment_item_state set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now() where user_id=uid and saved_id=s.saved_id;
    begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved category-change enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
  end if;

  return jsonb_build_object('ok',true,'id',s.saved_id,'capture_type',v_capture,'resolved_type',v_resolved,'reenrichmentQueued',v_old_capture is distinct from v_capture);
end;
$function$;

create or replace function public.english_set_saved_enrichment(
  p_saved_id text,p_meaning text,p_part_of_speech text,p_synonyms text,p_antonyms text,p_example text,p_explanation text,
  p_question text,p_option_a text,p_option_b text,p_option_c text,p_option_d text,p_correct_option text,
  p_source text default ''::text,p_gpt_status text default 'Ready'::text
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  uid uuid:=auth.uid();
  s english.saved_items%rowtype;
  t english.saved_item_types%rowtype;
  v_resolved text;
  v_origin_topic text:='';
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid;
  if not found then raise exception 'Saved item not found'; end if;

  update english.saved_items
  set meaning=coalesce(p_meaning,''),part_of_speech=coalesce(p_part_of_speech,''),synonyms=coalesce(p_synonyms,''),antonyms=coalesce(p_antonyms,''),example=coalesce(p_example,''),explanation=coalesce(p_explanation,''),question=coalesce(p_question,''),option_a=coalesce(p_option_a,''),option_b=coalesce(p_option_b,''),option_c=coalesce(p_option_c,''),option_d=coalesce(p_option_d,''),correct_option=upper(coalesce(p_correct_option,'')),gpt_source=coalesce(p_source,''),gpt_status=coalesce(nullif(btrim(p_gpt_status),''),'Ready'),gpt_updated_at=now(),updated_at=now()
  where saved_id=s.saved_id returning * into s;

  select * into t from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
  select coalesce(q.topic,'') into v_origin_topic from english.questions q where q.question_id=s.origin_question_id limit 1;
  v_resolved:=english.resolve_saved_type(coalesce(t.capture_type,'AUTO'),s.word,s.meaning,concat_ws(' ',s.context,case when v_origin_topic<>'' then 'Origin topic: '||v_origin_topic end),s.part_of_speech,s.question,s.explanation);

  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
  values(uid,s.saved_id,coalesce(t.capture_type,'AUTO'),v_resolved,now())
  on conflict(user_id,saved_id) do update set resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

  return jsonb_build_object('ok',true,'id',s.saved_id,'status',s.gpt_status,'capture_type',coalesce(t.capture_type,'AUTO'),'resolved_type',v_resolved);
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
      s.saved_id as "savedId",
      coalesce(s.word,'') as word,
      coalesce(s.meaning,'') as meaning,
      coalesce(s.context,'') as context,
      coalesce(s.origin_question_id,'') as "originQuestionId",
      coalesce(q.topic,'') as "originTopic",
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
      case
        when coalesce(t.capture_type,'AUTO')='AUTO' then english.resolve_saved_type('AUTO',s.word,s.meaning,concat_ws(' ',s.context,case when coalesce(q.topic,'')<>'' then 'Origin topic: '||q.topic end),s.part_of_speech,s.question,s.explanation)
        else coalesce(t.resolved_type,english.resolve_saved_type(t.capture_type,s.word,s.meaning,concat_ws(' ',s.context,case when coalesce(q.topic,'')<>'' then 'Origin topic: '||q.topic end),s.part_of_speech,s.question,s.explanation))
      end as "resolvedType",
      s.created_at,s.updated_at,s.gpt_updated_at
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    left join english.questions q on q.question_id=s.origin_question_id
    where s.active and s.user_id=v_owner
      and not (coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
      and (
        btrim(coalesce(s.gpt_status,''))=''
        or lower(btrim(coalesce(s.gpt_status,''))) in ('pending gpt','needs enrichment')
        or (lower(btrim(coalesce(s.gpt_status,'')))='needs review' and (s.gpt_updated_at is null or coalesce(s.updated_at,s.created_at)>s.gpt_updated_at+interval '1 second'))
        or (lower(btrim(coalesce(s.gpt_status,'')))='ready' and (btrim(coalesce(s.meaning,''))='' or btrim(coalesce(s.question,''))='' or btrim(coalesce(s.option_a,''))='' or btrim(coalesce(s.option_b,''))='' or btrim(coalesce(s.option_c,''))='' or btrim(coalesce(s.option_d,''))='' or upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D') or btrim(coalesce(s.explanation,''))=''))
      )
    order by case when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 0 when lower(btrim(coalesce(s.gpt_status,'')))='pending gpt' then 1 when btrim(coalesce(s.gpt_status,''))='' then 1 when lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment' then 2 else 3 end,
      s.created_at asc nulls last
    limit v_limit
  ) x;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end;
$function$;

create or replace function english.maintenance_apply_saved_enrichment(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english, auth
as $function$
declare
  v_owner uuid;
  v_owner_count integer;
  v_item jsonb;
  v_saved_id text;
  v_payload_capture text;
  v_stored_capture text;
  v_status text;
  v_result jsonb;
  v_results jsonb:='[]'::jsonb;
  v_promoted jsonb;
begin
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'p_items must be a JSON array'; end if;
  if jsonb_array_length(p_items)>25 then raise exception 'At most 25 saved items may be applied per batch'; end if;

  select count(*),max(o.user_id::text)::uuid into v_owner_count,v_owner from (select distinct s.user_id from english.saved_items s where s.active) o;
  if v_owner_count<>1 then raise exception 'Saved enrichment maintenance requires exactly one active owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_saved_id:=btrim(coalesce(v_item->>'savedId',''));
    if v_saved_id='' then raise exception 'savedId is required'; end if;

    select coalesce(t.capture_type,'AUTO') into v_stored_capture
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    where s.saved_id=v_saved_id and s.user_id=v_owner and s.active
    limit 1;
    if not found then raise exception 'Saved item is not active for the maintenance owner: %',v_saved_id; end if;

    v_payload_capture:=upper(btrim(coalesce(v_item->>'captureType',v_stored_capture)));
    if v_payload_capture<>v_stored_capture then
      raise exception 'AI payload cannot mutate saved capture type for %: stored %, payload %',v_saved_id,v_stored_capture,v_payload_capture;
    end if;

    v_status:=coalesce(nullif(btrim(v_item->>'gptStatus'),''),'Ready');
    v_result:=public.english_set_saved_enrichment(
      v_saved_id,coalesce(v_item->>'meaning',''),coalesce(v_item->>'partOfSpeech',''),coalesce(v_item->>'synonyms',''),coalesce(v_item->>'antonyms',''),coalesce(v_item->>'example',''),coalesce(v_item->>'explanation',''),coalesce(v_item->>'question',''),coalesce(v_item->>'optionA',''),coalesce(v_item->>'optionB',''),coalesce(v_item->>'optionC',''),coalesce(v_item->>'optionD',''),upper(coalesce(v_item->>'correctOption','')),coalesce(v_item->>'source','Scheduled My Saved enrichment'),v_status
    );

    v_promoted:=null;
    if lower(v_status)='ready' then v_promoted:=public.english_promote_saved_item(v_saved_id); end if;

    v_results:=v_results||jsonb_build_array(jsonb_build_object('savedId',v_saved_id,'enrichment',v_result,'promotion',v_promoted));
  end loop;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_results),'results',v_results);
end;
$function$;

create or replace function public.english_saved_enrichment_worker_apply(p_token text,p_lease_id uuid,p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, english
as $function$
declare
  x jsonb;
  v_saved_id text;
  v_capture text;
  v_resolved text;
  v_family text;
  v_question text;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;
  if not exists(select 1 from english.saved_enrichment_worker_state where singleton=true and lease_id=p_lease_id and lease_expires_at>now()) then raise exception 'saved enrichment worker lease is missing or expired'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' then raise exception 'Saved enrichment items must be an array'; end if;

  for x in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    v_saved_id:=btrim(coalesce(x->>'savedId',''));
    select coalesce(t.capture_type,'AUTO'),coalesce(t.resolved_type,'V') into v_capture,v_resolved
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    where s.saved_id=v_saved_id and s.active
    limit 1;
    if not found then raise exception 'Saved enrichment item % does not exist',v_saved_id; end if;

    if upper(btrim(coalesce(x->>'captureType','')))<>v_capture then
      raise exception 'Saved item % capture type mismatch: expected %, got %',v_saved_id,v_capture,coalesce(x->>'captureType','');
    end if;

    v_family:=case when v_capture='AUTO' then v_resolved else v_capture end;
    v_question:=btrim(coalesce(x->>'question',''));

    if v_family='SM' and v_question !~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)' then
      raise exception 'Saved item % resolves to SM but generated question is not spelling-family',v_saved_id;
    end if;
    if v_family='V' and v_question ~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)' then
      raise exception 'Saved item % resolves to V but generated question is spelling-family',v_saved_id;
    end if;
  end loop;

  if english.ai_feature_enabled('groq_critic_v1') then perform english.assert_generated_items_quality(p_items,true); end if;
  return english.maintenance_apply_saved_enrichment(p_items);
end;
$function$;

-- Recompute every genuine AUTO item under the new deterministic rules and re-enrich only when its family actually changes.
create temporary table _english_saved_auto_changed on commit drop as
select t.user_id,t.saved_id,t.resolved_type as old_resolved,
  english.resolve_saved_type('AUTO',s.word,s.meaning,concat_ws(' ',s.context,case when coalesce(q.topic,'')<>'' then 'Origin topic: '||q.topic end),s.part_of_speech,s.question,s.explanation) as new_resolved
from english.saved_item_types t
join english.saved_items s on s.user_id=t.user_id and s.saved_id=t.saved_id and s.active
left join english.questions q on q.question_id=s.origin_question_id
where t.capture_type='AUTO';

update english.saved_item_types t
set resolved_type=c.new_resolved,updated_at=now()
from _english_saved_auto_changed c
where t.user_id=c.user_id and t.saved_id=c.saved_id and t.resolved_type is distinct from c.new_resolved;

update english.saved_items s
set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
from _english_saved_auto_changed c
where s.user_id=c.user_id and s.saved_id=c.saved_id and c.old_resolved is distinct from c.new_resolved;

update english.saved_enrichment_item_state es
set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now()
from _english_saved_auto_changed c
where es.user_id=c.user_id and es.saved_id=c.saved_id and c.old_resolved is distinct from c.new_resolved;

-- Repair the concrete corruption that exposed this bug without assuming other explicit learner choices were AUTO.
with target as (
  select s.user_id,s.saved_id
  from english.saved_items s
  join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
  left join english.questions q on q.question_id=s.origin_question_id
  where s.active
    and lower(btrim(s.word))='successive'
    and t.capture_type='SM'
    and coalesce(q.topic,'') in ('Vocabulary','The Hindu Vocabulary','Synonym')
    and coalesce(s.question,'') ~* '(synonym|antonym|meaning)'
    and coalesce(s.question,'') !~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)'
)
update english.saved_item_types t
set capture_type='AUTO',resolved_type='V',updated_at=now()
from target x
where t.user_id=x.user_id and t.saved_id=x.saved_id;

update english.saved_items s
set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
where s.active and lower(btrim(s.word))='successive'
  and exists(select 1 from english.saved_item_types t where t.user_id=s.user_id and t.saved_id=s.saved_id and t.capture_type='AUTO' and t.resolved_type='V');

update english.saved_enrichment_item_state es
set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now()
where exists(
  select 1 from english.saved_items s
  join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
  where s.user_id=es.user_id and s.saved_id=es.saved_id and s.active and lower(btrim(s.word))='successive' and t.capture_type='AUTO' and t.resolved_type='V'
);

select english.kick_saved_enrichment_worker(1);

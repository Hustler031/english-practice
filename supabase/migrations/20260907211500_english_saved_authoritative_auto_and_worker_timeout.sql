-- My Saved AUTO integrity hardening.
-- The classification source is learner text + origin topic only; generated enrichment is never classifier evidence.
-- Also align the scheduler HTTP budget with the AI worker's bounded runtime.

create or replace function english.resolve_saved_type_authoritative(
  p_capture_type text,
  p_word text,
  p_context text,
  p_origin_topic text
)
returns text
language sql
immutable
set search_path to pg_catalog, english
as $function$
  select english.resolve_saved_type(
    p_capture_type,
    p_word,
    '',
    concat_ws(' ',coalesce(p_context,''),case when btrim(coalesce(p_origin_topic,''))<>'' then 'Origin topic: '||btrim(p_origin_topic) end),
    '',
    '',
    ''
  );
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
    from english.questions q where q.question_id=s.origin_question_id limit 1;

    v_resolved:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
    insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
    values(uid,s.saved_id,v_capture,v_resolved,now())
    on conflict(user_id,saved_id) do update
      set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

    if lower(btrim(coalesce(s.gpt_status,''))) in ('','pending gpt','needs enrichment') then
      begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved immediate enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
    end if;
    return jsonb_build_object('ok',true,'id',s.saved_id,'duplicate',true,'status',coalesce(s.status,'Saved'),'gpt_status',coalesce(s.gpt_status,'Pending GPT'),'capture_type',v_capture,'resolved_type',v_resolved);
  end if;

  v_capture:=v_requested_capture;
  v_id:='MW_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD_HH24MISS')||'_'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));
  insert into english.saved_items(saved_id,user_id,word,meaning,context,origin_question_id,origin_module,source,created_at,updated_at,status,practice_question_id,active,part_of_speech,synonyms,antonyms,example,explanation,question,option_a,option_b,option_c,option_d,correct_option,gpt_status,gpt_updated_at,gpt_source)
  values(v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),nullif(btrim(coalesce(p_question_id,'')),''),nullif(btrim(coalesce(p_module,'')),''),nullif(btrim(coalesce(p_source,'')),''),now(),now(),'Saved',null,true,'','','','','','','','','','','','Pending GPT',null,'')
  returning * into s;

  select coalesce(q.topic,'') into v_origin_topic
  from english.questions q where q.question_id=s.origin_question_id limit 1;
  v_resolved:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
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

  v_resolved:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
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

  v_resolved:=english.resolve_saved_type_authoritative(coalesce(t.capture_type,'AUTO'),s.word,s.context,v_origin_topic);
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
    select s.saved_id as "savedId",coalesce(s.word,'') as word,coalesce(s.meaning,'') as meaning,coalesce(s.context,'') as context,
      coalesce(s.origin_question_id,'') as "originQuestionId",coalesce(q.topic,'') as "originTopic",coalesce(s.origin_module,'') as "originModule",coalesce(s.source,'') as source,
      coalesce(s.part_of_speech,'') as "partOfSpeech",coalesce(s.synonyms,'') as synonyms,coalesce(s.antonyms,'') as antonyms,coalesce(s.example,'') as example,
      coalesce(s.explanation,'') as explanation,coalesce(s.question,'') as question,coalesce(s.option_a,'') as "optionA",coalesce(s.option_b,'') as "optionB",coalesce(s.option_c,'') as "optionC",coalesce(s.option_d,'') as "optionD",coalesce(s.correct_option,'') as "correctOption",coalesce(s.gpt_status,'Pending GPT') as "gptStatus",coalesce(t.capture_type,'AUTO') as "captureType",
      english.resolve_saved_type_authoritative(coalesce(t.capture_type,'AUTO'),s.word,s.context,coalesce(q.topic,'')) as "resolvedType",
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
        or (lower(btrim(coalesce(s.gpt_status,'')))='needs review' and (s.gpt_updated_at is null or coalesce(s.updated_at,s.created_at)>s.gpt_updated_at+interval '1 second'))
        or (lower(btrim(coalesce(s.gpt_status,'')))='ready' and (
          btrim(coalesce(s.meaning,''))='' or btrim(coalesce(s.question,''))='' or btrim(coalesce(s.option_a,''))='' or btrim(coalesce(s.option_b,''))='' or btrim(coalesce(s.option_c,''))='' or btrim(coalesce(s.option_d,''))='' or upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D') or btrim(coalesce(s.explanation,''))=''
        ))
      )
    order by case when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 0 when lower(btrim(coalesce(s.gpt_status,'')))='pending gpt' then 1 when btrim(coalesce(s.gpt_status,''))='' then 1 when lower(btrim(coalesce(s.gpt_status,'')))='needs enrichment' then 2 else 3 end,s.created_at asc nulls last
    limit v_limit
  ) x;
  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
end;
$function$;

create or replace function english.kick_saved_enrichment_worker(p_limit integer default 10)
returns bigint
language plpgsql
security definer
set search_path to pg_catalog, english, net
as $function$
declare
  v_token text;
  req bigint;
begin
  perform english.reconcile_saved_enrichment_worker_http();
  select token into v_token from english.context_ai_runtime_guard where singleton=true;
  if v_token is null then raise exception 'English runtime guard missing'; end if;

  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-saved-enrichment-worker',
    body:=jsonb_build_object('limit',greatest(1,least(10,coalesce(p_limit,10)))),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=300000
  ) into req;

  insert into english.saved_enrichment_worker_requests(request_id,requested_at)
  values(req,now()) on conflict(request_id) do nothing;
  return req;
end;
$function$;

-- Repair AUTO rows whose stored family was polluted by generated enrichment.
create temporary table _saved_auto_family_repairs on commit drop as
select s.user_id,s.saved_id,
  english.resolve_saved_type_authoritative('AUTO',s.word,s.context,coalesce(q.topic,'')) as new_resolved
from english.saved_items s
join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
left join english.questions q on q.question_id=s.origin_question_id
where s.active and t.capture_type='AUTO'
  and t.resolved_type is distinct from english.resolve_saved_type_authoritative('AUTO',s.word,s.context,coalesce(q.topic,''));

update english.saved_item_types t
set resolved_type=r.new_resolved,updated_at=now()
from _saved_auto_family_repairs r
where t.user_id=r.user_id and t.saved_id=r.saved_id;

update english.saved_items s
set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now()
from _saved_auto_family_repairs r
where s.user_id=r.user_id and s.saved_id=r.saved_id;

update english.saved_enrichment_item_state es
set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now()
from _saved_auto_family_repairs r
where es.user_id=r.user_id and es.saved_id=r.saved_id;

-- Expired global lease is safe to release; active leases remain untouched.
update english.saved_enrichment_worker_state
set lease_id=null,lease_expires_at=null,updated_at=now()
where singleton=true and lease_expires_at is not null and lease_expires_at<=now();

select english.kick_saved_enrichment_worker(10);

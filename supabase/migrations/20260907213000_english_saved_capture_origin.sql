-- Track whether a Saved category came from AUTO or an explicit learner choice.
-- This prevents future repair logic from confusing deliberate capture choices with classifier output.

alter table english.saved_item_types
  add column if not exists capture_origin text not null default 'LEGACY_UNKNOWN';

alter table english.saved_item_types
  drop constraint if exists saved_item_types_capture_origin_check;
alter table english.saved_item_types
  add constraint saved_item_types_capture_origin_check
  check (capture_origin in ('AUTO','USER_EXPLICIT','LEGACY_UNKNOWN'));

update english.saved_item_types
set capture_origin='AUTO'
where capture_type='AUTO' and capture_origin='LEGACY_UNKNOWN';

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
  v_existing_origin text;
  v_capture_origin text;
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
    select t.capture_type,t.capture_origin into v_existing_capture,v_existing_origin
    from english.saved_item_types t
    where t.user_id=uid and t.saved_id=s.saved_id;

    if v_requested_capture='AUTO' and v_existing_capture in ('V','SM','OWS','PV','IP','CU') then
      v_capture:=v_existing_capture;
      v_capture_origin:=coalesce(v_existing_origin,'LEGACY_UNKNOWN');
    else
      v_capture:=v_requested_capture;
      v_capture_origin:=case when v_requested_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
    end if;

    update english.saved_items
    set context=case when btrim(coalesce(p_context,''))<>'' then btrim(p_context) else context end,
        origin_question_id=case when btrim(coalesce(p_question_id,''))<>'' then btrim(p_question_id) else origin_question_id end,
        origin_module=case when btrim(coalesce(p_module,''))<>'' then btrim(p_module) else origin_module end,
        source=case when btrim(coalesce(p_source,''))<>'' then btrim(p_source) else source end,
        updated_at=now(),
        gpt_status=case when coalesce(btrim(gpt_status),'')='' and coalesce(btrim(practice_question_id),'')='' then 'Pending GPT' else gpt_status end
    where saved_id=s.saved_id returning * into s;

    select coalesce(q.topic,'') into v_origin_topic from english.questions q where q.question_id=s.origin_question_id limit 1;
    v_resolved:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);

    insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,capture_origin,updated_at)
    values(uid,s.saved_id,v_capture,v_resolved,v_capture_origin,now())
    on conflict(user_id,saved_id) do update
      set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,capture_origin=excluded.capture_origin,updated_at=excluded.updated_at;

    if lower(btrim(coalesce(s.gpt_status,''))) in ('','pending gpt','needs enrichment') then
      begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved immediate enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
    end if;

    return jsonb_build_object('ok',true,'id',s.saved_id,'duplicate',true,'status',coalesce(s.status,'Saved'),'gpt_status',coalesce(s.gpt_status,'Pending GPT'),'capture_type',v_capture,'resolved_type',v_resolved,'capture_origin',v_capture_origin);
  end if;

  v_capture:=v_requested_capture;
  v_capture_origin:=case when v_requested_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
  v_id:='MW_'||to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD_HH24MISS')||'_'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));

  insert into english.saved_items(saved_id,user_id,word,meaning,context,origin_question_id,origin_module,source,created_at,updated_at,status,practice_question_id,active,part_of_speech,synonyms,antonyms,example,explanation,question,option_a,option_b,option_c,option_d,correct_option,gpt_status,gpt_updated_at,gpt_source)
  values(v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),nullif(btrim(coalesce(p_question_id,'')),''),nullif(btrim(coalesce(p_module,'')),''),nullif(btrim(coalesce(p_source,'')),''),now(),now(),'Saved',null,true,'','','','','','','','','','','','Pending GPT',null,'')
  returning * into s;

  select coalesce(q.topic,'') into v_origin_topic from english.questions q where q.question_id=s.origin_question_id limit 1;
  v_resolved:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,capture_origin,updated_at)
  values(uid,v_id,v_capture,v_resolved,v_capture_origin,now());

  begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved immediate enrichment kick failed for %: %',v_id,sqlerrm; end;
  return jsonb_build_object('ok',true,'id',v_id,'duplicate',false,'status','Saved','gpt_status','Pending GPT','capture_type',v_capture,'resolved_type',v_resolved,'capture_origin',v_capture_origin);
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
  v_capture_origin text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_capture not in ('AUTO','V','SM','OWS','PV','IP','CU') then raise exception 'Invalid capture type'; end if;
  select * into s from english.saved_items where saved_id=btrim(p_saved_id) and user_id=uid;
  if not found then raise exception 'Saved item not found'; end if;

  select capture_type into v_old_capture from english.saved_item_types where user_id=uid and saved_id=s.saved_id;
  select coalesce(q.topic,'') into v_origin_topic from english.questions q where q.question_id=s.origin_question_id limit 1;
  v_capture_origin:=case when v_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end;
  v_resolved:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);

  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,capture_origin,updated_at)
  values(uid,s.saved_id,v_capture,v_resolved,v_capture_origin,now())
  on conflict(user_id,saved_id) do update
    set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,capture_origin=excluded.capture_origin,updated_at=excluded.updated_at;

  if v_old_capture is distinct from v_capture then
    update english.saved_items set gpt_status='Needs Enrichment',practice_question_id=null,gpt_source='',updated_at=now() where user_id=uid and saved_id=s.saved_id;
    update english.saved_enrichment_item_state set state='pending',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,updated_at=now() where user_id=uid and saved_id=s.saved_id;
    begin perform english.kick_saved_enrichment_worker(1); exception when others then raise warning 'My Saved category-change enrichment kick failed for %: %',s.saved_id,sqlerrm; end;
  end if;

  return jsonb_build_object('ok',true,'id',s.saved_id,'capture_type',v_capture,'resolved_type',v_resolved,'capture_origin',v_capture_origin,'reenrichmentQueued',v_old_capture is distinct from v_capture);
end;
$function$;

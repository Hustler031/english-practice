-- Final production state for Saved enrichment retry semantics and Saved identity.
-- Earlier 20260908 Saved migrations were short-lived intermediate forms; this file is
-- intentionally idempotent so a fresh database reaches the same state as production.

alter table english.saved_enrichment_item_state
  add column if not exists transient_failure_count integer not null default 0,
  add column if not exists last_error_class text;

create or replace function english.saved_anchor_key(p_text text)
returns text
language sql
immutable
set search_path=pg_catalog
as $$
  select lower(btrim(regexp_replace(coalesce(p_text,''),'[^[:alnum:]]+',' ','g')));
$$;

create or replace function public.english_saved_enrichment_worker_claim(
  p_token text,
  p_limit integer default 3
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,english
as $$
declare
  v_lease uuid;
  v_expires timestamptz;
  v_new_lease uuid;
  v_raw jsonb;
  v_items jsonb;
  v_batch jsonb;
  v_limit integer:=greatest(1,least(3,coalesce(p_limit,3)));
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;

  -- A resource/HTTP timeout must not consume the hard content-attempt budget.
  update english.saved_enrichment_item_state es
  set state='retrying',
      attempt_count=greatest(es.attempt_count-1,0),
      transient_failure_count=es.transient_failure_count+1,
      lease_id=null,
      last_error=coalesce(es.last_error,'stale saved-enrichment processing recovered'),
      last_error_at=now(),
      last_error_class='lease_timeout',
      next_attempt_at=now()+interval '15 minutes',
      updated_at=now()
  where es.state='processing'
    and es.updated_at<now()-interval '12 minutes';

  select lease_id,lease_expires_at into v_lease,v_expires
  from english.saved_enrichment_worker_state
  where singleton=true
  for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  v_raw:=english.maintenance_saved_enrichment_batch(25);
  select coalesce(jsonb_agg(j order by ord),'[]'::jsonb)
  into v_items
  from (
    select j,ord
    from jsonb_array_elements(coalesce(v_raw->'items','[]'::jsonb)) with ordinality x(j,ord)
    join english.saved_items s on s.saved_id=j->>'savedId' and s.active
    left join english.saved_enrichment_item_state es
      on es.user_id=s.user_id and es.saved_id=s.saved_id
    where coalesce(es.state,'') not in ('processing','failed')
      and not (
        coalesce(es.state,'')='retrying'
        and es.next_attempt_at is not null
        and es.next_attempt_at>now()
      )
    order by ord
    limit v_limit
  ) picked;

  v_batch:=jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
  if jsonb_array_length(v_items)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),
        last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch||jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,lease_expires_at=now()+interval '10 minutes',
      last_started_at=now(),last_error=null,updated_at=now()
  where singleton=true;

  insert into english.saved_enrichment_item_state(
    user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,next_attempt_at,updated_at
  )
  select s.user_id,j->>'savedId','processing',1,v_new_lease,now(),null,now()
  from jsonb_array_elements(v_items) j
  join english.saved_items s on s.saved_id=j->>'savedId' and s.active
  on conflict(user_id,saved_id) do update set
    state='processing',
    attempt_count=english.saved_enrichment_item_state.attempt_count+1,
    lease_id=excluded.lease_id,
    last_attempt_at=excluded.last_attempt_at,
    next_attempt_at=null,
    updated_at=now();

  return v_batch||jsonb_build_object('busy',false,'leaseId',v_new_lease);
end;
$$;

create or replace function public.english_saved_enrichment_worker_finish_v2(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_failures jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,english
as $$
declare
  v_verified jsonb:=jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb);
  v_success_count integer:=cardinality(coalesce(p_saved_ids,'{}'::text[]));
  f jsonb;
  v_saved_id text;
  v_error text;
  v_transient boolean;
  v_delay integer;
  v_failure_count integer:=0;
  v_summary text:='';
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;
  if not exists(
    select 1 from english.saved_enrichment_worker_state
    where singleton=true and lease_id=p_lease_id
  ) then
    raise exception 'saved enrichment worker lease mismatch';
  end if;
  if jsonb_typeof(coalesce(p_failures,'[]'::jsonb))<>'array' then
    raise exception 'p_failures must be an array';
  end if;

  if v_success_count>0 then
    v_verified:=english.maintenance_verify_saved_enrichment(p_saved_ids);
    update english.saved_enrichment_item_state es
    set state='ready',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,
        last_success_at=now(),last_error_class=null,updated_at=now()
    where es.saved_id=any(p_saved_ids) and es.lease_id=p_lease_id;
  end if;

  for f in select value from jsonb_array_elements(coalesce(p_failures,'[]'::jsonb)) loop
    v_saved_id:=btrim(coalesce(f->>'savedId',''));
    v_error:=left(coalesce(nullif(btrim(f->>'error'),''),'AI enrichment attempt did not complete.'),1200);
    if v_saved_id='' then continue; end if;
    v_failure_count:=v_failure_count+1;
    v_transient:=lower(v_error) like '%429%'
      or lower(v_error) like '%quota%'
      or lower(v_error) like '%rate limit%'
      or lower(v_error) like '%resource limit%'
      or lower(v_error) like '%timeout%'
      or lower(v_error) like '%timed out%'
      or lower(v_error) like '%temporarily unavailable%'
      or lower(v_error) like '%high demand%'
      or lower(v_error) like '%overloaded%'
      or lower(v_error) like '%502%'
      or lower(v_error) like '%503%'
      or lower(v_error) like '%504%';

    if v_transient then
      select case
        when coalesce(transient_failure_count,0)<=0 then 15
        when transient_failure_count=1 then 30
        else 60
      end
      into v_delay
      from english.saved_enrichment_item_state
      where saved_id=v_saved_id and lease_id=p_lease_id;

      update english.saved_enrichment_item_state es
      set state='retrying',
          attempt_count=greatest(es.attempt_count-1,0),
          transient_failure_count=es.transient_failure_count+1,
          lease_id=null,
          last_error=v_error,last_error_at=now(),last_error_class='transient',
          next_attempt_at=now()+make_interval(mins=>coalesce(v_delay,15)),updated_at=now()
      where es.saved_id=v_saved_id and es.lease_id=p_lease_id;
    else
      update english.saved_enrichment_item_state es
      set state=case when es.attempt_count>=3 then 'failed' else 'retrying' end,
          lease_id=null,
          last_error=v_error,last_error_at=now(),last_error_class='hard',
          next_attempt_at=case when es.attempt_count>=3 then null else now()+interval '1 hour' end,
          updated_at=now()
      where es.saved_id=v_saved_id and es.lease_id=p_lease_id;
    end if;

    if v_summary='' then
      v_summary:=v_saved_id||': '||left(v_error,350);
    elsif length(v_summary)<900 then
      v_summary:=v_summary||' | '||v_saved_id||': '||left(v_error,250);
    end if;
  end loop;

  -- A leased item omitted from both lists is recoverable, never stranded.
  update english.saved_enrichment_item_state es
  set state='retrying',
      attempt_count=greatest(es.attempt_count-1,0),
      transient_failure_count=es.transient_failure_count+1,
      lease_id=null,
      last_error='Worker finished without an item result',last_error_at=now(),
      last_error_class='transient',next_attempt_at=now()+interval '15 minutes',updated_at=now()
  where es.lease_id=p_lease_id;

  update english.saved_enrichment_worker_state
  set lease_id=null,lease_expires_at=null,last_finished_at=now(),last_count=v_success_count,
      last_error=nullif(left(v_summary,1200),''),updated_at=now()
  where singleton=true and lease_id=p_lease_id;

  if v_success_count>0 and v_failure_count=0 then
    begin
      perform english.kick_saved_enrichment_worker(1);
    exception when others then
      raise warning 'My Saved follow-up enrichment kick failed: %',sqlerrm;
    end;
  end if;

  return v_verified||jsonb_build_object('successCount',v_success_count,'failureCount',v_failure_count);
end;
$$;

create or replace function public.english_saved_enrichment_worker_finish(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_error text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,english
as $$
declare
  v_failures jsonb:='[]'::jsonb;
  v_error text:=nullif(left(btrim(coalesce(p_error,'')),1200),'');
  seg text;
  sid text;
  msg text;
  pos integer;
begin
  if not english.context_worker_authorized(p_token) then
    raise exception 'saved enrichment worker unauthorized';
  end if;

  if v_error is not null then
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

  if v_error is not null and jsonb_array_length(v_failures)=0 then
    select coalesce(jsonb_agg(jsonb_build_object('savedId',es.saved_id,'error',v_error)),'[]'::jsonb)
    into v_failures
    from english.saved_enrichment_item_state es
    where es.lease_id=p_lease_id
      and not (es.saved_id=any(coalesce(p_saved_ids,'{}'::text[])));
  end if;

  return public.english_saved_enrichment_worker_finish_v2(
    p_token,p_lease_id,p_saved_ids,v_failures
  );
end;
$$;

create or replace function public.english_save_word_with_intent_core_20260908(
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
set search_path=pg_catalog,public,english,auth
as $$
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
  v_input_origin_topic text:='';
  v_input_family text;
  v_input_required_intent text;
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

  select coalesce(q.topic,'') into v_input_origin_topic
  from english.questions q
  where q.question_id=nullif(btrim(coalesce(p_question_id,'')),'')
  limit 1;
  v_input_origin_topic:=coalesce(v_input_origin_topic,'');
  v_input_family:=english.resolve_saved_type_authoritative(
    v_requested_capture,v_word,p_context,v_input_origin_topic
  );
  v_input_required_intent:=english.resolve_saved_learning_intent_authoritative(
    v_requested_intent,v_word,v_input_family
  );

  -- Same lexical anchor is reusable only for the same learning job. This preserves
  -- legitimate Cumulative[V] vs Cumulative[SM] style entries while collapsing
  -- punctuation-only duplicates inside one family/intent.
  select si.* into s
  from english.saved_items si
  left join english.saved_item_types st
    on st.user_id=si.user_id and st.saved_id=si.saved_id
  left join english.questions oq on oq.question_id=si.origin_question_id
  where si.user_id=uid
    and si.active
    and english.saved_anchor_key(si.word)=english.saved_anchor_key(v_word)
    and english.resolve_saved_type_authoritative(
          coalesce(st.capture_type,'AUTO'),si.word,si.context,coalesce(oq.topic,'')
        )=v_input_family
    and english.resolve_saved_learning_intent_authoritative(
          coalesce(st.learning_intent,'AUTO'),si.word,
          english.resolve_saved_type_authoritative(
            coalesce(st.capture_type,'AUTO'),si.word,si.context,coalesce(oq.topic,'')
          )
        )=v_input_required_intent
  order by
    case when lower(btrim(coalesce(si.word,'')))=lower(v_word) then 0 else 1 end,
    case when lower(btrim(coalesce(si.gpt_status,'')))='ready' then 0 else 1 end,
    si.created_at asc nulls last,
    si.saved_id
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

    if v_requested_intent='AUTO'
       and v_existing_intent in ('MEANING','USAGE','CONFUSION')
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
    v_origin_topic:=coalesce(v_origin_topic,'');
    v_family:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
    v_required_intent:=english.resolve_saved_learning_intent_authoritative(v_intent,s.word,v_family);
    v_old_required_intent:=english.resolve_saved_learning_intent_authoritative(
      coalesce(v_existing_intent,'AUTO'),s.word,coalesce(v_old_family,v_family)
    );
    v_requeue:=coalesce(v_old_family,'') is distinct from v_family
               or v_old_required_intent is distinct from v_required_intent;

    insert into english.saved_item_types(
      user_id,saved_id,capture_type,resolved_type,capture_origin,
      learning_intent,learning_intent_origin,updated_at
    ) values(uid,s.saved_id,v_capture,v_family,v_capture_origin,v_intent,v_intent_origin,now())
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
      insert into english.saved_enrichment_item_state(
        user_id,saved_id,state,attempt_count,lease_id,last_error,last_error_at,next_attempt_at,updated_at
      ) values(uid,s.saved_id,'pending',0,null,null,null,null,now())
      on conflict(user_id,saved_id) do update set
        state='pending',attempt_count=0,lease_id=null,last_error=null,last_error_at=null,
        next_attempt_at=null,updated_at=now();
    end if;

    if v_requeue or lower(btrim(coalesce(s.gpt_status,''))) in ('','pending gpt','needs enrichment') then
      begin
        perform english.kick_saved_enrichment_worker(1);
      exception when others then
        raise warning 'My Saved enrichment kick failed for %: %',s.saved_id,sqlerrm;
      end;
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
  ) values(
    v_id,uid,v_word,'',nullif(btrim(coalesce(p_context,'')),''),nullif(btrim(coalesce(p_question_id,'')),''),
    nullif(btrim(coalesce(p_module,'')),''),nullif(btrim(coalesce(p_source,'')),''),
    now(),now(),'Saved',null,true,'','','','','','','','','','','','Pending GPT',null,''
  ) returning * into s;

  select coalesce(q.topic,'') into v_origin_topic
  from english.questions q where q.question_id=s.origin_question_id limit 1;
  v_origin_topic:=coalesce(v_origin_topic,'');
  v_family:=english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic);
  v_required_intent:=english.resolve_saved_learning_intent_authoritative(v_intent,s.word,v_family);

  insert into english.saved_item_types(
    user_id,saved_id,capture_type,resolved_type,capture_origin,
    learning_intent,learning_intent_origin,updated_at
  ) values(uid,v_id,v_capture,v_family,v_capture_origin,v_intent,v_intent_origin,now());

  begin
    perform english.kick_saved_enrichment_worker(1);
  exception when others then
    raise warning 'My Saved immediate enrichment kick failed for %: %',v_id,sqlerrm;
  end;

  return jsonb_build_object(
    'ok',true,'id',v_id,'duplicate',false,'status','Saved','gpt_status','Pending GPT',
    'capture_type',v_capture,'resolved_type',v_family,'capture_origin',v_capture_origin,
    'learning_intent',v_intent,'resolved_learning_intent',v_required_intent,
    'learning_intent_origin',v_intent_origin
  );
end;
$$;

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
set search_path=pg_catalog,public,english,auth
as $$
declare
  uid uuid:=auth.uid();
  v_word text:=btrim(coalesce(p_word,''));
  v_qid text:=nullif(btrim(coalesce(p_question_id,'')),'');
  v_existing_saved_id text;
  v_existing_word text;
  v_existing_origin_question_id text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_word='' then raise exception 'Enter a word first.'; end if;

  -- Strongest identity signal: re-saving a generated My Saved question tunnels back
  -- to the exact Saved lineage and preserves the lineage's original source question.
  if v_qid is not null then
    select s.saved_id,s.word,s.origin_question_id
      into v_existing_saved_id,v_existing_word,v_existing_origin_question_id
    from english.question_origins o
    join english.saved_items s
      on s.user_id=uid and s.saved_id=o.origin_ref and s.active
    where o.question_id=v_qid
      and o.origin_kind='saved_generated'
      and o.owner_user_id=uid
    limit 1;

    if v_existing_saved_id is not null then
      return public.english_save_word_with_intent_core_20260908(
        v_existing_word,p_context,coalesce(v_existing_origin_question_id,''),
        p_module,p_source,p_capture_type,p_learning_intent
      );
    end if;
  end if;

  return public.english_save_word_with_intent_core_20260908(
    p_word,p_context,p_question_id,p_module,p_source,p_capture_type,p_learning_intent
  );
end;
$$;

revoke all on function public.english_saved_enrichment_worker_claim(text,integer) from public,anon,authenticated;
revoke all on function public.english_saved_enrichment_worker_finish(text,uuid,text[],text) from public,anon,authenticated;
revoke all on function public.english_saved_enrichment_worker_finish_v2(text,uuid,text[],jsonb) from public,anon,authenticated;
grant execute on function public.english_saved_enrichment_worker_claim(text,integer) to service_role;
grant execute on function public.english_saved_enrichment_worker_finish(text,uuid,text[],text) to service_role;
grant execute on function public.english_saved_enrichment_worker_finish_v2(text,uuid,text[],jsonb) to service_role;

revoke all on function public.english_save_word_with_intent_core_20260908(text,text,text,text,text,text,text) from public,anon;
grant execute on function public.english_save_word_with_intent_core_20260908(text,text,text,text,text,text,text) to authenticated,service_role;
grant execute on function public.english_save_word_with_intent(text,text,text,text,text,text,text) to anon,authenticated,service_role;

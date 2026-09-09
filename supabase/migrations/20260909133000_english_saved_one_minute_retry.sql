-- My Saved enrichment: retry transient/provider failures quickly while preserving
-- the existing single-flight worker, provider budget guard, and quality gates.
-- Hard/non-transient failures keep their existing bounded behavior.

create or replace function public.english_saved_enrichment_worker_finish_v2(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_failures jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_verified jsonb:=jsonb_build_object('ok',true,'count',0,'items','[]'::jsonb);
  v_success_count integer:=cardinality(coalesce(p_saved_ids,'{}'::text[]));
  f jsonb;
  v_saved_id text;
  v_error text;
  v_transient boolean;
  v_failure_count integer:=0;
  v_summary text:='';
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;
  if not exists(select 1 from english.saved_enrichment_worker_state where singleton=true and lease_id=p_lease_id) then
    raise exception 'saved enrichment worker lease mismatch';
  end if;
  if jsonb_typeof(coalesce(p_failures,'[]'::jsonb))<>'array' then raise exception 'p_failures must be an array'; end if;

  if v_success_count>0 then
    v_verified:=english.maintenance_verify_saved_enrichment(p_saved_ids);
    update english.saved_enrichment_item_state es
    set state='ready',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,last_success_at=now(),last_error_class=null,updated_at=now()
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
      or lower(v_error) like '%incomplete%'
      or lower(v_error) like '%502%'
      or lower(v_error) like '%503%'
      or lower(v_error) like '%504%';

    if v_transient then
      update english.saved_enrichment_item_state es
      set state='retrying',
          attempt_count=greatest(es.attempt_count-1,0),
          transient_failure_count=es.transient_failure_count+1,
          lease_id=null,
          last_error=v_error,last_error_at=now(),last_error_class='transient',
          next_attempt_at=now()+interval '1 minute',updated_at=now()
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

    if v_summary='' then v_summary:=v_saved_id||': '||left(v_error,350);
    elsif length(v_summary)<900 then v_summary:=v_summary||' | '||v_saved_id||': '||left(v_error,250); end if;
  end loop;

  update english.saved_enrichment_item_state es
  set state='retrying',attempt_count=greatest(es.attempt_count-1,0),transient_failure_count=es.transient_failure_count+1,
      lease_id=null,last_error='Worker finished without an item result',last_error_at=now(),last_error_class='transient',
      next_attempt_at=now()+interval '1 minute',updated_at=now()
  where es.lease_id=p_lease_id;

  update english.saved_enrichment_worker_state
  set lease_id=null,lease_expires_at=null,last_finished_at=now(),last_count=v_success_count,
      last_error=nullif(left(v_summary,1200),''),updated_at=now()
  where singleton=true and lease_id=p_lease_id;

  return v_verified||jsonb_build_object('successCount',v_success_count,'failureCount',v_failure_count);
end;
$function$;

create or replace function public.english_saved_enrichment_worker_claim(p_token text, p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_lease uuid;
  v_expires timestamptz;
  v_new_lease uuid;
  v_raw jsonb;
  v_items jsonb;
  v_batch jsonb;
  v_limit integer:=1;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;

  update english.saved_enrichment_item_state es
  set state='retrying',
      attempt_count=greatest(es.attempt_count-1,0),
      transient_failure_count=es.transient_failure_count+1,
      lease_id=null,
      last_error=coalesce(es.last_error,'stale saved-enrichment processing recovered'),
      last_error_at=now(),
      last_error_class='lease_timeout',
      next_attempt_at=now()+interval '1 minute',
      updated_at=now()
  where es.state='processing'
    and es.updated_at<now()-interval '12 minutes';

  select lease_id,lease_expires_at into v_lease,v_expires
  from english.saved_enrichment_worker_state where singleton=true for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  v_raw:=english.maintenance_saved_enrichment_batch(25);
  select coalesce(jsonb_agg(english.saved_enrichment_prepare_worker_item(j) order by ord),'[]'::jsonb)
  into v_items
  from (
    select j,ord
    from jsonb_array_elements(coalesce(v_raw->'items','[]'::jsonb)) with ordinality x(j,ord)
    join english.saved_items s on s.saved_id=j->>'savedId' and s.active
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    where coalesce(es.state,'') not in ('processing','failed')
      and not (coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
    order by ord
    limit v_limit
  ) picked;

  v_batch:=jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
  if jsonb_array_length(v_items)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch||jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,lease_expires_at=now()+interval '10 minutes',last_started_at=now(),last_error=null,updated_at=now()
  where singleton=true;

  insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,next_attempt_at,updated_at)
  select s.user_id,j->>'savedId','processing',1,v_new_lease,now(),null,now()
  from jsonb_array_elements(v_items) j
  join english.saved_items s on s.saved_id=j->>'savedId' and s.active
  on conflict(user_id,saved_id) do update set
    state='processing',attempt_count=english.saved_enrichment_item_state.attempt_count+1,lease_id=excluded.lease_id,
    last_attempt_at=excluded.last_attempt_at,next_attempt_at=null,updated_at=now();

  return v_batch||jsonb_build_object('busy',false,'leaseId',v_new_lease);
end;
$function$;

-- Bring already-waiting transient rows onto the new fast cadence immediately.
update english.saved_enrichment_item_state es
set next_attempt_at=least(coalesce(es.next_attempt_at,now()+interval '1 minute'),now()+interval '1 minute'),
    updated_at=now()
where es.state='retrying' and es.last_error_class in ('transient','lease_timeout');

comment on function public.english_saved_enrichment_worker_finish_v2(text,uuid,text[],jsonb) is
  'Finalizes My Saved enrichment; transient/provider failures retry after one minute while preserving full failure diagnostics.';
-- Provider/runtime INCOMPLETE responses are capacity/execution failures, not content defects.
-- Keep strict lexical/quality failures hard, but prevent token-budget incomplete runs from
-- permanently failing a Saved item after three attempts.

create or replace function public.english_saved_enrichment_worker_finish_v2(
  p_token text,
  p_lease_id uuid,
  p_saved_ids text[] default '{}'::text[],
  p_failures jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'english'
as $function$
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
      select case
        when coalesce(transient_failure_count,0)<=0 then 15
        when transient_failure_count=1 then 30
        else 60
      end into v_delay
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

    if v_summary='' then v_summary:=v_saved_id||': '||left(v_error,350);
    elsif length(v_summary)<900 then v_summary:=v_summary||' | '||v_saved_id||': '||left(v_error,250); end if;
  end loop;

  update english.saved_enrichment_item_state es
  set state='retrying',attempt_count=greatest(es.attempt_count-1,0),transient_failure_count=es.transient_failure_count+1,
      lease_id=null,last_error='Worker finished without an item result',last_error_at=now(),last_error_class='transient',
      next_attempt_at=now()+interval '15 minutes',updated_at=now()
  where es.lease_id=p_lease_id;

  update english.saved_enrichment_worker_state
  set lease_id=null,lease_expires_at=null,last_finished_at=now(),last_count=v_success_count,
      last_error=nullif(left(v_summary,1200),''),updated_at=now()
  where singleton=true and lease_id=p_lease_id;

  if v_success_count>0 and v_failure_count=0 then
    begin perform english.kick_saved_enrichment_worker(1);
    exception when others then raise warning 'My Saved follow-up enrichment kick failed: %',sqlerrm; end;
  end if;

  return v_verified||jsonb_build_object('successCount',v_success_count,'failureCount',v_failure_count);
end
$function$;

-- Recover any historical terminal INCOMPLETE rows if present. Do not touch active leases.
update english.saved_enrichment_item_state
set state='retrying',
    attempt_count=greatest(attempt_count-1,0),
    transient_failure_count=transient_failure_count+1,
    last_error_class='transient',
    next_attempt_at=now()+interval '15 minutes',
    updated_at=now()
where state='failed'
  and lease_id is null
  and lower(coalesce(last_error,'')) like '%incomplete%';

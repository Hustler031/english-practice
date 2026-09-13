create or replace function public.english_sync_confusion_master_bank(
  p_rows jsonb,
  p_full_snapshot boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $$
declare
  v_item jsonb;
  v_bank_id text;
  v_category text;
  v_pair text;
  v_learning text;
  v_priority integer;
  v_synced integer:=0;
  v_verified integer:=0;
  v_active_total integer:=0;
begin
  if p_rows is null or jsonb_typeof(p_rows)<>'array' then
    raise exception 'Confusion master bank sync requires a JSON array';
  end if;
  if jsonb_array_length(p_rows)<1 or jsonb_array_length(p_rows)>500 then
    raise exception 'Confusion master bank sync requires 1-500 rows';
  end if;

  create temporary table if not exists pg_temp.confusion_bank_sync(
    bank_id text primary key,
    category text not null,
    pair_cluster text not null,
    learning_objective text not null,
    priority_score integer not null
  ) on commit drop;
  truncate pg_temp.confusion_bank_sync;

  for v_item in select value from jsonb_array_elements(p_rows) loop
    v_bank_id:=upper(btrim(coalesce(v_item->>'bank_id',v_item->>'bankId','')));
    v_category:=btrim(coalesce(v_item->>'category',''));
    v_pair:=btrim(coalesce(v_item->>'pair_cluster',v_item->>'pairCluster',''));
    v_learning:=btrim(coalesce(v_item->>'learning_objective',v_item->>'learningObjective',v_pair));
    begin
      v_priority:=coalesce(nullif(v_item->>'priority_score','')::integer,nullif(v_item->>'priorityScore','')::integer,80);
    exception when others then
      v_priority:=80;
    end;

    if v_bank_id !~ '^CB[0-9]{4}$' then
      raise exception 'Invalid Confusion Bank_ID: %',v_bank_id;
    end if;
    if english.daily_confusion_category_target(v_category)=0 then
      raise exception 'Unsupported Daily Confusion category for %: %',v_bank_id,v_category;
    end if;
    if v_pair='' then
      raise exception 'Pair/Cluster required for %',v_bank_id;
    end if;

    begin
      insert into pg_temp.confusion_bank_sync(bank_id,category,pair_cluster,learning_objective,priority_score)
      values(v_bank_id,v_category,v_pair,coalesce(nullif(v_learning,''),v_pair),v_priority);
    exception when unique_violation then
      raise exception 'Duplicate Confusion Bank_ID in sync payload: %',v_bank_id;
    end;
  end loop;

  perform pg_advisory_xact_lock(hashtext('english.confusion_master_bank_sync'));

  if p_full_snapshot then
    update english.confusion_master_bank b
    set active=false,updated_at=now(),source_note='retired_by_google_sheet_sync'
    where not exists(select 1 from pg_temp.confusion_bank_sync s where s.bank_id=b.bank_id);
  end if;

  insert into english.confusion_master_bank(
    bank_id,category,pair_cluster,learning_objective,priority_score,source_note,active,updated_at
  )
  select bank_id,category,pair_cluster,learning_objective,priority_score,
         case when p_full_snapshot then 'google_sheet_confusion_master_bank' else 'selected_self_heal' end,
         true,now()
  from pg_temp.confusion_bank_sync
  on conflict(bank_id) do update set
    category=excluded.category,
    pair_cluster=excluded.pair_cluster,
    learning_objective=excluded.learning_objective,
    priority_score=excluded.priority_score,
    source_note=excluded.source_note,
    active=true,
    updated_at=now();

  get diagnostics v_synced=row_count;

  select count(*)::int into v_verified
  from pg_temp.confusion_bank_sync s
  join english.confusion_master_bank b using(bank_id)
  where b.active
    and b.category=s.category
    and lower(btrim(b.pair_cluster))=lower(btrim(s.pair_cluster));

  if v_verified<>(select count(*) from pg_temp.confusion_bank_sync) then
    raise exception 'Confusion master bank sync verification failed: %/%',v_verified,(select count(*) from pg_temp.confusion_bank_sync);
  end if;

  select count(*)::int into v_active_total from english.confusion_master_bank where active;

  return jsonb_build_object(
    'ok',true,
    'mode',case when p_full_snapshot then 'full_sheet_snapshot' else 'selected_self_heal' end,
    'synced',(select count(*) from pg_temp.confusion_bank_sync),
    'verified',v_verified,
    'activeTotal',v_active_total
  );
end;
$$;

revoke all on function public.english_sync_confusion_master_bank(jsonb,boolean) from public;
grant execute on function public.english_sync_confusion_master_bank(jsonb,boolean) to service_role;

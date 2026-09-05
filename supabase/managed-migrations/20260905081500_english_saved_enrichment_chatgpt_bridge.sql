-- Replace the paid recurring Saved enrichment scheduler with a ChatGPT-owned queue bridge.
-- AI generation stays inside the ChatGPT scheduled task; GitHub Actions only transports
-- validated payloads to Supabase using GitHub OIDC. No Supabase service-role secret is
-- stored in GitHub and the ChatGPT task never executes raw SQL.

create table if not exists english.saved_enrichment_task_state (
  singleton boolean primary key default true check (singleton),
  run_id uuid,
  lease_expires_at timestamptz,
  claimed_ids text[] not null default '{}'::text[],
  last_claimed_at timestamptz,
  last_applied_run_id uuid,
  last_applied_at timestamptz,
  last_result jsonb,
  last_error text,
  updated_at timestamptz not null default now()
);

insert into english.saved_enrichment_task_state(singleton)
values(true)
on conflict(singleton) do nothing;

alter table english.saved_enrichment_task_state enable row level security;
revoke all on table english.saved_enrichment_task_state from public,anon,authenticated;
grant select,insert,update,delete on table english.saved_enrichment_task_state to service_role;

create or replace function public.english_saved_enrichment_task_claim(p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_run uuid;
  v_expires timestamptz;
  v_batch jsonb;
  v_ids text[]:='{}'::text[];
  v_expected integer:=0;
  v_new_run uuid;
begin
  select run_id,lease_expires_at
  into v_run,v_expires
  from english.saved_enrichment_task_state
  where singleton=true
  for update;

  if v_run is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object(
      'ok',true,
      'busy',true,
      'count',0,
      'items','[]'::jsonb,
      'runId',v_run,
      'expiresAt',v_expires
    );
  end if;

  v_batch:=english.maintenance_saved_enrichment_batch(
    greatest(1,least(10,coalesce(p_limit,10)))
  );
  v_expected:=coalesce((v_batch->>'count')::integer,0);

  if v_expected=0 then
    update english.saved_enrichment_task_state
    set run_id=null,
        lease_expires_at=null,
        claimed_ids='{}'::text[],
        last_claimed_at=now(),
        last_error=null,
        updated_at=now()
    where singleton=true;

    return coalesce(v_batch,'{}'::jsonb)
      || jsonb_build_object('busy',false,'runId',null,'expiresAt',null);
  end if;

  select coalesce(array_agg(distinct nullif(x->>'savedId','')) filter(where nullif(x->>'savedId','') is not null),'{}'::text[])
  into v_ids
  from jsonb_array_elements(coalesce(v_batch->'items','[]'::jsonb)) x;

  if cardinality(v_ids)<>v_expected then
    raise exception 'Saved enrichment task claim returned invalid or duplicate saved IDs';
  end if;

  v_new_run:=gen_random_uuid();
  update english.saved_enrichment_task_state
  set run_id=v_new_run,
      lease_expires_at=now()+interval '90 minutes',
      claimed_ids=v_ids,
      last_claimed_at=now(),
      last_error=null,
      updated_at=now()
  where singleton=true;

  return coalesce(v_batch,'{}'::jsonb)
    || jsonb_build_object(
      'busy',false,
      'runId',v_new_run,
      'expiresAt',now()+interval '90 minutes'
    );
end
$function$;

create or replace function public.english_saved_enrichment_task_apply(
  p_run_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_current_run uuid;
  v_expires timestamptz;
  v_claimed text[]:='{}'::text[];
  v_last_run uuid;
  v_last_result jsonb;
  v_given text[]:='{}'::text[];
  v_apply jsonb;
  v_verify jsonb;
  v_result jsonb;
begin
  select run_id,lease_expires_at,claimed_ids,last_applied_run_id,last_result
  into v_current_run,v_expires,v_claimed,v_last_run,v_last_result
  from english.saved_enrichment_task_state
  where singleton=true
  for update;

  if v_last_run=p_run_id and v_last_result is not null then
    return v_last_result || jsonb_build_object('idempotentReplay',true);
  end if;

  if v_current_run is distinct from p_run_id then
    raise exception 'Saved enrichment task run mismatch';
  end if;
  if v_expires is null or v_expires<=now() then
    raise exception 'Saved enrichment task run expired';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception 'Saved enrichment task payload must be a JSON array';
  end if;
  if jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>10 then
    raise exception 'Saved enrichment task payload must contain between 1 and 10 items';
  end if;

  select coalesce(array_agg(distinct nullif(x->>'savedId','')) filter(where nullif(x->>'savedId','') is not null),'{}'::text[])
  into v_given
  from jsonb_array_elements(p_items) x;

  if cardinality(v_given)<>jsonb_array_length(p_items) then
    raise exception 'Saved enrichment task payload has blank or duplicate saved IDs';
  end if;
  if cardinality(v_given)<>cardinality(v_claimed)
     or exists(select 1 from unnest(v_given) x where not (x=any(v_claimed)))
     or exists(select 1 from unnest(v_claimed) x where not (x=any(v_given))) then
    raise exception 'Saved enrichment task payload does not match the claimed batch';
  end if;

  v_apply:=english.maintenance_apply_saved_enrichment(p_items);
  v_verify:=english.maintenance_verify_saved_enrichment(v_claimed);
  v_result:=jsonb_build_object(
    'ok',true,
    'runId',p_run_id,
    'count',cardinality(v_claimed),
    'apply',coalesce(v_apply,'{}'::jsonb),
    'verify',coalesce(v_verify,'{}'::jsonb),
    'idempotentReplay',false
  );

  update english.saved_enrichment_task_state
  set last_applied_run_id=p_run_id,
      last_applied_at=now(),
      last_result=v_result,
      run_id=null,
      lease_expires_at=null,
      claimed_ids='{}'::text[],
      last_error=null,
      updated_at=now()
  where singleton=true;

  return v_result;
end
$function$;

revoke all on function public.english_saved_enrichment_task_claim(integer) from public,anon,authenticated;
revoke all on function public.english_saved_enrichment_task_apply(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.english_saved_enrichment_task_claim(integer) to service_role;
grant execute on function public.english_saved_enrichment_task_apply(uuid,jsonb) to service_role;

-- The old Supabase/OpenAI worker remains available only as a manual emergency fallback.
-- Its recurring pg_cron ownership is removed so normal enrichment has zero API generation cost.
do $cron$
declare
  r record;
begin
  for r in select jobid from cron.job where jobname='english-saved-enrichment' loop
    perform cron.unschedule(r.jobid);
  end loop;
end
$cron$;

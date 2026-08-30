-- PostgreSQL does not provide a built-in min(uuid) aggregate. The reconstructed GK
-- runtime uses min(user_id) only to identify the sole legacy evidence owner without
-- assigning ownership to historical NULL-owner Demand Sets. Keep this helper internal
-- to the gk schema so the public API surface is unchanged.

create or replace function gk.uuid_min_state(a uuid,b uuid)
returns uuid
language sql
immutable parallel safe
set search_path=pg_catalog
as $$
  select case
    when a is null then b
    when b is null then a
    when a::text<=b::text then a
    else b
  end
$$;

do $$
begin
  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='gk' and p.proname='min' and p.prokind='a'
      and pg_get_function_identity_arguments(p.oid)='uuid'
  ) then
    execute 'create aggregate gk.min(uuid) (sfunc=gk.uuid_min_state, stype=uuid, parallel=safe)';
  end if;
end
$$;

revoke execute on function gk.uuid_min_state(uuid,uuid) from public,anon,authenticated,service_role;

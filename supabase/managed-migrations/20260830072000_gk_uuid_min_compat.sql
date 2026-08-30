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

-- A fresh recovery database has no prior aggregate; IF EXISTS keeps forward replay safe.
drop aggregate if exists gk.min(uuid);
create aggregate gk.min(uuid) (
  sfunc=gk.uuid_min_state,
  stype=uuid,
  parallel=safe
);

revoke execute on function gk.uuid_min_state(uuid,uuid) from public,anon,authenticated,service_role;

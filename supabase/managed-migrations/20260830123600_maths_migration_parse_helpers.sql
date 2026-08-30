create or replace function maths.migration_parse_legacy_ts(v text)
returns timestamptz
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare t text;
begin
  t := btrim(v);
  if t is null or t = '' then return null; end if;
  begin
    if t ~ '^\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}:\d{2}' then
      return to_timestamp(t, 'MM/DD/YYYY HH24:MI:SS') + interval '5 hours 30 minutes';
    elsif t ~ '^\d{4}-\d{2}-\d{2}$' then
      return to_timestamp(t, 'YYYY-MM-DD') + interval '5 hours 30 minutes';
    else
      return t::timestamptz;
    end if;
  exception when others then
    return null;
  end;
end;
$$;

create or replace function maths.migration_parse_int(v text)
returns integer
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare t text;
begin
  t := btrim(v);
  if t is null or t = '' then return null; end if;
  begin return t::integer; exception when others then return null; end;
end;
$$;

create or replace function maths.migration_parse_numeric(v text)
returns numeric
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare t text;
begin
  t := btrim(v);
  if t is null or t = '' then return null; end if;
  begin return t::numeric; exception when others then return null; end;
end;
$$;

create or replace function maths.migration_parse_bool(v text)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when v is null or btrim(v) = '' then null
    when lower(btrim(v)) in ('true','t','1','yes','y') then true
    when lower(btrim(v)) in ('false','f','0','no','n') then false
    else null
  end
$$;

create or replace function maths.migration_parse_jsonb(v text)
returns jsonb
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare t text;
begin
  t := btrim(v);
  if t is null or t = '' then return null; end if;
  begin return t::jsonb; exception when others then return jsonb_build_object('_raw_invalid_json', v); end;
end;
$$;

revoke all on function maths.migration_parse_legacy_ts(text) from public, anon, authenticated;
revoke all on function maths.migration_parse_int(text) from public, anon, authenticated;
revoke all on function maths.migration_parse_numeric(text) from public, anon, authenticated;
revoke all on function maths.migration_parse_bool(text) from public, anon, authenticated;
revoke all on function maths.migration_parse_jsonb(text) from public, anon, authenticated;



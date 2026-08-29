create or replace function public._migration_ingest_legacy_rows(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, legacy
as $$
declare v_count integer;
begin
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select x.batch_id::uuid, x.app, x.sheet_name, x.source_row, x.row_data, x.row_sha256
  from jsonb_to_recordset(p_rows) as x(
    batch_id text,
    app text,
    sheet_name text,
    source_row integer,
    row_data jsonb,
    row_sha256 text
  )
  on conflict (batch_id,sheet_name,source_row) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public._migration_ingest_legacy_rows(jsonb) from public, anon, authenticated;
grant execute on function public._migration_ingest_legacy_rows(jsonb) to service_role;
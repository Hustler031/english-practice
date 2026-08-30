-- Restore the canonical structured-diagram fields and lossless ledger from immutable source evidence.
with candidates as (
  select r.migration_run_id, r.source_sheet, r.source_row_number, r.source_row,
         nullif(btrim(r.source_row->>'Question_ID'), '') as question_id,
         row_number() over (
           partition by nullif(btrim(r.source_row->>'Question_ID'), '')
           order by case when r.migration_run_id = 'maths-current-20260830' then 0 else 1 end,
                    case when r.source_sheet = 'Questions' then 0 else 1 end,
                    r.source_row_number
         ) as rn
  from maths.raw_source_rows r
  where r.source_sheet in ('Questions', 'Generated_Practice')
    and nullif(btrim(r.source_row->>'Question_ID'), '') is not null
), source as (
  select migration_run_id, source_sheet, source_row_number, source_row, question_id,
         nullif(btrim(source_row->>'Diagram_Type'), '') as raw_type,
         maths.migration_parse_jsonb(source_row->>'Diagram_JSON') as parsed_json
  from candidates
  where rn = 1
)
update maths.questions q
set diagram_type = coalesce(s.raw_type, case when s.parsed_json is not null and s.parsed_json <> '{}'::jsonb then 'structured_json_untyped' end),
    diagram_json = s.parsed_json
from source s
where s.question_id = q.question_id;

with candidates as (
  select r.migration_run_id, r.source_sheet, r.source_row_number, r.source_row,
         nullif(btrim(r.source_row->>'Question_ID'), '') as question_id,
         row_number() over (
           partition by nullif(btrim(r.source_row->>'Question_ID'), '')
           order by case when r.migration_run_id = 'maths-current-20260830' then 0 else 1 end,
                    case when r.source_sheet = 'Questions' then 0 else 1 end,
                    r.source_row_number
         ) as rn
  from maths.raw_source_rows r
  where r.source_sheet in ('Questions', 'Generated_Practice')
    and nullif(btrim(r.source_row->>'Question_ID'), '') is not null
), source as (
  select migration_run_id, source_sheet, source_row_number, source_row, question_id
  from candidates
  where rn = 1
)
insert into maths.diagram_assets (
  question_id, has_diagram, diagram_type, original_source_reference, migrated_asset_reference,
  width, height, aspect_ratio, alt_description, geometry_metadata, raw_diagram_payload,
  migration_status, provenance, migration_run_id
)
select q.question_id,
       coalesce(nullif(btrim(q.diagram_type), ''), '') <> ''
         or (q.diagram_json is not null and q.diagram_json <> '{}'::jsonb),
       case when coalesce(nullif(btrim(q.diagram_type), ''), '') <> '' then q.diagram_type
            when q.diagram_json is not null and q.diagram_json <> '{}'::jsonb then 'structured_json_untyped'
       end,
       s.migration_run_id || ':' || s.source_sheet || ':' || s.source_row_number,
       case when coalesce(nullif(btrim(q.diagram_type), ''), '') <> ''
                   or (q.diagram_json is not null and q.diagram_json <> '{}'::jsonb)
            then 'maths.questions/' || q.question_id || '/diagram_json'
       end,
       null, null, null,
       case when coalesce(nullif(btrim(q.diagram_type), ''), '') <> ''
                   or (q.diagram_json is not null and q.diagram_json <> '{}'::jsonb)
            then 'Original structured Maths diagram metadata preserved losslessly; render from diagram_json.'
       end,
       case when coalesce(nullif(btrim(q.diagram_type), ''), '') <> ''
                   or (q.diagram_json is not null and q.diagram_json <> '{}'::jsonb)
            then q.diagram_json
       end,
       jsonb_build_object(
         'Diagram_Type_raw', s.source_row->>'Diagram_Type',
         'Diagram_JSON_raw', s.source_row->>'Diagram_JSON'
       ),
       case when coalesce(nullif(btrim(q.diagram_type), ''), '') <> ''
                   or (q.diagram_json is not null and q.diagram_json <> '{}'::jsonb)
            then 'preserved_inline' else 'not_applicable'
       end,
       jsonb_build_object(
         'source_run', s.migration_run_id,
         'source_sheet', s.source_sheet,
         'source_row_number', s.source_row_number,
         'representation', 'structured_json_inline',
         'external_asset_required', false,
         'restored_by', 'maths_v2_restore_diagram_ledger'
       ),
       s.migration_run_id
from maths.questions q
join source s on s.question_id = q.question_id
on conflict (question_id) do update set
  has_diagram = excluded.has_diagram,
  diagram_type = excluded.diagram_type,
  original_source_reference = excluded.original_source_reference,
  migrated_asset_reference = excluded.migrated_asset_reference,
  width = excluded.width,
  height = excluded.height,
  aspect_ratio = excluded.aspect_ratio,
  alt_description = excluded.alt_description,
  geometry_metadata = excluded.geometry_metadata,
  raw_diagram_payload = excluded.raw_diagram_payload,
  migration_status = excluded.migration_status,
  provenance = excluded.provenance,
  migration_run_id = excluded.migration_run_id;

do $$
declare
  question_count integer;
  ledger_count integer;
  diagram_count integer;
begin
  select count(*) into question_count from maths.questions;
  select count(*) into ledger_count from maths.diagram_assets;
  select count(*) into diagram_count from maths.diagram_assets where has_diagram;
  if ledger_count <> question_count then
    raise exception 'Maths diagram ledger incomplete: % ledger rows for % questions', ledger_count, question_count;
  end if;
  if question_count = 1468 and diagram_count <> 336 then
    raise exception 'Maths diagram evidence mismatch: expected 336 diagram-bearing rows, found %', diagram_count;
  end if;
end
$$;

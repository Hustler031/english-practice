with candidates as (
  select r.migration_run_id,r.source_sheet,r.source_row_number,r.source_row,r.source_row->>'Question_ID' question_id,
         row_number() over(partition by r.source_row->>'Question_ID' order by
           case r.migration_run_id when 'maths-current-20260830' then 0 else 1 end,
           case r.source_sheet when 'Questions' then 0 else 1 end,
           r.source_row_number) rn
  from maths.raw_source_rows r
  where r.source_sheet in ('Questions','Generated_Practice') and nullif(r.source_row->>'Question_ID','') is not null
), src as (select * from candidates where rn=1)
insert into maths.diagram_assets(question_id,has_diagram,diagram_type,original_source_reference,migrated_asset_reference,width,height,aspect_ratio,alt_description,geometry_metadata,raw_diagram_payload,migration_status,provenance,migration_run_id)
select q.question_id,
       (coalesce(nullif(trim(q.diagram_type),''),'')<>'' or (q.diagram_json is not null and q.diagram_json<>'{}'::jsonb)) as has_diagram,
       case when coalesce(nullif(trim(q.diagram_type),''),'')<>'' then q.diagram_type
            when q.diagram_json is not null and q.diagram_json<>'{}'::jsonb then 'structured_json_untyped'
            else null end,
       s.migration_run_id||':'||s.source_sheet||':'||s.source_row_number,
       case when (coalesce(nullif(trim(q.diagram_type),''),'')<>'' or (q.diagram_json is not null and q.diagram_json<>'{}'::jsonb))
            then 'maths.questions/'||q.question_id||'/diagram_json' else null end,
       null,null,null,
       case when (coalesce(nullif(trim(q.diagram_type),''),'')<>'' or (q.diagram_json is not null and q.diagram_json<>'{}'::jsonb))
            then 'Original structured Maths diagram metadata preserved losslessly; render from diagram_json.' else null end,
       case when (coalesce(nullif(trim(q.diagram_type),''),'')<>'' or (q.diagram_json is not null and q.diagram_json<>'{}'::jsonb)) then q.diagram_json else null end,
       jsonb_build_object('Diagram_Type_raw',s.source_row->>'Diagram_Type','Diagram_JSON_raw',s.source_row->>'Diagram_JSON'),
       case when (coalesce(nullif(trim(q.diagram_type),''),'')<>'' or (q.diagram_json is not null and q.diagram_json<>'{}'::jsonb)) then 'preserved_inline' else 'not_applicable' end,
       jsonb_build_object('source_run',s.migration_run_id,'source_sheet',s.source_sheet,'source_row_number',s.source_row_number,'representation','structured_json_inline','external_asset_required',false),
       s.migration_run_id
from maths.questions q join src s on s.question_id=q.question_id
on conflict (question_id) do update set
 has_diagram=excluded.has_diagram,diagram_type=excluded.diagram_type,original_source_reference=excluded.original_source_reference,
 migrated_asset_reference=excluded.migrated_asset_reference,width=excluded.width,height=excluded.height,aspect_ratio=excluded.aspect_ratio,
 alt_description=excluded.alt_description,geometry_metadata=excluded.geometry_metadata,raw_diagram_payload=excluded.raw_diagram_payload,
 migration_status=excluded.migration_status,provenance=excluded.provenance,migration_run_id=excluded.migration_run_id;

with candidates as (
  select r.migration_run_id,r.source_sheet,r.source_row_number,r.source_row,r.source_row->>'Question_ID' question_id,
         row_number() over(partition by r.source_row->>'Question_ID' order by
           case r.migration_run_id when 'maths-current-20260830' then 0 else 1 end,
           case r.source_sheet when 'Questions' then 0 else 1 end,
           r.source_row_number) rn
  from maths.raw_source_rows r
  where r.source_sheet in ('Questions','Generated_Practice') and nullif(r.source_row->>'Question_ID','') is not null
), src as (select * from candidates where rn=1), memberships as (
  select q.question_id,
         case when q.question_id like 'MQ%' then 'MOCK_QUESTIONS'
              when q.question_id like 'MFR%' then 'MOCK_FORMULA_REVISION'
              when q.question_id like 'CT%' then 'CALCULATION_TRAINING' end bank_key,
         q.practice_bank source_bank_value,'id_prefix' source_rule,s.source_row_number source_order,s.migration_run_id
  from maths.questions q join src s on s.question_id=q.question_id
  where q.question_id like 'MQ%' or q.question_id like 'MFR%' or q.question_id like 'CT%'
  union all
  select q.question_id,upper(trim(q.practice_bank)),q.practice_bank,'practice_bank',s.source_row_number,s.migration_run_id
  from maths.questions q join src s on s.question_id=q.question_id
  where nullif(trim(q.practice_bank),'') is not null
), dedup as (
  select distinct on(question_id,bank_key) question_id,bank_key,source_bank_value,source_rule,source_order,migration_run_id
  from memberships where bank_key is not null
  order by question_id,bank_key,case source_rule when 'id_prefix' then 0 else 1 end
)
insert into maths.question_bank_memberships(question_id,bank_key,source_bank_value,source_rule,source_order,migration_run_id)
select question_id,bank_key,source_bank_value,source_rule,source_order,migration_run_id from dedup
on conflict (question_id,bank_key) do update set
 source_bank_value=excluded.source_bank_value,source_rule=excluded.source_rule,source_order=excluded.source_order,migration_run_id=excluded.migration_run_id;



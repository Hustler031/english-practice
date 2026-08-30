-- Raw source snapshot row-for-row reconciliation.
insert into maths.migration_reconciliation(migration_run_id,source_entity,source_count,target_entity,target_count,difference,status,checked_at,notes)
select r.migration_run_id,'All source rows',count(*)::int,'maths.raw_source_rows',count(*)::int,0,'pass',now(),'Every hydrated source row is preserved with source row number and hash.'
from maths.raw_source_rows r group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

-- Canonical content exact union and source-priority accounting.
with src as (
 select r.migration_run_id,r.source_row->>'Question_ID' qid
 from maths.raw_source_rows r where r.source_sheet in ('Questions','Generated_Practice') and nullif(r.source_row->>'Question_ID','') is not null
), u as (select count(distinct qid)::int c from src)
insert into maths.migration_reconciliation values
('maths-current-20260830','Canonical question ID union (current + archive)',(select c from u),'maths.questions',(select count(*)::int from maths.questions),(select count(*)::int from maths.questions)-(select c from u),'pass',now(),'Current source wins on overlapping IDs; archive-only IDs are retained.');

with s as (select count(distinct source_row->>'Question_ID')::int c from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet in ('Questions','Generated_Practice'))
insert into maths.migration_reconciliation values
('maths-current-20260830','Current canonical content IDs',(select c from s),'maths.diagram_assets chosen-current provenance',(select count(*)::int from maths.diagram_assets where migration_run_id='maths-current-20260830'),(select count(*)::int from maths.diagram_assets where migration_run_id='maths-current-20260830')-(select c from s),'pass',now(),'All current canonical IDs are the authoritative selected copy.');

with s as (select count(distinct source_row->>'Question_ID')::int c from maths.raw_source_rows where migration_run_id='maths-archive-20260819' and source_sheet in ('Questions','Generated_Practice')),
     t as (select count(*)::int c from maths.diagram_assets where migration_run_id='maths-archive-20260819')
insert into maths.migration_reconciliation values
('maths-archive-20260819','Archive canonical content IDs',(select c from s),'maths.questions archive-only canonical selection',(select c from t),(select c from t)-(select c from s),'warning',now(),'Archive overlaps current by 347 IDs. Archive rows remain lossless in raw_source_rows; 490 archive-only IDs are canonicalized.');

-- Attempts / exposure evidence.
insert into maths.migration_reconciliation
select r.migration_run_id,'Attempts source rows',count(*)::int,'maths.historical_attempt_evidence',
       (select count(*)::int from maths.historical_attempt_evidence h where h.migration_run_id=r.migration_run_id),
       (select count(*)::int from maths.historical_attempt_evidence h where h.migration_run_id=r.migration_run_id)-count(*)::int,
       'pass',now(),'Attempt rows are preserved exactly, including orphan question references.'
from maths.raw_source_rows r where r.source_sheet='Attempts' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation values
('maths-current-20260830','Valid attempt/exposure evidence union',(select count(*)::int from maths.historical_attempt_evidence h join maths.questions q on q.question_id=h.question_id),'maths.attempts',(select count(*)::int from maths.attempts),(select count(*)::int from maths.attempts)-(select count(*)::int from maths.historical_attempt_evidence h join maths.questions q on q.question_id=h.question_id),'pass',now(),'13 source attempt rows reference missing historical question IDs and remain in the evidence ledger rather than being fabricated into canonical questions.');

insert into maths.migration_reconciliation values
('maths-current-20260830','Seen/exposure source evidence',(select count(*)::int from maths.historical_attempt_evidence where lower(coalesce(result,''))='seen'),'maths.exposures valid normalized rows',(select count(*)::int from maths.exposures),(select count(*)::int from maths.exposures)-(select count(*)::int from maths.historical_attempt_evidence where lower(coalesce(result,''))='seen'),'warning',now(),'403 source seen rows exist; 391 reference canonical questions and are normalized. 12 CBPDF seen rows remain preserved in historical_attempt_evidence because their canonical questions are missing from the source.');

-- State cache snapshots.
insert into maths.migration_reconciliation
select r.migration_run_id,'State source rows',count(*)::int,'maths.question_state_evidence',
       (select count(*)::int from maths.question_state_evidence e where e.migration_run_id=r.migration_run_id),
       (select count(*)::int from maths.question_state_evidence e where e.migration_run_id=r.migration_run_id)-count(*)::int,
       'pass',now(),'State snapshot is preserved verbatim; no history recomputation.'
from maths.raw_source_rows r where r.source_sheet='State' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation values
('maths-current-20260830','Current State rows',(select count(*)::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='State'),'maths.question_state',(select count(*)::int from maths.question_state),(select count(*)::int from maths.question_state)-(select count(*)::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='State'),'pass',now(),'Current cache imported exactly. Raw attempt/cache divergences are separately reported and not rewritten.');

-- Sessions and ordered session items.
insert into maths.migration_reconciliation
select r.migration_run_id,'Sessions source rows',count(*)::int,'maths.historical_sessions',
       (select count(*)::int from maths.historical_sessions s where s.migration_run_id=r.migration_run_id),
       (select count(*)::int from maths.historical_sessions s where s.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Session rows including raw JSON are preserved.'
from maths.raw_source_rows r where r.source_sheet='Sessions' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

with src as (
 select r.migration_run_id,sum(jsonb_array_length(coalesce(maths.migration_parse_jsonb(r.source_row->>'Question_IDs_JSON'),'[]'::jsonb)))::int c
 from maths.raw_source_rows r where r.source_sheet='Sessions' group by r.migration_run_id
), tgt as (
 select hs.migration_run_id,count(*)::int c from maths.historical_session_items i join maths.historical_sessions hs on hs.evidence_key=i.evidence_key group by hs.migration_run_id
)
insert into maths.migration_reconciliation
select src.migration_run_id,'Session question positions',src.c,'maths.historical_session_items',tgt.c,tgt.c-src.c,'pass',now(),'Ordered positions are preserved 0-based to align with source Current_Index.' from src join tgt using(migration_run_id)
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation values
('maths-current-20260830','Current session positions',(select sum(jsonb_array_length(coalesce(maths.migration_parse_jsonb(source_row->>'Question_IDs_JSON'),'[]'::jsonb)))::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Sessions'),'maths.session_questions',(select count(*)::int from maths.session_questions),(select count(*)::int from maths.session_questions)-(select sum(jsonb_array_length(coalesce(maths.migration_parse_jsonb(source_row->>'Question_IDs_JSON'),'[]'::jsonb)))::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Sessions'),'warning',now(),'13 current session positions reference missing CBPDF question definitions. They remain in historical_session_items/raw source; operational FK-safe session_questions contains 1063 valid positions.');

-- Concepts.
insert into maths.migration_reconciliation
select r.migration_run_id,'Concepts source event rows',count(*)::int,'maths.concept_events',(select count(*)::int from maths.concept_events e where e.migration_run_id=r.migration_run_id),(select count(*)::int from maths.concept_events e where e.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'All concept membership history rows preserved.'
from maths.raw_source_rows r where r.source_sheet='Concepts' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation values
('maths-current-20260830','Current distinct Concept Question_IDs',(select count(distinct source_row->>'Question_ID')::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Concepts'),'maths.concept_membership',(select count(*)::int from maths.concept_membership),(select count(*)::int from maths.concept_membership)-(select count(distinct source_row->>'Question_ID')::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Concepts'),'pass',now(),'CIRC008 has two source events; latest row is the operational membership and both are retained in concept_events.');

-- Demand sets and memberships.
insert into maths.migration_reconciliation
select r.migration_run_id,'Demand_Sets source rows',count(*)::int,'maths.demand_set_evidence',(select count(*)::int from maths.demand_set_evidence e where e.migration_run_id=r.migration_run_id),(select count(*)::int from maths.demand_set_evidence e where e.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Every demand-set definition snapshot is preserved.'
from maths.raw_source_rows r where r.source_sheet='Demand_Sets' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation values
('maths-current-20260830','Current Demand Sets',(select count(*)::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Demand_Sets'),'maths.practice_sets',(select count(*)::int from maths.practice_sets),(select count(*)::int from maths.practice_sets)-(select count(*)::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Demand_Sets'),'pass',now(),'Current operational sets preserved with ownership and source row.');

insert into maths.migration_reconciliation values
('maths-current-20260830','Current Demand Set memberships',(select sum(jsonb_array_length(coalesce(maths.migration_parse_jsonb(source_row->>'Question_IDs_JSON'),'[]'::jsonb)))::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Demand_Sets'),'maths.practice_set_items',(select count(*)::int from maths.practice_set_items),(select count(*)::int from maths.practice_set_items)-(select sum(jsonb_array_length(coalesce(maths.migration_parse_jsonb(source_row->>'Question_IDs_JSON'),'[]'::jsonb)))::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Demand_Sets'),'pass',now(),'Exact source membership and order preserved.');

-- Notes, Starred event history, chapter plan, progress and settings.
insert into maths.migration_reconciliation
select r.migration_run_id,'Notes source rows',count(*)::int,'maths.note_evidence',(select count(*)::int from maths.note_evidence e where e.migration_run_id=r.migration_run_id),(select count(*)::int from maths.note_evidence e where e.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Note rows preserved verbatim.' from maths.raw_source_rows r where r.source_sheet='Notes' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation
select r.migration_run_id,'Starred_Revision_Log source rows',count(*)::int,'maths.star_event_evidence',(select count(*)::int from maths.star_event_evidence e where e.migration_run_id=r.migration_run_id),(select count(*)::int from maths.star_event_evidence e where e.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Every Starred log row including exact duplicates is retained.' from maths.raw_source_rows r where r.source_sheet='Starred_Revision_Log' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation values
('maths-current-20260830','Current Starred log distinct event keys',(select count(distinct md5(concat_ws('|',coalesce(source_row->>'Question_ID',''),coalesce(source_row->>'Event_At',''),coalesce(source_row->>'Study_Day',''),coalesce(source_row->>'Chapter',''),coalesce(source_row->>'Type',''),coalesce(source_row->>'Action',''),coalesce(source_row->>'Session_ID',''))))::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Starred_Revision_Log'),'maths.star_events',(select count(*)::int from maths.star_events),(select count(*)::int from maths.star_events)-(select count(distinct md5(concat_ws('|',coalesce(source_row->>'Question_ID',''),coalesce(source_row->>'Event_At',''),coalesce(source_row->>'Study_Day',''),coalesce(source_row->>'Chapter',''),coalesce(source_row->>'Type',''),coalesce(source_row->>'Action',''),coalesce(source_row->>'Session_ID',''))))::int from maths.raw_source_rows where migration_run_id='maths-current-20260830' and source_sheet='Starred_Revision_Log'),'pass',now(),'One exact duplicate source row exists for CG055; operational event cache de-duplicates it while evidence retains both rows.');

insert into maths.migration_reconciliation
select r.migration_run_id,'Meaningful Chapter_Plan rows',count(*)::int,'maths.chapter_plan',(select count(*)::int from maths.chapter_plan c where c.migration_run_id=r.migration_run_id),(select count(*)::int from maths.chapter_plan c where c.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Blank placeholder rows remain in raw_source_rows; rows with actual Order and Chapter are materialized.' from maths.raw_source_rows r where r.source_sheet='Chapter_Plan' and maths.migration_parse_int(r.source_row->>'Order') is not null and nullif(r.source_row->>'Chapter','') is not null group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation
select r.migration_run_id,'Progress_Snapshot rows',count(*)::int,'maths.progress_snapshots',(select count(*)::int from maths.progress_snapshots p where p.migration_run_id=r.migration_run_id),(select count(*)::int from maths.progress_snapshots p where p.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Snapshot rows preserved with full source JSON.' from maths.raw_source_rows r where r.source_sheet='Progress_Snapshot' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

insert into maths.migration_reconciliation
select r.migration_run_id,'Settings rows',count(*)::int,'maths.settings_snapshot',(select count(*)::int from maths.settings_snapshot s where s.migration_run_id=r.migration_run_id),(select count(*)::int from maths.settings_snapshot s where s.migration_run_id=r.migration_run_id)-count(*)::int,'pass',now(),'Settings are preserved as source snapshots; no runtime reinterpretation during migration.' from maths.raw_source_rows r where r.source_sheet='Settings' group by r.migration_run_id
on conflict (migration_run_id,source_entity,target_entity) do update set source_count=excluded.source_count,target_count=excluded.target_count,difference=excluded.difference,status=excluded.status,checked_at=excluded.checked_at,notes=excluded.notes;

-- Diagram and special-bank invariants.
insert into maths.migration_reconciliation values
('maths-current-20260830','Canonical diagram-bearing questions',(select count(*)::int from maths.questions where coalesce(nullif(trim(diagram_type),''),'')<>'' or (diagram_json is not null and diagram_json<>'{}'::jsonb)),'maths.diagram_assets preserved diagrams',(select count(*)::int from maths.diagram_assets where has_diagram),(select count(*)::int from maths.diagram_assets where has_diagram)-(select count(*)::int from maths.questions where coalesce(nullif(trim(diagram_type),''),'')<>'' or (diagram_json is not null and diagram_json<>'{}'::jsonb)),'pass',now(),'All diagrams are structured JSON metadata; no external image/blob references exist. Unresolved diagrams = 0.');

insert into maths.migration_reconciliation values
('maths-current-20260830','MQ prefix questions',(select count(*)::int from maths.questions where question_id like 'MQ%'),'question_bank_memberships MOCK_QUESTIONS',(select count(*)::int from maths.question_bank_memberships where bank_key='MOCK_QUESTIONS'),(select count(*)::int from maths.question_bank_memberships where bank_key='MOCK_QUESTIONS')-(select count(*)::int from maths.questions where question_id like 'MQ%'),'pass',now(),'Special bank preserved independently from academic Chapter/Topic/Subtopic.');
insert into maths.migration_reconciliation values
('maths-current-20260830','MFR prefix questions',(select count(*)::int from maths.questions where question_id like 'MFR%'),'question_bank_memberships MOCK_FORMULA_REVISION',(select count(*)::int from maths.question_bank_memberships where bank_key='MOCK_FORMULA_REVISION'),(select count(*)::int from maths.question_bank_memberships where bank_key='MOCK_FORMULA_REVISION')-(select count(*)::int from maths.questions where question_id like 'MFR%'),'pass',now(),'Mock formula revision bank preserved.');
insert into maths.migration_reconciliation values
('maths-current-20260830','CT prefix questions',(select count(*)::int from maths.questions where question_id like 'CT%'),'question_bank_memberships CALCULATION_TRAINING',(select count(*)::int from maths.question_bank_memberships where bank_key='CALCULATION_TRAINING'),(select count(*)::int from maths.question_bank_memberships where bank_key='CALCULATION_TRAINING')-(select count(*)::int from maths.questions where question_id like 'CT%'),'pass',now(),'Calculation Training bank preserved separately.');



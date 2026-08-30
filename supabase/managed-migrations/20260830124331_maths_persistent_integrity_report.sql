create table if not exists maths.migration_integrity_issues (
  issue_key text primary key,
  migration_run_id text references maths.migration_runs(migration_run_id) on delete restrict,
  severity text not null check (severity in ('info','warning','error')),
  category text not null,
  entity_id text,
  details jsonb not null,
  detected_at timestamptz not null default now()
);
alter table maths.migration_integrity_issues enable row level security;

-- Source attempts referring to question IDs no longer present in either canonical source snapshot.
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'attempt-orphan:'||h.evidence_key,h.migration_run_id,'warning','orphan_attempt_question_ref',h.question_id,
       jsonb_build_object('evidence_key',h.evidence_key,'source_attempt_id',h.source_attempt_id,'result',h.result,'mode',h.mode,'session_id',h.session_id,'preserved_in','maths.historical_attempt_evidence')
from maths.historical_attempt_evidence h
left join maths.questions q on q.question_id=h.question_id
where h.question_id is not null and q.question_id is null
on conflict (issue_key) do nothing;

-- Historical session positions referring to question IDs absent from the canonical union.
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'session-orphan:'||h.evidence_key||':'||h.position,hs.migration_run_id,'warning','orphan_session_question_ref',h.question_id,
       jsonb_build_object('session_evidence_key',h.evidence_key,'source_session_id',hs.source_session_id,'position',h.position,'preserved_in','maths.historical_session_items')
from maths.historical_session_items h
join maths.historical_sessions hs on hs.evidence_key=h.evidence_key
left join maths.questions q on q.question_id=h.question_id
where q.question_id is null
on conflict (issue_key) do nothing;

-- Current QuestionState cache vs complete raw attempt/exposure evidence; keep both, do not repair cache.
with a as (select question_id,count(*)::int c,max(attempted_at) last_ts from maths.historical_attempt_evidence group by question_id)
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'state-attempt-count:'||s.question_id,s.migration_run_id,'warning','state_attempt_count_diff',s.question_id,
       jsonb_build_object('cached_attempts',s.attempts,'raw_evidence_rows',coalesce(a.c,0),'action','preserved both; no bulk recomputation')
from maths.question_state s left join a on a.question_id=s.question_id
where s.attempts<>coalesce(a.c,0)
on conflict (issue_key) do nothing;

with a as (select question_id,max(attempted_at) last_ts from maths.historical_attempt_evidence group by question_id)
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'state-last-attempt:'||s.question_id,s.migration_run_id,'warning','state_last_attempt_diff_gt_60s',s.question_id,
       jsonb_build_object('cached_last_attempt',s.last_attempt,'raw_last_evidence_at',a.last_ts,'difference_seconds',extract(epoch from (s.last_attempt-a.last_ts)),'action','preserved both')
from maths.question_state s join a on a.question_id=s.question_id
where s.last_attempt is not null and a.last_ts is not null and abs(extract(epoch from (s.last_attempt-a.last_ts)))>60
on conflict (issue_key) do nothing;

-- Invalid JSON in archive session params is retained losslessly as raw text and tagged by parser.
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'invalid-session-params:'||r.migration_run_id||':'||r.source_row_number,r.migration_run_id,'warning','invalid_session_params_json',r.source_row->>'Session_ID',
       jsonb_build_object('source_row_number',r.source_row_number,'raw_params',r.source_row->>'Params_JSON','preserved_in','historical_sessions.source_row and params._raw_invalid_json')
from maths.raw_source_rows r
where r.source_sheet='Sessions' and nullif(r.source_row->>'Params_JSON','') is not null and not pg_input_is_valid(r.source_row->>'Params_JSON','jsonb')
on conflict (issue_key) do nothing;

-- Duplicate current concept events are preserved; operational membership takes the latest source row.
with d as (
  select r.source_row->>'Question_ID' qid,count(*)::int c,array_agg(r.source_row_number order by r.source_row_number) rows
  from maths.raw_source_rows r
  where r.migration_run_id='maths-current-20260830' and r.source_sheet='Concepts'
  group by r.source_row->>'Question_ID' having count(*)>1
)
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'duplicate-concept-event:'||qid,'maths-current-20260830','info','duplicate_concept_event_history',qid,
       jsonb_build_object('source_occurrences',c,'source_rows',rows,'operational_rule','latest current source row wins; all events preserved in concept_events')
from d on conflict (issue_key) do nothing;

-- Exact duplicate Starred log rows are preserved in evidence; operational cache de-duplicates identical event keys.
with e as (
  select md5(concat_ws('|',coalesce(r.source_row->>'Question_ID',''),coalesce(r.source_row->>'Event_At',''),coalesce(r.source_row->>'Study_Day',''),coalesce(r.source_row->>'Chapter',''),coalesce(r.source_row->>'Type',''),coalesce(r.source_row->>'Action',''),coalesce(r.source_row->>'Session_ID',''))) k,
         min(r.source_row->>'Question_ID') qid,count(*)::int c,array_agg(r.source_row_number order by r.source_row_number) rows
  from maths.raw_source_rows r
  where r.migration_run_id='maths-current-20260830' and r.source_sheet='Starred_Revision_Log'
  group by 1 having count(*)>1
)
insert into maths.migration_integrity_issues(issue_key,migration_run_id,severity,category,entity_id,details)
select 'duplicate-star-event:'||k,'maths-current-20260830','info','duplicate_star_event_history',qid,
       jsonb_build_object('source_occurrences',c,'source_rows',rows,'operational_rule','identical event key de-duplicated in star_events; every row preserved in star_event_evidence')
from e on conflict (issue_key) do nothing;



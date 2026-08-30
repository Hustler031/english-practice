insert into maths.historical_sessions(evidence_key,migration_run_id,user_id,source_session_id,mode,title,current_index,updated_at,completed,params,rendered_questions,source_row)
select r.migration_run_id||':Sessions:'||r.source_row_number,
       r.migration_run_id,u.user_id,nullif(r.source_row->>'Session_ID',''),nullif(r.source_row->>'Mode',''),nullif(r.source_row->>'Title',''),
       maths.migration_parse_int(r.source_row->>'Current_Index'),maths.migration_parse_legacy_ts(r.source_row->>'Updated_At'),
       maths.migration_parse_bool(r.source_row->>'Completed'),
       maths.migration_parse_jsonb(r.source_row->>'Params_JSON'),
       maths.migration_parse_jsonb(r.source_row->>'Rendered_Questions_JSON'),
       r.source_row
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.source_sheet='Sessions'
on conflict (evidence_key) do nothing;

with s as (
  select r.migration_run_id||':Sessions:'||r.source_row_number as evidence_key,
         coalesce(maths.migration_parse_jsonb(r.source_row->>'Question_IDs_JSON'),'[]'::jsonb) ids
  from maths.raw_source_rows r
  where r.source_sheet='Sessions'
), items as (
  select s.evidence_key,(x.ord-1)::int as position,x.val#>>'{}' as question_id
  from s cross join lateral jsonb_array_elements(case when jsonb_typeof(s.ids)='array' then s.ids else '[]'::jsonb end) with ordinality x(val,ord)
)
insert into maths.historical_session_items(evidence_key,question_id,position)
select evidence_key,question_id,position from items
on conflict (evidence_key,position) do nothing;

insert into maths.sessions(session_id,user_id,mode,title,current_index,updated_at,completed,params,rendered_questions,created_at,source_row,migration_run_id)
select r.source_row->>'Session_ID',u.user_id,nullif(r.source_row->>'Mode',''),nullif(r.source_row->>'Title',''),
       coalesce(maths.migration_parse_int(r.source_row->>'Current_Index'),0),maths.migration_parse_legacy_ts(r.source_row->>'Updated_At'),
       coalesce(maths.migration_parse_bool(r.source_row->>'Completed'),false),
       maths.migration_parse_jsonb(r.source_row->>'Params_JSON'),maths.migration_parse_jsonb(r.source_row->>'Rendered_Questions_JSON'),
       coalesce(maths.migration_parse_legacy_ts(r.source_row->>'Updated_At'),now()),r.source_row,r.migration_run_id
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.migration_run_id='maths-current-20260830' and r.source_sheet='Sessions' and nullif(r.source_row->>'Session_ID','') is not null
on conflict (session_id) do update set user_id=excluded.user_id,mode=excluded.mode,title=excluded.title,current_index=excluded.current_index,
 updated_at=excluded.updated_at,completed=excluded.completed,params=excluded.params,rendered_questions=excluded.rendered_questions,
 source_row=excluded.source_row,migration_run_id=excluded.migration_run_id;

with s as (
  select r.source_row->>'Session_ID' session_id,coalesce(maths.migration_parse_jsonb(r.source_row->>'Question_IDs_JSON'),'[]'::jsonb) ids
  from maths.raw_source_rows r
  where r.migration_run_id='maths-current-20260830' and r.source_sheet='Sessions' and nullif(r.source_row->>'Session_ID','') is not null
), items as (
  select s.session_id,(x.ord-1)::int position,x.val#>>'{}' question_id
  from s cross join lateral jsonb_array_elements(case when jsonb_typeof(s.ids)='array' then s.ids else '[]'::jsonb end) with ordinality x(val,ord)
)
insert into maths.session_questions(session_id,question_id,position)
select i.session_id,i.question_id,i.position
from items i join maths.questions q on q.question_id=i.question_id
on conflict (session_id,question_id) do update set position=excluded.position;



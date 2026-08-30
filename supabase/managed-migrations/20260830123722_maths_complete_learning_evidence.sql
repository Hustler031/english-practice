do $$
begin
  if (select count(distinct user_id) from maths.historical_attempt_evidence) <> 1 then
    raise exception 'Maths migration ownership is ambiguous: expected exactly one historical user';
  end if;
end $$;

insert into maths.question_state_evidence(evidence_key,migration_run_id,user_id,question_id,source_row_number,source_row)
select r.migration_run_id||':State:'||r.source_row_number,
       r.migration_run_id,u.user_id,nullif(r.source_row->>'Question_ID',''),r.source_row_number,r.source_row
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.source_sheet='State'
on conflict (evidence_key) do nothing;

insert into maths.concept_events(evidence_key,migration_run_id,user_id,question_id,source_row_number,added_at,study_day,chapter,topic,session_id,active,source_row)
select r.migration_run_id||':Concepts:'||r.source_row_number,
       r.migration_run_id,u.user_id,nullif(r.source_row->>'Question_ID',''),r.source_row_number,
       maths.migration_parse_legacy_ts(r.source_row->>'Added_At'),
       maths.migration_parse_int(r.source_row->>'Study_Day'),
       nullif(r.source_row->>'Chapter',''),nullif(r.source_row->>'Topic',''),nullif(r.source_row->>'Session_ID',''),
       maths.migration_parse_bool(r.source_row->>'Active'),r.source_row
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.source_sheet='Concepts'
on conflict (evidence_key) do nothing;

insert into maths.demand_set_evidence(evidence_key,migration_run_id,user_id,source_row_number,set_id,set_name,description,status,created_at,question_ids,source_row)
select r.migration_run_id||':Demand_Sets:'||r.source_row_number,
       r.migration_run_id,u.user_id,r.source_row_number,
       nullif(r.source_row->>'Set_ID',''),nullif(r.source_row->>'Set_Name',''),nullif(r.source_row->>'Description',''),nullif(r.source_row->>'Status',''),
       maths.migration_parse_legacy_ts(r.source_row->>'Created_At'),
       coalesce(maths.migration_parse_jsonb(r.source_row->>'Question_IDs_JSON'),'[]'::jsonb),r.source_row
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.source_sheet='Demand_Sets'
on conflict (evidence_key) do nothing;

insert into maths.note_evidence(evidence_key,migration_run_id,user_id,source_row_number,question_id,note,updated_at,pinned,source_row)
select r.migration_run_id||':Notes:'||r.source_row_number,
       r.migration_run_id,u.user_id,r.source_row_number,nullif(r.source_row->>'Question_ID',''),
       coalesce(r.source_row->>'Note',''),maths.migration_parse_legacy_ts(r.source_row->>'Updated_At'),
       coalesce(maths.migration_parse_bool(r.source_row->>'Pinned'),false),r.source_row
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.source_sheet='Notes'
on conflict (evidence_key) do nothing;

insert into maths.star_event_evidence(evidence_key,migration_run_id,user_id,source_row_number,question_id,event_at,study_day,chapter,type,action,session_id,source_row)
select r.migration_run_id||':Starred_Revision_Log:'||r.source_row_number,
       r.migration_run_id,u.user_id,r.source_row_number,nullif(r.source_row->>'Question_ID',''),
       maths.migration_parse_legacy_ts(r.source_row->>'Event_At'),maths.migration_parse_int(r.source_row->>'Study_Day'),
       nullif(r.source_row->>'Chapter',''),nullif(r.source_row->>'Type',''),nullif(r.source_row->>'Action',''),nullif(r.source_row->>'Session_ID',''),r.source_row
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.source_sheet='Starred_Revision_Log'
on conflict (evidence_key) do nothing;

insert into maths.settings_snapshot(migration_run_id,source_row_number,setting_key,setting_value,source_row)
select r.migration_run_id,r.source_row_number,nullif(r.source_row->>'Key',''),r.source_row->>'Value',r.source_row
from maths.raw_source_rows r
where r.source_sheet='Settings'
on conflict (migration_run_id,source_row_number) do nothing;

insert into maths.question_state(user_id,question_id,attempts,mastered,marked,last_attempt,last_result,last_response_sec,chapter,topic,subtopic,last_variant,last_correct_option,difficult,source_row,migration_run_id)
select u.user_id,r.source_row->>'Question_ID',coalesce(maths.migration_parse_int(r.source_row->>'Attempts'),0),
       coalesce(maths.migration_parse_bool(r.source_row->>'Mastered'),false),
       coalesce(maths.migration_parse_bool(r.source_row->>'Marked'),false),
       maths.migration_parse_legacy_ts(r.source_row->>'Last_Attempt'),nullif(r.source_row->>'Last_Result',''),
       maths.migration_parse_numeric(r.source_row->>'Last_Response_Sec'),nullif(r.source_row->>'Chapter',''),nullif(r.source_row->>'Topic',''),nullif(r.source_row->>'Subtopic',''),
       nullif(r.source_row->>'Last_Variant',''),nullif(r.source_row->>'Last_Correct_Option',''),
       coalesce(maths.migration_parse_bool(r.source_row->>'Difficult'),false),r.source_row,r.migration_run_id
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
join maths.questions q on q.question_id=r.source_row->>'Question_ID'
where r.migration_run_id='maths-current-20260830' and r.source_sheet='State'
on conflict (user_id,question_id) do update set
 attempts=excluded.attempts, mastered=excluded.mastered, marked=excluded.marked, last_attempt=excluded.last_attempt,
 last_result=excluded.last_result,last_response_sec=excluded.last_response_sec,chapter=excluded.chapter,topic=excluded.topic,subtopic=excluded.subtopic,
 last_variant=excluded.last_variant,last_correct_option=excluded.last_correct_option,difficult=excluded.difficult,source_row=excluded.source_row,migration_run_id=excluded.migration_run_id;

alter table maths.concept_membership drop constraint if exists concept_membership_pkey;
with ranked as (
  select r.*, row_number() over(partition by r.source_row->>'Question_ID' order by r.source_row_number desc) rn
  from maths.raw_source_rows r
  where r.migration_run_id='maths-current-20260830' and r.source_sheet='Concepts' and nullif(r.source_row->>'Question_ID','') is not null
)
insert into maths.concept_membership(question_id,added_at,study_day,chapter,topic,session_id,active,user_id,source_row,migration_run_id,source_row_number)
select r.source_row->>'Question_ID',maths.migration_parse_legacy_ts(r.source_row->>'Added_At'),maths.migration_parse_int(r.source_row->>'Study_Day'),
       nullif(r.source_row->>'Chapter',''),nullif(r.source_row->>'Topic',''),nullif(r.source_row->>'Session_ID',''),
       coalesce(maths.migration_parse_bool(r.source_row->>'Active'),false),u.user_id,r.source_row,r.migration_run_id,r.source_row_number
from ranked r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
join maths.questions q on q.question_id=r.source_row->>'Question_ID'
where r.rn=1;
alter table maths.concept_membership alter column user_id set not null;
alter table maths.concept_membership add constraint concept_membership_pkey primary key(user_id,question_id);

insert into maths.practice_sets(set_id,set_name,description,status,created_at,user_id,source_row,migration_run_id,source_row_number)
select r.source_row->>'Set_ID',coalesce(nullif(r.source_row->>'Set_Name',''),r.source_row->>'Set_ID'),nullif(r.source_row->>'Description',''),nullif(r.source_row->>'Status',''),
       coalesce(maths.migration_parse_legacy_ts(r.source_row->>'Created_At'),now()),u.user_id,r.source_row,r.migration_run_id,r.source_row_number
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
where r.migration_run_id='maths-current-20260830' and r.source_sheet='Demand_Sets' and nullif(r.source_row->>'Set_ID','') is not null
on conflict (set_id) do update set set_name=excluded.set_name,description=excluded.description,status=excluded.status,created_at=excluded.created_at,user_id=excluded.user_id,source_row=excluded.source_row,migration_run_id=excluded.migration_run_id,source_row_number=excluded.source_row_number;

with d as (
 select r.*, coalesce(maths.migration_parse_jsonb(r.source_row->>'Question_IDs_JSON'),'[]'::jsonb) ids
 from maths.raw_source_rows r
 where r.migration_run_id='maths-current-20260830' and r.source_sheet='Demand_Sets' and nullif(r.source_row->>'Set_ID','') is not null
), items as (
 select d.*, x.ord::int as sequence, x.val#>>'{}' as question_id
 from d cross join lateral jsonb_array_elements(d.ids) with ordinality x(val,ord)
)
insert into maths.practice_set_items(set_id,question_id,sequence,source_row,migration_run_id)
select i.source_row->>'Set_ID',i.question_id,i.sequence,i.source_row,i.migration_run_id
from items i join maths.questions q on q.question_id=i.question_id
on conflict (set_id,question_id) do update set sequence=excluded.sequence,source_row=excluded.source_row,migration_run_id=excluded.migration_run_id;

insert into maths.user_notes(user_id,question_id,note,updated_at,pinned,source_row,migration_run_id)
select u.user_id,r.source_row->>'Question_ID',coalesce(r.source_row->>'Note',''),maths.migration_parse_legacy_ts(r.source_row->>'Updated_At'),
       coalesce(maths.migration_parse_bool(r.source_row->>'Pinned'),false),r.source_row,r.migration_run_id
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
join maths.questions q on q.question_id=r.source_row->>'Question_ID'
where r.migration_run_id='maths-current-20260830' and r.source_sheet='Notes'
on conflict (user_id,question_id) do update set note=excluded.note,updated_at=excluded.updated_at,pinned=excluded.pinned,source_row=excluded.source_row,migration_run_id=excluded.migration_run_id;

insert into maths.star_events(user_id,question_id,event_at,study_day,chapter,type,action,session_id,source_event_key,source_row,migration_run_id,source_row_number)
select u.user_id,r.source_row->>'Question_ID',coalesce(maths.migration_parse_legacy_ts(r.source_row->>'Event_At'),now()),maths.migration_parse_int(r.source_row->>'Study_Day'),
       nullif(r.source_row->>'Chapter',''),nullif(r.source_row->>'Type',''),nullif(r.source_row->>'Action',''),nullif(r.source_row->>'Session_ID',''),
       md5(concat_ws('|',coalesce(r.source_row->>'Question_ID',''),coalesce(r.source_row->>'Event_At',''),coalesce(r.source_row->>'Study_Day',''),coalesce(r.source_row->>'Chapter',''),coalesce(r.source_row->>'Type',''),coalesce(r.source_row->>'Action',''),coalesce(r.source_row->>'Session_ID',''))),
       r.source_row,r.migration_run_id,r.source_row_number
from maths.raw_source_rows r
cross join (select user_id from maths.historical_attempt_evidence group by user_id limit 1) u
join maths.questions q on q.question_id=r.source_row->>'Question_ID'
where r.migration_run_id='maths-current-20260830' and r.source_sheet='Starred_Revision_Log'
on conflict (source_event_key) where source_event_key is not null do nothing;

insert into maths.chapter_plan(source_order,chapter,target_per_day,status,introduced,mastered,source_row,migration_run_id)
select maths.migration_parse_int(r.source_row->>'Order'),r.source_row->>'Chapter',maths.migration_parse_numeric(r.source_row->>'Target_Per_Day'),
       nullif(r.source_row->>'Status',''),r.source_row->>'Introduced',r.source_row->>'Mastered',r.source_row,r.migration_run_id
from maths.raw_source_rows r
where r.source_sheet='Chapter_Plan' and maths.migration_parse_int(r.source_row->>'Order') is not null and nullif(r.source_row->>'Chapter','') is not null
on conflict (migration_run_id,source_order,chapter) do nothing;

insert into maths.progress_snapshots(migration_run_id,source_row_number,source_row,generated_at)
select r.migration_run_id,r.source_row_number,r.source_row,maths.migration_parse_legacy_ts(r.source_row->>'Generated_At')
from maths.raw_source_rows r where r.source_sheet='Progress_Snapshot'
on conflict (migration_run_id,source_row_number) do nothing;



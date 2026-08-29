create or replace function legacy.parse_bool_text(p_value text)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when p_value is null or btrim(p_value)='' then null
    when lower(btrim(p_value)) in ('true','1','yes','y') then true
    when lower(btrim(p_value)) in ('false','0','no','n') then false
    else null
  end
$$;

create or replace function legacy.finalize_english_behavior_import(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, legacy, english, auth
as $$
declare
  v_batch uuid;
  v_perf bigint; v_attempts bigint; v_perf_orphans bigint; v_attempt_dups bigint;
  v_star bigint; v_star_imported bigint; v_star_orphans bigint;
  v_diff bigint; v_master bigint; v_master_imported bigint; v_master_orphans bigint;
  v_daily bigint; v_daily_imported bigint; v_daily_orphans bigint; v_daily_dups bigint;
  v_types bigint; v_sources bigint; v_hindu bigint; v_demand bigint;
  v_result jsonb;
begin
  if not exists(select 1 from auth.users where id=p_user_id and email_confirmed_at is not null) then
    raise exception 'Confirmed auth user not found';
  end if;

  select count(*) into v_perf from legacy.english_performance_raw;
  select count(*) into v_star from legacy.english_starred_revision_log_raw;
  select count(*) into v_diff from legacy.english_starred_revision_difficult_raw;
  select count(*) into v_master from legacy.english_mastered_log_raw;
  select count(*) into v_daily from legacy.english_daily_quiz_raw;
  select count(*) into v_types from legacy.english_my_word_types_raw;
  select count(*) into v_sources from legacy.english_sources_raw;
  select count(*) into v_hindu from legacy.english_hindu_words_raw;
  select count(*) into v_demand from legacy.english_demanded_practice_raw;

  if v_perf=0 then raise exception 'Performance staging is empty'; end if;

  insert into legacy.import_batches(app,source_spreadsheet_id,source_title,status,source_row_count,notes)
  values('english','1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak','English 30-Day Mastery','started',
         v_perf+v_star+v_diff+v_master+v_daily+v_types+v_sources+v_hindu+v_demand,
         'Behavior-parity supplemental import finalized from locked raw staging tables.')
  returning batch_id into v_batch;

  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Performance',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_performance_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Starred_Revision_Log',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_starred_revision_log_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Starred_Revision_Difficult',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_starred_revision_difficult_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Mastered_Log',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_mastered_log_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Daily_Quiz',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_daily_quiz_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','My_Word_Types',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_my_word_types_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Sources',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_sources_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Hindu_Words',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_hindu_words_raw r;
  insert into legacy.sheet_rows(batch_id,app,sheet_name,source_row,row_data,row_sha256)
  select v_batch,'english','Demanded_Practice',(source_row+1)::int,to_jsonb(r)-'source_row',encode(digest((to_jsonb(r)-'source_row')::text,'sha256'),'hex') from legacy.english_demanded_practice_raw r;

  select coalesce(sum(c-1),0) into v_attempt_dups from (select count(*) c from legacy.english_performance_raw where nullif(btrim("Attempt_ID"),'') is not null group by btrim("Attempt_ID") having count(*)>1) x;
  select count(*) into v_perf_orphans from legacy.english_performance_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));

  insert into legacy.unresolved_references(batch_id,app,sheet_name,source_row,reference_type,reference_value,row_data,reason)
  select v_batch,'english','Performance',(r.source_row+1)::int,'Question_ID',btrim(r."Question_ID"),to_jsonb(r)-'source_row','Historical attempt references a question absent from canonical Questions; preserved but not fabricated into production.'
  from legacy.english_performance_raw r
  where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));

  insert into english.attempts(attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,marked_revision,topic,concept_id,module,submission_key,created_at)
  select distinct on (btrim(r."Attempt_ID")) btrim(r."Attempt_ID"),p_user_id,btrim(r."Question_ID"),legacy.parse_excel_timestamptz(r."Timestamp"),nullif(btrim(r."Selected_Answer"),''),legacy.parse_bool_text(r."Correct"),nullif(btrim(r."Time_Seconds"),'')::numeric,coalesce(legacy.parse_bool_text(r."Marked_Revision"),false),nullif(btrim(r."Topic"),''),nullif(btrim(r."Concept_ID"),''),nullif(btrim(r."Module"),''),btrim(r."Attempt_ID"),coalesce(legacy.parse_excel_timestamptz(r."Timestamp"),now())
  from legacy.english_performance_raw r
  where nullif(btrim(r."Attempt_ID"),'') is not null and exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"))
  order by btrim(r."Attempt_ID"), r.source_row
  on conflict (attempt_id) do nothing;
  select count(*) into v_attempts from english.attempts where user_id=p_user_id;

  select count(*) into v_star_orphans from legacy.english_starred_revision_log_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));
  insert into legacy.unresolved_references(batch_id,app,sheet_name,source_row,reference_type,reference_value,row_data,reason)
  select v_batch,'english','Starred_Revision_Log',(r.source_row+1)::int,'Question_ID',btrim(r."Question_ID"),to_jsonb(r)-'source_row','Historical star event references a question absent from canonical Questions.'
  from legacy.english_starred_revision_log_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));
  insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action,source_row)
  select p_user_id,btrim(r."Question_ID"),legacy.parse_excel_timestamptz(r."Event_At"),legacy.parse_excel_date(r."Starred_Date"),nullif(btrim(r."Day_No"),'')::numeric::int,upper(btrim(r."Action")),(r.source_row+1)::int
  from legacy.english_starred_revision_log_raw r
  where upper(btrim(r."Action")) in ('STAR','UNSTAR') and exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID")) and legacy.parse_excel_timestamptz(r."Event_At") is not null
  on conflict (user_id,question_id,event_at,action) do nothing;
  get diagnostics v_star_imported = row_count;

  insert into english.difficult_state(user_id,question_id,difficult,updated_at)
  select p_user_id,btrim(x."Question_ID"),coalesce(legacy.parse_bool_text(x."Difficult"),false),legacy.parse_excel_timestamptz(x."Updated_At")
  from (select distinct on (btrim(r."Question_ID")) r.* from legacy.english_starred_revision_difficult_raw r where nullif(btrim(r."Question_ID"),'') is not null order by btrim(r."Question_ID"),r.source_row desc) x
  where exists(select 1 from english.questions q where q.question_id=btrim(x."Question_ID"))
  on conflict (user_id,question_id) do update set difficult=excluded.difficult,updated_at=excluded.updated_at;

  select count(*) into v_master_orphans from legacy.english_mastered_log_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));
  insert into legacy.unresolved_references(batch_id,app,sheet_name,source_row,reference_type,reference_value,row_data,reason)
  select v_batch,'english','Mastered_Log',(r.source_row+1)::int,'Question_ID',btrim(r."Question_ID"),to_jsonb(r)-'source_row','Historical mastery event references a question absent from canonical Questions.'
  from legacy.english_mastered_log_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));
  insert into english.mastery_events(user_id,question_id,mastered_on,reason,previous_status,source,category,restored_on,active,source_row)
  select p_user_id,btrim(r."Question_ID"),legacy.parse_excel_timestamptz(r."Mastered_On"),nullif(r."Reason",''),nullif(r."Previous_Status",''),nullif(r."Source",''),nullif(r."Category",''),legacy.parse_excel_timestamptz(r."Restored_On"),coalesce(legacy.parse_bool_text(r."Active"),true),(r.source_row+1)::int
  from legacy.english_mastered_log_raw r where exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"))
  on conflict (user_id,source_row) do nothing;
  get diagnostics v_master_imported = row_count;

  select count(*) into v_daily_orphans from legacy.english_daily_quiz_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));
  select coalesce(sum(c-1),0) into v_daily_dups from (select count(*) c from legacy.english_daily_quiz_raw where nullif(btrim("Question_ID"),'') is not null group by btrim("Question_ID") having count(*)>1) x;
  insert into legacy.unresolved_references(batch_id,app,sheet_name,source_row,reference_type,reference_value,row_data,reason)
  select v_batch,'english','Daily_Quiz',(r.source_row+1)::int,'Question_ID',btrim(r."Question_ID"),to_jsonb(r)-'source_row','Current Daily row references a question absent from canonical Questions.'
  from legacy.english_daily_quiz_raw r where nullif(btrim(r."Question_ID"),'') is not null and not exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"));
  delete from english.daily_current where user_id=p_user_id;
  insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id)
  select p_user_id,btrim(x."Question_ID"),x.source_row::int,nullif(btrim(x."Priority"),'')::numeric::int,nullif(x."Reason",''),legacy.parse_excel_date(x."Quiz_Date"),nullif(x."Status",''),nullif(x."Topic",''),nullif(x."Concept_ID",'')
  from (select distinct on (btrim(r."Question_ID")) r.* from legacy.english_daily_quiz_raw r where nullif(btrim(r."Question_ID"),'') is not null order by btrim(r."Question_ID"),r.source_row) x
  where exists(select 1 from english.questions q where q.question_id=btrim(x."Question_ID")) and legacy.parse_excel_date(x."Quiz_Date") is not null
  order by x.source_row;
  get diagnostics v_daily_imported = row_count;

  if exists(select 1 from legacy.english_my_word_types_raw where upper(btrim("Capture_Type")) not in ('AUTO','V','SM','OWS','PV','IP','CU')) then
    raise exception 'Unknown My_Word_Types Capture_Type found; refusing silent fallback';
  end if;
  if exists(select 1 from legacy.english_my_word_types_raw r where not exists(select 1 from english.saved_items s where s.saved_id=btrim(r."Saved_ID"))) then
    raise exception 'My_Word_Types contains Saved_ID not present in english.saved_items';
  end if;
  insert into english.saved_item_types(user_id,saved_id,capture_type,resolved_type,updated_at)
  select p_user_id,btrim(r."Saved_ID"),upper(btrim(r."Capture_Type")),
    case
      when upper(btrim(r."Capture_Type"))<>'AUTO' then upper(btrim(r."Capture_Type"))
      when lower(concat_ws(' ',s.word,s.meaning,s.context,s.explanation,s.question)) ~ '(concept|usage|grammar|uncountable|countable|confus|difference between|figurative|metaphor|passage tone|tone of)' then 'CU'
      when lower(concat_ws(' ',s.word,s.meaning,s.context,s.explanation,s.question)) ~ '(phrasal verb|verb + preposition|verb\+preposition)' then 'PV'
      when lower(concat_ws(' ',s.word,s.meaning,s.context,s.explanation,s.question)) ~ '(idiom|phrase|expression)' then 'IP'
      when lower(concat_ws(' ',s.word,s.meaning,s.context,s.explanation,s.question)) ~ '(one word substitution|one-word substitution|one word for)' then 'OWS'
      when lower(concat_ws(' ',s.word,s.meaning,s.context,s.explanation,s.question)) ~ '(spelling|misspell|correct spelling|incorrect spelling)' then 'SM'
      else 'V'
    end,
    legacy.parse_excel_timestamptz(r."Updated_At")
  from legacy.english_my_word_types_raw r join english.saved_items s on s.saved_id=btrim(r."Saved_ID")
  on conflict (user_id,saved_id) do update set capture_type=excluded.capture_type,resolved_type=excluded.resolved_type,updated_at=excluded.updated_at;

  insert into english.sources(source_id,source_type,source_name,source_file,source_date,active,imported_on,question_count,source_ref,notes,import_status,new_count,recall_count,duplicate_count,category_summary,processed_on)
  select btrim(r."Source_ID"),nullif(r."Source_Type",''),nullif(r."Source_Name",''),nullif(r."Source_File",''),legacy.parse_excel_date(r."Source_Date"),coalesce(legacy.parse_bool_text(r."Active"),true),legacy.parse_excel_timestamptz(r."Imported_On"),nullif(btrim(r."Question_Count"),'')::numeric::int,nullif(r."Source_Ref",''),nullif(r."Notes",''),nullif(r."Import_Status",''),nullif(btrim(r."New_Count"),'')::numeric::int,nullif(btrim(r."Recall_Count"),'')::numeric::int,nullif(btrim(r."Duplicate_Count"),'')::numeric::int,nullif(r."Category_Summary",''),legacy.parse_excel_timestamptz(r."Processed_On")
  from legacy.english_sources_raw r where nullif(btrim(r."Source_ID"),'') is not null
  on conflict (source_id) do update set source_type=excluded.source_type,source_name=excluded.source_name,source_file=excluded.source_file,source_date=excluded.source_date,active=excluded.active,imported_on=excluded.imported_on,question_count=excluded.question_count,source_ref=excluded.source_ref,notes=excluded.notes,import_status=excluded.import_status,new_count=excluded.new_count,recall_count=excluded.recall_count,duplicate_count=excluded.duplicate_count,category_summary=excluded.category_summary,processed_on=excluded.processed_on;

  insert into english.hindu_words(hindu_id,word_date,word,part_of_speech,meaning,synonyms,antonyms,example_sentence,word_family,usage_note,tip,memory_aid,article_title,source_url,source_name,learning_status,content_status,first_practiced,last_practiced,active)
  select btrim(r."Hindu_ID"),legacy.parse_excel_date(r."Date"),r."Word",nullif(r."Part_of_Speech",''),nullif(r."Meaning",''),nullif(r."Synonyms",''),nullif(r."Antonyms",''),nullif(r."Example_Sentence",''),nullif(r."Word_Family",''),nullif(r."Usage_Note",''),nullif(r."Tip",''),nullif(r."Memory_Aid",''),nullif(r."Article_Title",''),nullif(r."Source_URL",''),nullif(r."Source_Name",''),nullif(r."Learning_Status",''),nullif(r."Content_Status",''),legacy.parse_excel_timestamptz(r."First_Practiced"),legacy.parse_excel_timestamptz(r."Last_Practiced"),coalesce(legacy.parse_bool_text(r."Active"),true)
  from legacy.english_hindu_words_raw r where nullif(btrim(r."Hindu_ID"),'') is not null and nullif(btrim(r."Word"),'') is not null
  on conflict (hindu_id) do update set word_date=excluded.word_date,word=excluded.word,part_of_speech=excluded.part_of_speech,meaning=excluded.meaning,synonyms=excluded.synonyms,antonyms=excluded.antonyms,example_sentence=excluded.example_sentence,word_family=excluded.word_family,usage_note=excluded.usage_note,tip=excluded.tip,memory_aid=excluded.memory_aid,article_title=excluded.article_title,source_url=excluded.source_url,source_name=excluded.source_name,learning_status=excluded.learning_status,content_status=excluded.content_status,first_practiced=excluded.first_practiced,last_practiced=excluded.last_practiced,active=excluded.active;

  insert into english.practice_sets(set_id,name,description,active,created_at)
  select btrim(r."Batch_ID"),max(coalesce(nullif(r."Batch_Name",''),btrim(r."Batch_ID"))),max(nullif(r."Notes",'')),bool_or(coalesce(legacy.parse_bool_text(r."Active"),true)),coalesce(min(legacy.parse_excel_timestamptz(r."Created_Date")),now())
  from legacy.english_demanded_practice_raw r where nullif(btrim(r."Batch_ID"),'') is not null group by btrim(r."Batch_ID")
  on conflict (set_id) do update set name=excluded.name,description=excluded.description,active=excluded.active;
  delete from english.practice_set_items i where exists(select 1 from legacy.english_demanded_practice_raw r where btrim(r."Batch_ID")=i.set_id);
  insert into english.practice_set_items(set_id,question_id,sequence)
  select btrim(r."Batch_ID"),btrim(r."Question_ID"),nullif(btrim(r."Sequence"),'')::numeric::int
  from legacy.english_demanded_practice_raw r
  where nullif(btrim(r."Batch_ID"),'') is not null and nullif(btrim(r."Question_ID"),'') is not null and exists(select 1 from english.questions q where q.question_id=btrim(r."Question_ID"))
  order by btrim(r."Batch_ID"),nullif(btrim(r."Sequence"),'')::numeric::int;

  v_result=jsonb_build_object(
    'source',jsonb_build_object('performance',v_perf,'star_events',v_star,'difficult',v_diff,'mastery',v_master,'daily_current',v_daily,'saved_types',v_types,'sources',v_sources,'hindu_words',v_hindu,'demanded_practice',v_demand),
    'production',jsonb_build_object('attempts_total_for_user',v_attempts,'star_events_inserted_this_run',v_star_imported,'mastery_events_inserted_this_run',v_master_imported,'daily_current',v_daily_imported),
    'exceptions',jsonb_build_object('duplicate_attempt_ids_in_source',v_attempt_dups,'performance_orphans',v_perf_orphans,'star_orphans',v_star_orphans,'mastery_orphans',v_master_orphans,'daily_orphans',v_daily_orphans,'daily_duplicate_question_ids',v_daily_dups)
  );

  insert into legacy.reconciliation_runs(batch_id,app,completed_at,status,checks,notes)
  values(v_batch,'english',now(),'passed',v_result,'Behavior-parity supplemental import transformed and reconciled. Historical orphan references were preserved in legacy.unresolved_references and were not fabricated into canonical content.');
  update legacy.import_batches set status='completed',completed_at=now(),imported_row_count=v_perf+v_star+v_diff+v_master+v_daily+v_types+v_sources+v_hindu+v_demand,notes=notes||' Finalization passed.' where batch_id=v_batch;

  return jsonb_build_object('ok',true,'batch_id',v_batch,'checks',v_result);
end;
$$;

revoke all on function legacy.finalize_english_behavior_import(uuid) from public, anon, authenticated;

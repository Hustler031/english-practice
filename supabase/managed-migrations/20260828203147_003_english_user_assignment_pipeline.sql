create table if not exists legacy.user_assignment_runs (
  assignment_id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references legacy.import_batches(batch_id) on delete restrict,
  app text not null check (app in ('english','gk','maths')),
  user_id uuid not null references auth.users(id) on delete restrict,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'started' check (status in ('started','passed','failed')),
  counts jsonb not null default '{}'::jsonb,
  notes text,
  unique(batch_id,app,user_id)
);

create table if not exists legacy.unresolved_references (
  id bigint generated always as identity primary key,
  batch_id uuid not null references legacy.import_batches(batch_id) on delete restrict,
  app text not null check (app in ('english','gk','maths')),
  sheet_name text not null,
  source_row integer not null,
  reference_type text not null,
  reference_value text,
  row_data jsonb not null,
  reason text not null,
  recorded_at timestamptz not null default now(),
  unique(batch_id,sheet_name,source_row,reference_type)
);

alter table legacy.user_assignment_runs enable row level security;
alter table legacy.unresolved_references enable row level security;
revoke all on legacy.user_assignment_runs, legacy.unresolved_references from anon, authenticated;

create or replace function legacy.parse_excel_timestamptz(p_value text)
returns timestamptz
language plpgsql
stable
as $$
declare
  n numeric;
begin
  if p_value is null or btrim(p_value) = '' then return null; end if;
  begin
    n := p_value::numeric;
    return (timestamp '1899-12-30' + n * interval '1 day') at time zone 'Asia/Kolkata';
  exception when invalid_text_representation then
    begin
      return p_value::timestamptz;
    exception when others then
      return null;
    end;
  end;
end;
$$;

create or replace function legacy.parse_excel_date(p_value text)
returns date
language plpgsql
stable
as $$
declare
  n numeric;
begin
  if p_value is null or btrim(p_value) = '' then return null; end if;
  begin
    n := p_value::numeric;
    return date '1899-12-30' + floor(n)::integer;
  exception when invalid_text_representation then
    begin
      return p_value::date;
    exception when others then
      return null;
    end;
  end;
end;
$$;

create or replace function legacy.assign_english_snapshot(p_batch_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, legacy, english, auth
as $$
declare
  v_state integer := 0;
  v_daily integer := 0;
  v_saved integer := 0;
  v_orphans integer := 0;
  v_duplicates integer := 0;
  v_result jsonb;
begin
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'Target auth user % does not exist', p_user_id;
  end if;
  if not exists (select 1 from legacy.import_batches b where b.batch_id = p_batch_id and b.app='english') then
    raise exception 'English import batch % does not exist', p_batch_id;
  end if;

  insert into english.question_state (
    user_id,question_id,attempts,correct,wrong,accuracy,marked_count,avg_time,last_attempt,last_result,last_time,last_marked,
    correct_streak,status,next_review,mastered,mastered_on,repeat_suppressed_until,recall_check_count,updated_at
  )
  select
    p_user_id,
    r.row_data->>'Question_ID',
    coalesce(nullif(r.row_data->>'Attempts','')::integer,0),
    coalesce(nullif(r.row_data->>'Correct','')::integer,0),
    coalesce(nullif(r.row_data->>'Wrong','')::integer,0),
    nullif(r.row_data->>'Accuracy','')::numeric,
    coalesce(nullif(r.row_data->>'Marked_Count','')::integer,0),
    nullif(r.row_data->>'Avg_Time','')::numeric,
    legacy.parse_excel_timestamptz(r.row_data->>'Last_Attempt'),
    case when nullif(r.row_data->>'Last_Result','') is null then null else (r.row_data->>'Last_Result')::boolean end,
    nullif(r.row_data->>'Last_Time','')::numeric,
    case when nullif(r.row_data->>'Last_Marked','') is null then null else (r.row_data->>'Last_Marked')::boolean end,
    coalesce(nullif(r.row_data->>'Correct_Streak','')::integer,0),
    nullif(r.row_data->>'Status',''),
    legacy.parse_excel_timestamptz(r.row_data->>'Next_Review'),
    coalesce(nullif(r.row_data->>'Mastered','')::boolean,false),
    legacy.parse_excel_timestamptz(r.row_data->>'Mastered_On'),
    legacy.parse_excel_timestamptz(r.row_data->>'Repeat_Suppressed_Until'),
    coalesce(nullif(r.row_data->>'Recall_Check_Count','')::integer,0),
    now()
  from legacy.sheet_rows r
  join english.questions q on q.question_id = nullif(r.row_data->>'Question_ID','')
  where r.batch_id=p_batch_id and r.sheet_name='Question_Status'
  on conflict (user_id,question_id) do update set
    attempts=excluded.attempts, correct=excluded.correct, wrong=excluded.wrong, accuracy=excluded.accuracy,
    marked_count=excluded.marked_count, avg_time=excluded.avg_time, last_attempt=excluded.last_attempt,
    last_result=excluded.last_result, last_time=excluded.last_time, last_marked=excluded.last_marked,
    correct_streak=excluded.correct_streak, status=excluded.status, next_review=excluded.next_review,
    mastered=excluded.mastered, mastered_on=excluded.mastered_on,
    repeat_suppressed_until=excluded.repeat_suppressed_until, recall_check_count=excluded.recall_check_count,
    updated_at=now();
  get diagnostics v_state = row_count;

  insert into legacy.unresolved_references(batch_id,app,sheet_name,source_row,reference_type,reference_value,row_data,reason)
  select p_batch_id,'english','Daily_History',r.source_row,'question_id',r.row_data->>'Question_ID',r.row_data,
         'Historical Daily_History row references a Question_ID not present in the canonical English questions table.'
  from legacy.sheet_rows r
  left join english.questions q on q.question_id=nullif(r.row_data->>'Question_ID','')
  where r.batch_id=p_batch_id and r.sheet_name='Daily_History'
    and nullif(r.row_data->>'Question_ID','') is not null and q.question_id is null
  on conflict (batch_id,sheet_name,source_row,reference_type) do nothing;
  get diagnostics v_orphans = row_count;

  with ranked as (
    select r.*,
           row_number() over (
             partition by legacy.parse_excel_date(r.row_data->>'Quiz_Date'), r.row_data->>'Question_ID'
             order by r.source_row desc
           ) as rn,
           count(*) over (
             partition by legacy.parse_excel_date(r.row_data->>'Quiz_Date'), r.row_data->>'Question_ID'
           ) as dup_count
    from legacy.sheet_rows r
    join english.questions q on q.question_id=nullif(r.row_data->>'Question_ID','')
    where r.batch_id=p_batch_id and r.sheet_name='Daily_History'
  )
  insert into english.daily_history(user_id,quiz_date,day_no,question_id,priority,reason,status,topic,concept_id,archived_at)
  select p_user_id,
         legacy.parse_excel_date(row_data->>'Quiz_Date'),
         nullif(row_data->>'Day_No','')::integer,
         row_data->>'Question_ID',
         nullif(row_data->>'Priority','')::integer,
         nullif(row_data->>'Reason',''),
         nullif(row_data->>'Status',''),
         nullif(row_data->>'Topic',''),
         nullif(row_data->>'Concept_ID',''),
         legacy.parse_excel_timestamptz(row_data->>'Archived_At')
  from ranked where rn=1
  on conflict (user_id,quiz_date,question_id) do update set
    day_no=excluded.day_no, priority=excluded.priority, reason=excluded.reason, status=excluded.status,
    topic=excluded.topic, concept_id=excluded.concept_id, archived_at=excluded.archived_at;
  get diagnostics v_daily = row_count;

  select coalesce(sum(c-1),0)::integer into v_duplicates
  from (
    select count(*) c
    from legacy.sheet_rows r
    join english.questions q on q.question_id=nullif(r.row_data->>'Question_ID','')
    where r.batch_id=p_batch_id and r.sheet_name='Daily_History'
    group by legacy.parse_excel_date(r.row_data->>'Quiz_Date'), r.row_data->>'Question_ID'
    having count(*)>1
  ) d;

  insert into english.saved_items(
    saved_id,user_id,word,meaning,context,origin_question_id,origin_module,source,created_at,updated_at,status,
    practice_question_id,active,part_of_speech,synonyms,antonyms,example,explanation,question,option_a,option_b,option_c,
    option_d,correct_option,gpt_status,gpt_updated_at,gpt_source
  )
  select
    r.row_data->>'Saved_ID',p_user_id,nullif(r.row_data->>'Word',''),nullif(r.row_data->>'Meaning',''),
    nullif(r.row_data->>'Context',''),nullif(r.row_data->>'Origin_Question_ID',''),nullif(r.row_data->>'Origin_Module',''),
    nullif(r.row_data->>'Source',''),legacy.parse_excel_timestamptz(r.row_data->>'Created_At'),
    legacy.parse_excel_timestamptz(r.row_data->>'Updated_At'),nullif(r.row_data->>'Status',''),
    nullif(r.row_data->>'Practice_Question_ID',''),coalesce(nullif(r.row_data->>'Active','')::boolean,true),
    nullif(r.row_data->>'Part_of_Speech',''),nullif(r.row_data->>'Synonyms',''),nullif(r.row_data->>'Antonyms',''),
    nullif(r.row_data->>'Example',''),nullif(r.row_data->>'Explanation',''),nullif(r.row_data->>'Question',''),
    nullif(r.row_data->>'Option_A',''),nullif(r.row_data->>'Option_B',''),nullif(r.row_data->>'Option_C',''),
    nullif(r.row_data->>'Option_D',''),nullif(r.row_data->>'Correct_Option',''),nullif(r.row_data->>'GPT_Status',''),
    legacy.parse_excel_timestamptz(r.row_data->>'GPT_Updated_At'),nullif(r.row_data->>'GPT_Source','')
  from legacy.sheet_rows r
  where r.batch_id=p_batch_id and r.sheet_name='My_Words' and nullif(r.row_data->>'Saved_ID','') is not null
  on conflict (saved_id) do update set
    user_id=excluded.user_id, word=excluded.word, meaning=excluded.meaning, context=excluded.context,
    origin_question_id=excluded.origin_question_id, origin_module=excluded.origin_module, source=excluded.source,
    created_at=excluded.created_at, updated_at=excluded.updated_at, status=excluded.status,
    practice_question_id=excluded.practice_question_id, active=excluded.active, part_of_speech=excluded.part_of_speech,
    synonyms=excluded.synonyms, antonyms=excluded.antonyms, example=excluded.example, explanation=excluded.explanation,
    question=excluded.question, option_a=excluded.option_a, option_b=excluded.option_b, option_c=excluded.option_c,
    option_d=excluded.option_d, correct_option=excluded.correct_option, gpt_status=excluded.gpt_status,
    gpt_updated_at=excluded.gpt_updated_at, gpt_source=excluded.gpt_source;
  get diagnostics v_saved = row_count;

  v_result := jsonb_build_object(
    'question_state_rows',v_state,
    'daily_history_rows',v_daily,
    'saved_items_rows',v_saved,
    'historical_orphan_rows',v_orphans,
    'daily_duplicate_rows_deduplicated',v_duplicates
  );

  insert into legacy.user_assignment_runs(batch_id,app,user_id,completed_at,status,counts,notes)
  values(p_batch_id,'english',p_user_id,now(),'passed',v_result,
    'User-scoped English snapshot assigned. Historical orphan Daily_History rows remain preserved in immutable staging and unresolved_references; no placeholder questions were invented.')
  on conflict (batch_id,app,user_id) do update set completed_at=excluded.completed_at,status='passed',counts=excluded.counts,notes=excluded.notes;

  return v_result;
exception when others then
  insert into legacy.user_assignment_runs(batch_id,app,user_id,completed_at,status,counts,notes)
  values(p_batch_id,'english',p_user_id,now(),'failed','{}'::jsonb,sqlerrm)
  on conflict (batch_id,app,user_id) do update set completed_at=excluded.completed_at,status='failed',counts='{}'::jsonb,notes=sqlerrm;
  raise;
end;
$$;

revoke all on function legacy.assign_english_snapshot(uuid,uuid) from public, anon, authenticated;
revoke all on function legacy.parse_excel_timestamptz(text) from public, anon, authenticated;
revoke all on function legacy.parse_excel_date(text) from public, anon, authenticated;
-- Phase 1: reshape the retired Hindu daily lane into Daily Confusion 15.
-- User-facing/canonical semantics are Daily Confusion. The legacy task lane name
-- `hindu` is intentionally retained as a transport compatibility shim so the
-- existing private GitHub/OIDC bridge does not need to change atomically.

create table if not exists english.daily_confusion_items (
  batch_date date not null,
  slot smallint not null check (slot between 1 and 15),
  question_id text not null references english.questions(question_id) on delete cascade,
  bank_id text not null,
  category text not null,
  pair_cluster text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (batch_date, slot),
  unique (batch_date, question_id),
  unique (batch_date, bank_id),
  check (bank_id ~ '^CB[0-9]{4}$'),
  check (category in (
    'Confusable Words',
    'Phrasal Verb Contrast',
    'Look-alike / Spelling',
    'Homophone / Homonym',
    'Usage / Collocation'
  ))
);

create index if not exists daily_confusion_items_question_idx
  on english.daily_confusion_items(question_id)
  where active;

create or replace function english.daily_confusion_category_target(p_category text)
returns integer
language sql
immutable
set search_path = pg_catalog, english
as $$
select case p_category
  when 'Confusable Words' then 4
  when 'Phrasal Verb Contrast' then 3
  when 'Look-alike / Spelling' then 3
  when 'Homophone / Homonym' then 2
  when 'Usage / Collocation' then 3
  else 0
end;
$$;

create or replace function english.maintenance_verify_daily_confusion()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_source_id text := 'CONFUSION_'||to_char(v_day,'YYYYMMDD');
  v_items integer;
  v_questions integer;
  v_mapped integer;
  v_bad integer;
  v_confusable integer;
  v_phrasal integer;
  v_lookalike integer;
  v_homophone integer;
  v_usage integer;
  v_complete boolean;
begin
  select count(*) into v_items
  from english.daily_confusion_items i
  where i.batch_date=v_day and i.active;

  select count(*) into v_questions
  from english.daily_confusion_items i
  join english.questions q on q.question_id=i.question_id
  where i.batch_date=v_day and i.active and q.active
    and q.source_id=v_source_id and q.topic='Daily Confusion';

  select count(*) into v_mapped
  from english.daily_confusion_items i
  join english.questions q on q.question_id=i.question_id
  join english.question_concept_mappings m
    on m.question_id=q.question_id and m.concept_id=q.concept_id
  where i.batch_date=v_day and i.active and q.active;

  select count(*) into v_bad
  from english.daily_confusion_items i
  join english.questions q on q.question_id=i.question_id
  where i.batch_date=v_day and i.active
    and (
      btrim(coalesce(i.bank_id,'')) !~ '^CB[0-9]{4}$'
      or btrim(coalesce(i.pair_cluster,''))=''
      or btrim(coalesce(q.question,''))=''
      or btrim(coalesce(q.option_a,''))=''
      or btrim(coalesce(q.option_b,''))=''
      or btrim(coalesce(q.option_c,''))=''
      or btrim(coalesce(q.option_d,''))=''
      or upper(coalesce(q.correct,'')) not in ('A','B','C','D')
      or btrim(coalesce(q.explanation,''))=''
      or q.concept_id is null
    );

  select
    count(*) filter (where category='Confusable Words'),
    count(*) filter (where category='Phrasal Verb Contrast'),
    count(*) filter (where category='Look-alike / Spelling'),
    count(*) filter (where category='Homophone / Homonym'),
    count(*) filter (where category='Usage / Collocation')
  into v_confusable,v_phrasal,v_lookalike,v_homophone,v_usage
  from english.daily_confusion_items
  where batch_date=v_day and active;

  v_complete := (
    v_items=15
    and v_questions=15
    and v_mapped=15
    and v_bad=0
    and v_confusable=4
    and v_phrasal=3
    and v_lookalike=3
    and v_homophone=2
    and v_usage=3
  );

  return jsonb_build_object(
    'ok',(
      v_items=v_questions and v_questions=v_mapped and v_bad=0 and v_items<=15
      and v_confusable<=4 and v_phrasal<=3 and v_lookalike<=3 and v_homophone<=2 and v_usage<=3
    ),
    'date',v_day,
    'sourceId',v_source_id,
    'itemCount',v_items,
    'questionCount',v_questions,
    'mappedCount',v_mapped,
    'badCount',v_bad,
    'exactDailyTarget',15,
    'categoryCounts',jsonb_build_object(
      'Confusable Words',v_confusable,
      'Phrasal Verb Contrast',v_phrasal,
      'Look-alike / Spelling',v_lookalike,
      'Homophone / Homonym',v_homophone,
      'Usage / Collocation',v_usage
    ),
    'sourceComplete',v_complete,
    'completeBatch',v_complete,
    'overfilled',(v_items>15)
  );
end;
$$;

create or replace function english.daily_confusion_status()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_verify jsonb;
  v_count integer;
  v_confusable integer;
  v_phrasal integer;
  v_lookalike integer;
  v_homophone integer;
  v_usage integer;
begin
  v_verify := english.maintenance_verify_daily_confusion();
  v_count := coalesce((v_verify->>'itemCount')::int,0);
  v_confusable := coalesce((v_verify->'categoryCounts'->>'Confusable Words')::int,0);
  v_phrasal := coalesce((v_verify->'categoryCounts'->>'Phrasal Verb Contrast')::int,0);
  v_lookalike := coalesce((v_verify->'categoryCounts'->>'Look-alike / Spelling')::int,0);
  v_homophone := coalesce((v_verify->'categoryCounts'->>'Homophone / Homonym')::int,0);
  v_usage := coalesce((v_verify->'categoryCounts'->>'Usage / Collocation')::int,0);

  return jsonb_build_object(
    'ok',coalesce((v_verify->>'ok')::boolean,false),
    'date',v_day,
    'sourceId','CONFUSION_'||to_char(v_day,'YYYYMMDD'),
    'sourceFile','Confusion_Master_Bank',
    'existingToday',v_count,
    'exactDailyTarget',15,
    'missing',greatest(0,15-v_count),
    'capacityRemaining',greatest(0,15-v_count),
    'sourceComplete',coalesce((v_verify->>'sourceComplete')::boolean,false),
    'overfilled',(v_count>15),
    'categoryCounts',v_verify->'categoryCounts',
    'missingByCategory',jsonb_build_object(
      'Confusable Words',greatest(0,4-v_confusable),
      'Phrasal Verb Contrast',greatest(0,3-v_phrasal),
      'Look-alike / Spelling',greatest(0,3-v_lookalike),
      'Homophone / Homonym',greatest(0,2-v_homophone),
      'Usage / Collocation',greatest(0,3-v_usage)
    ),
    'existingItems',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'slot',i.slot,'questionId',i.question_id,'bankId',i.bank_id,
        'category',i.category,'pairCluster',i.pair_cluster
      ) order by i.slot),'[]'::jsonb)
      from english.daily_confusion_items i
      where i.batch_date=v_day and i.active
    )
  );
end;
$$;

create or replace function english.maintenance_check_confusion_candidates(p_candidates jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_item jsonb;
  v_bank_id text;
  v_category text;
  v_pair text;
  v_duplicate boolean;
  v_rows jsonb := '[]'::jsonb;
begin
  if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' then
    raise exception 'p_candidates must be a JSON array';
  end if;
  if jsonb_array_length(p_candidates) > 30 then
    raise exception 'At most 30 Daily Confusion candidates may be checked';
  end if;

  for v_item in select value from jsonb_array_elements(p_candidates) loop
    v_bank_id := upper(btrim(coalesce(v_item->>'bankId',v_item->>'bank_id','')));
    v_category := btrim(coalesce(v_item->>'category',''));
    v_pair := btrim(coalesce(v_item->>'pairCluster',v_item->>'pair_cluster',''));

    if v_bank_id !~ '^CB[0-9]{4}$' then raise exception 'Valid Confusion_Master_Bank Bank_ID required'; end if;
    if english.daily_confusion_category_target(v_category)=0 then raise exception 'Unsupported Daily Confusion category: %',v_category; end if;
    if v_pair='' then raise exception 'Pair / Cluster is required for %',v_bank_id; end if;

    select exists(
      select 1 from english.daily_confusion_items i
      where i.batch_date=v_day and i.active and i.bank_id=v_bank_id
    ) into v_duplicate;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'bankId',v_bank_id,
      'category',v_category,
      'pairCluster',v_pair,
      'duplicate',v_duplicate,
      'reason',case when v_duplicate then 'same_day_bank_repeat' else 'valid_master_bank_candidate' end,
      'collisionClass',case when v_duplicate then 'same_day_exact' else 'none' end
    ));
  end loop;

  return jsonb_build_object('ok',true,'count',jsonb_array_length(v_rows),'items',v_rows);
end;
$$;

create or replace function english.maintenance_apply_daily_confusion(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_source_id text := 'CONFUSION_'||to_char(v_day,'YYYYMMDD');
  v_item jsonb;
  v_bank_id text;
  v_category text;
  v_pair text;
  v_question text;
  v_explanation text;
  v_correct text;
  v_slot integer;
  v_qid text;
  v_concept text;
  v_current_category integer;
  v_target integer;
  v_count integer;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a JSON array';
  end if;
  if jsonb_array_length(p_items) > 15 then
    raise exception 'At most 15 Daily Confusion items may be applied in one payload';
  end if;

  perform pg_advisory_xact_lock(hashtext('english.maintenance_daily_confusion'));

  select count(*) into v_count
  from english.daily_confusion_items
  where batch_date=v_day and active;
  if jsonb_array_length(p_items) > greatest(0,15-v_count) then
    raise exception 'Payload exceeds remaining Daily Confusion capacity: % > %',jsonb_array_length(p_items),greatest(0,15-v_count);
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_bank_id := upper(btrim(coalesce(v_item->>'bankId',v_item->>'bank_id','')));
    v_category := btrim(coalesce(v_item->>'category',''));
    v_pair := btrim(coalesce(v_item->>'pairCluster',v_item->>'pair_cluster',''));
    v_question := btrim(coalesce(v_item->>'question',''));
    v_explanation := btrim(coalesce(v_item->>'explanation',''));
    v_correct := upper(btrim(coalesce(v_item->>'correctKey','')));

    if v_bank_id !~ '^CB[0-9]{4}$' then raise exception 'Valid Confusion_Master_Bank Bank_ID required'; end if;
    v_target := english.daily_confusion_category_target(v_category);
    if v_target=0 then raise exception 'Unsupported Daily Confusion category: %',v_category; end if;
    if v_pair='' or v_question='' or v_explanation='' then raise exception 'Bank pair, question and explanation are required for %',v_bank_id; end if;
    if btrim(coalesce(v_item->>'optionA',''))='' or btrim(coalesce(v_item->>'optionB',''))='' or btrim(coalesce(v_item->>'optionC',''))='' or btrim(coalesce(v_item->>'optionD',''))='' or v_correct not in ('A','B','C','D') then
      raise exception 'Daily Confusion MCQ requires four options and A-D key for %',v_bank_id;
    end if;
    if exists(select 1 from english.daily_confusion_items i where i.batch_date=v_day and i.active and i.bank_id=v_bank_id) then
      raise exception 'Daily Confusion Bank_ID already used today: %',v_bank_id;
    end if;

    select count(*) into v_current_category
    from english.daily_confusion_items
    where batch_date=v_day and active and category=v_category;
    if v_current_category >= v_target then
      raise exception 'Daily Confusion category quota already full for %',v_category;
    end if;

    select s into v_slot
    from generate_series(1,15) s
    where not exists(
      select 1 from english.daily_confusion_items i
      where i.batch_date=v_day and i.slot=s and i.active
    )
    order by s limit 1;
    if v_slot is null then raise exception 'No Daily Confusion slot available'; end if;

    v_qid := 'CF'||to_char(v_day,'YYYYMMDD')||'_'||lpad(v_slot::text,3,'0');
    v_concept := 'CONFUSION_'||v_bank_id;
    if exists(select 1 from english.questions q where q.question_id=v_qid) then
      raise exception 'Daily Confusion Question_ID already exists: %',v_qid;
    end if;

    insert into english.concepts(
      concept_id,domain,skill_family,name,description,confidence,exam_relevance,
      priority_score,coverage_state,is_atomic,active,metadata
    ) values(
      v_concept,'English','Daily Confusion',v_pair,
      coalesce(nullif(btrim(v_item->>'learningObjective'),''),v_pair),
      'high','high',90,'unseen',true,true,
      jsonb_build_object(
        'bankId',v_bank_id,'category',v_category,'pairCluster',v_pair,
        'source','Confusion_Master_Bank','owner','Central Intelligence'
      )
    ) on conflict(concept_id) do update set
      skill_family='Daily Confusion',
      name=excluded.name,
      description=excluded.description,
      active=true,
      metadata=english.concepts.metadata||excluded.metadata,
      updated_at=now();

    insert into english.questions(
      question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,
      explanation,subtopic,question_type,source_file,source_page,concept_id,difficulty,
      source_id,learning_status,content_status,exam_relevance,tip,usage_note,
      example_sentence,memory_aid,related_words,source_url,review_notes,active,created_at,updated_at
    ) values(
      v_qid,'Daily Confusion',v_pair,v_question,
      v_item->>'optionA',v_item->>'optionB',v_item->>'optionC',v_item->>'optionD',v_correct,
      v_explanation,v_category,coalesce(nullif(btrim(v_item->>'questionType'),''),'Confusion MCQ'),
      'Confusion_Master_Bank','',v_concept,coalesce(nullif(btrim(v_item->>'difficulty'),''),'Hard'),
      v_source_id,'New','Active','SSC CGL',coalesce(v_item->>'tip',''),coalesce(v_item->>'usageNote',''),
      coalesce(v_item->>'example',''),coalesce(v_item->>'memoryAid',''),
      coalesce(nullif(v_item->>'relatedWords',''),v_pair),'',
      concat_ws(' | ','Bank_ID: '||v_bank_id,'Pair/Cluster: '||v_pair,'Generator: ChatGPT self-critic'),
      true,now(),now()
    );

    insert into english.question_concept_mappings(
      question_id,concept_id,mapping_confidence,mapping_method,review_status,relation_type
    ) values(v_qid,v_concept,1,'deterministic_confusion_bank','mapped','primary')
    on conflict(question_id) do update set
      concept_id=excluded.concept_id,
      mapping_confidence=1,
      mapping_method='deterministic_confusion_bank',
      review_status='mapped',
      relation_type='primary',
      updated_at=now();

    insert into english.daily_confusion_items(batch_date,slot,question_id,bank_id,category,pair_cluster,active)
    values(v_day,v_slot,v_qid,v_bank_id,v_category,v_pair,true);
  end loop;

  select count(*) into v_count
  from english.daily_confusion_items
  where batch_date=v_day and active;

  insert into english.sources(
    source_id,source_type,source_name,source_file,source_date,active,imported_on,
    question_count,source_ref,notes,import_status,new_count,duplicate_count,category_summary,processed_on
  ) values(
    v_source_id,'Curated Confusion Practice','Daily Confusion 15','Confusion_Master_Bank',v_day,true,now(),
    v_count,'ChatGPT curated from Confusion_Master_Bank',
    'Daily Confusion is generated by ChatGPT from the fixed master pair/cluster bank. Canonical questions are mapped into Central Intelligence; no backend AI generation and no current-news vocabulary research.',
    case when coalesce((english.maintenance_verify_daily_confusion()->>'sourceComplete')::boolean,false) then 'Complete' else 'Partial' end,
    v_count,0,'Daily Confusion: '||v_count,now()
  ) on conflict(source_id) do update set
    question_count=excluded.question_count,
    active=true,
    source_ref=excluded.source_ref,
    notes=excluded.notes,
    import_status=excluded.import_status,
    new_count=excluded.new_count,
    duplicate_count=0,
    category_summary=excluded.category_summary,
    processed_on=now();

  return english.maintenance_verify_daily_confusion();
end;
$$;

create or replace function public.english_get_confusion_quiz()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select coalesce(jsonb_agg(
    english.question_payload(uid,i.question_id) || jsonb_build_object(
      'id',i.question_id,
      'centralQuestionId',i.question_id,
      'bankId',i.bank_id,
      'confusionCategory',i.category,
      'pairCluster',i.pair_cluster,
      'slot',i.slot
    ) order by i.slot
  ),'[]'::jsonb) into out
  from english.daily_confusion_items i
  join english.questions q on q.question_id=i.question_id and q.active
  where i.batch_date=v_day and i.active;
  return out;
end;
$$;

create or replace function public.english_confusion_progress()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, english, auth
as $$
with items as (
  select i.question_id
  from english.daily_confusion_items i
  where auth.uid() is not null
    and i.active
    and i.batch_date=(now() at time zone 'Asia/Kolkata')::date
), counts as (
  select i.question_id,
    (select count(*) from english.attempts a
     where a.user_id=auth.uid() and a.question_id=i.question_id
       and lower(coalesce(a.module,''))='confusion') n
  from items i
)
select jsonb_build_object(
  'total',(select count(*) from items),
  'completed',(select count(*) from counts where n>0),
  'roundsCompleted',coalesce((select min(n) from counts),0),
  'nextRound',coalesce((select min(n) from counts),0)+1,
  'target',15
);
$$;

create or replace function public.english_submit_confusion_answer(
  p_question_id text,
  p_selected_key text,
  p_time_seconds numeric default 0,
  p_attempt_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english, auth
as $$
declare
  uid uuid := auth.uid();
  v_qid text := btrim(coalesce(p_question_id,''));
  q english.questions%rowtype;
  v_key text := upper(btrim(coalesce(p_selected_key,'')));
  v_correct_key text;
  v_correct boolean;
  v_id text;
  v_rows integer;
  v_state jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if v_key not in ('A','B','C','D') then raise exception 'Invalid answer'; end if;
  if not exists(
    select 1 from english.daily_confusion_items i
    where i.batch_date=(now() at time zone 'Asia/Kolkata')::date
      and i.active and i.question_id=v_qid
  ) then return jsonb_build_object('ok',false,'reason','not-todays-confusion','questionId',v_qid); end if;

  select * into q
  from english.questions
  where question_id=v_qid and active and english.question_visible_to_user(uid,question_id);
  if not found then return jsonb_build_object('ok',false,'reason','not-active-question','questionId',v_qid); end if;

  v_correct_key := upper(btrim(coalesce(q.correct,'')));
  if v_correct_key not in ('A','B','C','D') then raise exception 'Canonical Daily Confusion question has invalid correct key'; end if;
  v_correct := (v_key=v_correct_key);
  v_id := coalesce(nullif(btrim(p_attempt_id),''),v_qid||'-CONFUSION-'||floor(extract(epoch from clock_timestamp())*1000)::bigint||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6));

  insert into english.attempts(
    attempt_id,user_id,question_id,attempted_at,selected_answer,correct,time_seconds,
    marked_revision,topic,concept_id,module,submission_key,created_at
  ) values(
    v_id,uid,v_qid,now(),v_key,v_correct,least(180,greatest(0,coalesce(p_time_seconds,0))),
    false,q.topic,q.concept_id,'confusion',v_id,now()
  ) on conflict do nothing;
  get diagnostics v_rows=row_count;

  select english.recompute_question_state(uid,v_qid) into v_state;
  return jsonb_build_object(
    'ok',true,'durable',true,'deduped',(v_rows=0),'correct',v_correct,
    'correctKey',v_correct_key,'questionId',v_qid,'attemptId',v_id,'state',v_state
  );
end;
$$;

-- Compatibility wrappers for the existing private `hindu` transport lane.
-- These deliberately no longer use Hindu/newspaper semantics.
create or replace function english.maintenance_hindu_status()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, english, auth
as $$ select english.daily_confusion_status(); $$;

create or replace function english.maintenance_verify_hindu_daily()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, english, auth
as $$ select english.maintenance_verify_daily_confusion(); $$;

create or replace function english.maintenance_hindu_check_candidates(p_candidates jsonb)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, english, auth
as $$ select english.maintenance_check_confusion_candidates(p_candidates); $$;

create or replace function english.maintenance_apply_hindu_daily(p_items jsonb)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, english, auth
as $$ select english.maintenance_apply_daily_confusion(p_items); $$;

create or replace function public.english_hindu_task_claim()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english
as $$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_status jsonb;
  v_run uuid;
  v_active uuid;
  v_existing integer;
begin
  perform pg_advisory_xact_lock(hashtext('english.daily_confusion_chatgpt_task'));
  v_status := english.daily_confusion_status();
  v_existing := coalesce((v_status->>'existingToday')::int,0);
  if coalesce((v_status->>'sourceComplete')::boolean,false) then
    return v_status||jsonb_build_object('count',0,'complete',true,'contentLane','daily_confusion');
  end if;
  if v_existing>15 then
    return v_status||jsonb_build_object('count',0,'complete',false,'overfilled',true,'contentLane','daily_confusion');
  end if;

  update english.chatgpt_content_task_runs
  set status='superseded',updated_at=now()
  where lane='hindu' and batch_date=v_day and status in ('claimed','checked') and created_at<now()-interval '4 hours';

  select run_id into v_active
  from english.chatgpt_content_task_runs
  where lane='hindu' and batch_date=v_day and status in ('claimed','checked')
  order by created_at desc limit 1;
  if v_active is not null then
    return jsonb_build_object('ok',true,'busy',true,'runId',v_active,'status',v_status,'contentLane','daily_confusion');
  end if;

  v_run := gen_random_uuid();
  insert into english.chatgpt_content_task_runs(run_id,lane,batch_date,status)
  values(v_run,'hindu',v_day,'claimed');
  return v_status||jsonb_build_object(
    'runId',v_run,'busy',false,'count',coalesce((v_status->>'missing')::int,0),
    'contentLane','daily_confusion'
  );
end;
$$;

create or replace function public.english_hindu_task_check_candidates(p_run_id uuid,p_candidates jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v jsonb;
begin
  select * into r
  from english.chatgpt_content_task_runs
  where run_id=p_run_id and lane='hindu'
  for update;
  if not found or r.status not in ('claimed','checked') then
    raise exception 'Daily Confusion run is not available for candidate check';
  end if;
  v := english.maintenance_check_confusion_candidates(p_candidates);
  update english.chatgpt_content_task_runs set status='checked',updated_at=now() where run_id=p_run_id;
  return v||jsonb_build_object('runId',p_run_id,'contentLane','daily_confusion');
end;
$$;

create or replace function public.english_hindu_task_apply(p_run_id uuid,p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, english
as $$
declare
  r english.chatgpt_content_task_runs%rowtype;
  v_apply jsonb;
  v_verify jsonb;
begin
  select * into r
  from english.chatgpt_content_task_runs
  where run_id=p_run_id and lane='hindu'
  for update;
  if not found then raise exception 'Unknown Daily Confusion run'; end if;
  if r.status='applied' then return coalesce(r.result,jsonb_build_object('ok',true,'alreadyApplied',true)); end if;
  if r.status not in ('claimed','checked') then raise exception 'Daily Confusion run is not applicable: %',r.status; end if;

  v_apply := english.maintenance_apply_daily_confusion(p_items);
  v_verify := english.maintenance_verify_daily_confusion();
  if not coalesce((v_verify->>'ok')::boolean,false) then
    raise exception 'Daily Confusion verification failed after apply';
  end if;

  update english.chatgpt_content_task_runs
  set status='applied',
      result=jsonb_build_object('apply',v_apply,'verify',v_verify,'contentLane','daily_confusion'),
      applied_at=now(),updated_at=now()
  where run_id=p_run_id;
  return jsonb_build_object('ok',true,'apply',v_apply,'verify',v_verify,'contentLane','daily_confusion');
end;
$$;

grant execute on function public.english_get_confusion_quiz() to authenticated;
grant execute on function public.english_confusion_progress() to authenticated;
grant execute on function public.english_submit_confusion_answer(text,text,numeric,text) to authenticated;

comment on table english.daily_confusion_items is
  'Daily Confusion 15 membership. Canonical question/concept state remains in English Central Intelligence tables.';

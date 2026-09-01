-- English V2 concept evidence integration.
-- Adds cross-surface evidence without deleting historical question-level state.

create table if not exists english.concept_evidence_events (
  event_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id text not null references english.concepts(concept_id) on delete restrict,
  question_id text references english.questions(question_id) on delete set null,
  source text not null,
  source_key text not null,
  event_type text not null default 'assessment',
  correct boolean,
  variant text,
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(source,source_key)
);
create index if not exists english_concept_events_user_concept_idx
  on english.concept_evidence_events(user_id,concept_id,occurred_at desc);
alter table english.concept_evidence_events enable row level security;
drop policy if exists english_concept_events_owner on english.concept_evidence_events;
create policy english_concept_events_owner on english.concept_evidence_events for select to authenticated
  using ((select auth.uid())=user_id);

create table if not exists english.saved_concept_mappings (
  saved_id text primary key references english.saved_items(saved_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id text not null references english.concepts(concept_id) on delete restrict,
  mapping_confidence numeric not null default .72 check(mapping_confidence between 0 and 1),
  mapping_method text not null default 'post_enrichment_deterministic',
  model text,
  embedding_vector extensions.vector(1536),
  embedded_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists english_saved_concept_user_idx on english.saved_concept_mappings(user_id,concept_id);
alter table english.saved_concept_mappings enable row level security;
drop policy if exists english_saved_concept_owner on english.saved_concept_mappings;
create policy english_saved_concept_owner on english.saved_concept_mappings for select to authenticated
  using ((select auth.uid())=user_id);

create or replace function english.recompute_concept_evidence(p_user_id uuid,p_concept_id text) returns void
language plpgsql security definer set search_path=pg_catalog,english as $$
declare r record; v_guessed int:=0; score numeric:=0; state text:='unseen'; v_next timestamptz;
begin
  with raw as (
    select a.attempted_at occurred_at,a.correct,a.question_id,
      coalesce(nullif(a.module,''),'practice') variant,a.question_id evidence_key,null::text diagnosis
    from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id
    where a.user_id=p_user_id and m.concept_id=p_concept_id
    union all
    select e.occurred_at,e.correct,e.question_id,coalesce(nullif(e.variant,''),e.source),
      coalesce(e.question_id,e.source_key),e.metadata->>'diagnosis'
    from english.concept_evidence_events e
    where e.user_id=p_user_id and e.concept_id=p_concept_id
  ), ordered as (
    select raw.*,lag(occurred_at) over(order by occurred_at,evidence_key) prev_at from raw
  )
  select count(*)::int,
    count(*) filter(where correct is true)::int,
    count(*) filter(where correct is false)::int,
    count(distinct evidence_key)::int,
    count(distinct variant)::int,
    count(*) filter(where correct is true and lower(variant) ~ '(target|sprint|fast|transfer)')::int,
    count(*) filter(where correct is true and prev_at is not null and occurred_at-prev_at>=interval '20 hours')::int,
    count(*) filter(where correct is false and occurred_at>=now()-interval '7 days')::int,
    count(*) filter(where lower(coalesce(diagnosis,''))='confusion')::int,
    max(occurred_at)
  into r.attempts,r.correct,r.wrong,r.distinct_questions,r.distinct_variants,
    r.transfer_successes,r.delayed_successes,r.recent_failures,r.confusion_count,r.last_attempt_at
  from ordered;

  select count(*)::int into v_guessed
  from english.learner_confidence_signals g
  join english.question_concept_mappings m on m.question_id=g.question_id
  where g.user_id=p_user_id and m.concept_id=p_concept_id and g.signal='guessed';

  score:=greatest(0,least(100,
      least(45,coalesce(r.correct,0)*7)
    + least(20,coalesce(r.distinct_questions,0)*7)
    + least(15,coalesce(r.delayed_successes,0)*7.5)
    + least(12,coalesce(r.transfer_successes,0)*6)
    - least(30,coalesce(r.recent_failures,0)*12)
    - least(20,coalesce(v_guessed,0)*5)
    - least(20,coalesce(r.confusion_count,0)*7)
  ));

  state:=case
    when coalesce(r.attempts,0)=0 then 'unseen'
    when coalesce(r.recent_failures,0)>=2 and score<55 then 'weak'
    when coalesce(r.recent_failures,0)>0 and score>=55 then 'retention_risk'
    when score>=82 and coalesce(r.delayed_successes,0)>=1 and coalesce(r.distinct_questions,0)>=2 and coalesce(r.transfer_successes,0)>=1 then 'exam_ready'
    when score>=60 and coalesce(r.distinct_questions,0)>=2 then 'secure'
    else 'seen'
  end;
  v_next:=case state
    when 'weak' then coalesce(r.last_attempt_at,now())+interval '8 hours'
    when 'retention_risk' then coalesce(r.last_attempt_at,now())+interval '1 day'
    when 'seen' then coalesce(r.last_attempt_at,now())+interval '2 days'
    when 'secure' then coalesce(r.last_attempt_at,now())+interval '6 days'
    when 'exam_ready' then coalesce(r.last_attempt_at,now())+interval '12 days'
    else null end;

  insert into english.concept_evidence(
    user_id,concept_id,attempts,correct,wrong,guessed,distinct_questions,distinct_variants,
    transfer_successes,delayed_successes,recent_failures,confusion_count,
    confidence_score,coverage_state,next_review,last_attempt_at,updated_at
  ) values(
    p_user_id,p_concept_id,coalesce(r.attempts,0),coalesce(r.correct,0),coalesce(r.wrong,0),coalesce(v_guessed,0),
    coalesce(r.distinct_questions,0),coalesce(r.distinct_variants,0),coalesce(r.transfer_successes,0),
    coalesce(r.delayed_successes,0),coalesce(r.recent_failures,0),coalesce(r.confusion_count,0),
    score,state,v_next,r.last_attempt_at,now()
  ) on conflict(user_id,concept_id) do update set
    attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,guessed=excluded.guessed,
    distinct_questions=excluded.distinct_questions,distinct_variants=excluded.distinct_variants,
    transfer_successes=excluded.transfer_successes,delayed_successes=excluded.delayed_successes,
    recent_failures=excluded.recent_failures,confusion_count=excluded.confusion_count,
    confidence_score=excluded.confidence_score,coverage_state=excluded.coverage_state,
    next_review=excluded.next_review,last_attempt_at=excluded.last_attempt_at,updated_at=now();
end $$;
revoke all on function english.recompute_concept_evidence(uuid,text) from public;

create or replace function english.on_attempt_concept_evidence() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
declare cid text;
begin
  select m.concept_id into cid from english.question_concept_mappings m where m.question_id=new.question_id;
  if cid is not null then perform english.recompute_concept_evidence(new.user_id,cid); end if;
  return new;
end $$;
revoke all on function english.on_attempt_concept_evidence() from public;
drop trigger if exists english_attempt_concept_evidence on english.attempts;
create trigger english_attempt_concept_evidence after insert on english.attempts
for each row execute function english.on_attempt_concept_evidence();

create or replace function english.sprint_concept_id(p_session_id uuid,p_position integer) returns text
language plpgsql security definer set search_path=pg_catalog,english as $$
declare i english.sprint_items%rowtype; cid text; ckey text; dom text;
begin
  select * into i from english.sprint_items where session_id=p_session_id and position=p_position;
  if not found then return null; end if;
  if i.canonical_question_id is not null then
    select m.concept_id into cid from english.question_concept_mappings m where m.question_id=i.canonical_question_id;
    if cid is not null then return cid; end if;
  end if;
  ckey:=nullif(trim(coalesce(i.metadata->>'conceptKey','')),'');
  if ckey is null then ckey:='sprint-'||p_session_id::text||'-'||p_position::text; end if;
  dom:=coalesce(nullif(trim(i.metadata->>'domain'),''),'English');
  cid:='SPR_'||md5(lower(dom||'|'||ckey));
  insert into english.concepts(concept_id,domain,skill_family,name,description,confidence,exam_relevance,priority_score,metadata)
  values(cid,'English',coalesce(nullif(trim(i.category),''),'Sprint'),ckey,nullif(trim(i.explanation),''),'medium','high',70,
    jsonb_build_object('initial_source','sprint','domain',dom,'question_type',i.question_type))
  on conflict(concept_id) do update set updated_at=now();
  return cid;
end $$;

create or replace function english.sync_sprint_concept_event(p_session_id uuid,p_position integer) returns void
language plpgsql security definer set search_path=pg_catalog,english,auth as $$
declare a english.sprint_answers%rowtype; i english.sprint_items%rowtype; cid text; skey text;
begin
  select * into a from english.sprint_answers where session_id=p_session_id and position=p_position;
  if not found or a.selected_key is null then return; end if;
  select * into i from english.sprint_items where session_id=p_session_id and position=p_position;
  if not found then return; end if;
  cid:=english.sprint_concept_id(p_session_id,p_position); if cid is null then return; end if;
  skey:=p_session_id::text||':'||p_position::text;
  insert into english.concept_evidence_events(user_id,concept_id,question_id,source,source_key,event_type,correct,variant,occurred_at,metadata)
  values(a.user_id,cid,i.canonical_question_id,'sprint',skey,'assessment',a.correct,
    'sprint:'||coalesce(i.question_type,'unknown'),coalesce(a.updated_at,a.created_at,now()),
    jsonb_strip_nulls(jsonb_build_object('diagnosis',a.diagnosis,'action',a.action,'confused_with',a.confused_with,
      'difficulty',i.metadata->>'difficultyTier','source_type',i.source_type)))
  on conflict(source,source_key) do update set concept_id=excluded.concept_id,question_id=excluded.question_id,
    correct=excluded.correct,variant=excluded.variant,occurred_at=excluded.occurred_at,metadata=excluded.metadata;
  perform english.recompute_concept_evidence(a.user_id,cid);
end $$;

create or replace function english.on_sprint_concept_evidence() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
begin perform english.sync_sprint_concept_event(new.session_id,new.position); return new; end $$;
drop trigger if exists english_sprint_concept_evidence on english.sprint_answers;
create trigger english_sprint_concept_evidence after insert or update of selected_key,correct,diagnosis,action,confused_with
on english.sprint_answers for each row execute function english.on_sprint_concept_evidence();

create or replace function english.saved_concept_seed_id(p_type text,p_word text) returns text
language sql immutable set search_path=pg_catalog as $$
select 'SAVED_'||md5(lower(trim(coalesce(p_type,'V')||'|'||coalesce(p_word,''))));
$$;

create or replace function english.sync_saved_concept(p_saved_id text) returns text
language plpgsql security definer set search_path=pg_catalog,english,auth as $$
declare s english.saved_items%rowtype; resolved text; cid text; fam text; origin_cid text;
begin
  select * into s from english.saved_items where saved_id=p_saved_id;
  if not found or not coalesce(s.active,true) then return null; end if;
  if lower(coalesce(s.gpt_status,'')) not in ('ready','complete','completed','done') then return null; end if;
  select coalesce(t.resolved_type,t.capture_type,'V') into resolved
  from english.saved_item_types t where t.saved_id=s.saved_id and t.user_id=s.user_id;
  resolved:=coalesce(resolved,'V');
  if nullif(trim(s.practice_question_id),'') is not null then
    select m.concept_id into cid from english.question_concept_mappings m where m.question_id=s.practice_question_id;
  end if;
  if cid is null and nullif(trim(s.origin_question_id),'') is not null then
    select m.concept_id into origin_cid
    from english.question_concept_mappings m join english.questions q on q.question_id=m.question_id
    where m.question_id=s.origin_question_id and (nullif(trim(s.word),'') is null or lower(trim(coalesce(q.word,'')))=lower(trim(coalesce(s.word,''))));
    cid:=origin_cid;
  end if;
  if cid is null then
    cid:=english.saved_concept_seed_id(resolved,s.word);
    fam:=case resolved when 'PV' then 'Phrasal Verbs' when 'IP' then 'Idioms & Phrases'
      when 'OWS' then 'One Word Substitution' when 'SM' then 'Spelling & Usage'
      when 'CU' then 'Contextual Usage' else 'Vocabulary' end;
    insert into english.concepts(concept_id,domain,skill_family,name,description,confidence,exam_relevance,priority_score,metadata)
    values(cid,'English',fam,coalesce(nullif(trim(s.word),''),'Saved item'),nullif(trim(coalesce(s.meaning,'')),''),
      'medium','high',65,jsonb_build_object('initial_source','my_saved','resolved_type',resolved))
    on conflict(concept_id) do update set
      name=case when english.concepts.name in ('Saved item','Unclassified concept') then excluded.name else english.concepts.name end,
      description=coalesce(english.concepts.description,excluded.description),updated_at=now();
  end if;
  insert into english.saved_concept_mappings(saved_id,user_id,concept_id,mapping_confidence,mapping_method,updated_at)
  values(s.saved_id,s.user_id,cid,.72,'post_enrichment_deterministic',now())
  on conflict(saved_id) do update set user_id=excluded.user_id,concept_id=excluded.concept_id,
    mapping_confidence=greatest(english.saved_concept_mappings.mapping_confidence,excluded.mapping_confidence),updated_at=now();
  if nullif(trim(s.practice_question_id),'') is not null
     and exists(select 1 from english.questions q where q.question_id=s.practice_question_id)
     and not exists(select 1 from english.question_concept_mappings m where m.question_id=s.practice_question_id) then
    insert into english.question_concept_mappings(question_id,concept_id,family_id,mapping_confidence,mapping_method,review_status,relation_type)
    select s.practice_question_id,cid,'F_'||md5(lower(trim(coalesce(q.topic,'English')||'|'||coalesce(q.subtopic,q.question_type,'Unclassified')))),
      .86,'saved_post_enrichment','verified','primary' from english.questions q where q.question_id=s.practice_question_id;
  end if;
  return cid;
end $$;

create or replace function english.on_saved_concept_sync() returns trigger
language plpgsql security definer set search_path=pg_catalog,english as $$
begin
  if lower(coalesce(new.gpt_status,'')) in ('ready','complete','completed','done')
     and (tg_op='INSERT' or old.gpt_status is distinct from new.gpt_status
       or old.gpt_updated_at is distinct from new.gpt_updated_at
       or old.practice_question_id is distinct from new.practice_question_id) then
    perform english.sync_saved_concept(new.saved_id);
  end if;
  return new;
end $$;
drop trigger if exists english_saved_concept_sync on english.saved_items;
create trigger english_saved_concept_sync after insert or update of gpt_status,gpt_updated_at,practice_question_id
on english.saved_items for each row execute function english.on_saved_concept_sync();

-- Backfill already-enriched Saved items without changing enrichment content.
do $$ declare s record; begin
  for s in select saved_id from english.saved_items where active and lower(coalesce(gpt_status,'')) in ('ready','complete','completed','done') loop
    perform english.sync_saved_concept(s.saved_id);
  end loop;
end $$;

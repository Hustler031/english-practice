alter table english.learner_context_notes
  add column if not exists ai_status text not null default 'not_needed',
  add column if not exists ai_attempts integer not null default 0,
  add column if not exists ai_attempted_at timestamptz,
  add column if not exists ai_next_attempt_at timestamptz,
  add column if not exists ai_error text;

alter table english.learner_confidence_signals
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution_attempt_id text;

create table if not exists english.learner_confusions(
  confusion_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  primary_concept_id text not null references english.concepts(concept_id) on delete cascade,
  primary_question_id text references english.questions(question_id) on delete set null,
  related_concept_id text references english.concepts(concept_id) on delete set null,
  related_question_id text references english.questions(question_id) on delete set null,
  related_term text,
  confusion_key text not null,
  source_note_id uuid references english.learner_context_notes(note_id) on delete set null,
  status text not null default 'open',
  strength integer not null default 1,
  opened_at timestamptz not null default now(),
  last_signal_at timestamptz not null default now(),
  last_validation_at timestamptz,
  resolved_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  unique(user_id,confusion_key)
);
alter table english.learner_confusions enable row level security;
revoke all on english.learner_confusions from public,anon,authenticated;
grant select,insert,update,delete on english.learner_confusions to service_role;
create index if not exists english_learner_confusions_user_status_idx on english.learner_confusions(user_id,status,last_signal_at desc);
create index if not exists english_learner_confusions_primary_idx on english.learner_confusions(user_id,primary_concept_id,status);
create index if not exists english_learner_confusions_related_idx on english.learner_confusions(user_id,related_concept_id,status) where related_concept_id is not null;

create table if not exists english.learning_intelligence_activity(
  activity_id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  activity_type text not null,
  title text not null,
  detail text,
  question_id text references english.questions(question_id) on delete set null,
  concept_id text references english.concepts(concept_id) on delete set null,
  source_note_id uuid references english.learner_context_notes(note_id) on delete set null,
  route text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
alter table english.learning_intelligence_activity enable row level security;
revoke all on english.learning_intelligence_activity from public,anon,authenticated;
grant select,insert,update,delete on english.learning_intelligence_activity to service_role;
create index if not exists english_learning_activity_user_time_idx on english.learning_intelligence_activity(user_id,occurred_at desc);
create unique index if not exists english_learning_activity_note_type_uidx
  on english.learning_intelligence_activity(user_id,source_note_id,activity_type)
  where source_note_id is not null;

create or replace function english.log_learning_activity(
  p_user_id uuid,p_type text,p_title text,p_detail text default null,p_question_id text default null,
  p_concept_id text default null,p_source_note_id uuid default null,p_route text default null,p_metadata jsonb default '{}'::jsonb,
  p_occurred_at timestamptz default now()
) returns bigint
language plpgsql security definer
set search_path to 'pg_catalog','english'
as $$
declare v_id bigint;
begin
  insert into english.learning_intelligence_activity(
    user_id,activity_type,title,detail,question_id,concept_id,source_note_id,route,metadata,occurred_at
  ) values(
    p_user_id,left(coalesce(nullif(trim(p_type),''),'learning_action'),80),left(coalesce(nullif(trim(p_title),''),'Learning action'),180),
    nullif(left(coalesce(p_detail,''),600),''),p_question_id,p_concept_id,p_source_note_id,p_route,coalesce(p_metadata,'{}'::jsonb),coalesce(p_occurred_at,now())
  ) on conflict do nothing returning activity_id into v_id;
  return v_id;
end $$;
revoke all on function english.log_learning_activity(uuid,text,text,text,text,text,uuid,text,jsonb,timestamptz) from public,anon,authenticated;
grant execute on function english.log_learning_activity(uuid,text,text,text,text,text,uuid,text,jsonb,timestamptz) to service_role;

create or replace function english.upsert_learner_confusion(
  p_user_id uuid,p_primary_concept_id text,p_primary_question_id text,p_related_term text,
  p_related_question_id text default null,p_related_concept_id text default null,p_source_note_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer
set search_path to 'pg_catalog','english'
as $$
declare v_key text; v_id uuid; v_term text:=nullif(trim(coalesce(p_related_term,'')),'');
begin
  if p_user_id is null or nullif(trim(coalesce(p_primary_concept_id,'')),'') is null then return null; end if;
  v_key:=md5(lower(trim(p_primary_concept_id))||'|'||lower(coalesce(v_term,p_related_concept_id,p_related_question_id,'unspecified')));
  insert into english.learner_confusions(
    user_id,primary_concept_id,primary_question_id,related_concept_id,related_question_id,related_term,
    confusion_key,source_note_id,status,strength,opened_at,last_signal_at,resolved_at,metadata,updated_at
  ) values(
    p_user_id,p_primary_concept_id,p_primary_question_id,p_related_concept_id,p_related_question_id,v_term,
    v_key,p_source_note_id,'open',1,now(),now(),null,coalesce(p_metadata,'{}'::jsonb),now()
  )
  on conflict(user_id,confusion_key) do update set
    primary_question_id=coalesce(excluded.primary_question_id,english.learner_confusions.primary_question_id),
    related_concept_id=coalesce(excluded.related_concept_id,english.learner_confusions.related_concept_id),
    related_question_id=coalesce(excluded.related_question_id,english.learner_confusions.related_question_id),
    related_term=coalesce(excluded.related_term,english.learner_confusions.related_term),
    source_note_id=coalesce(excluded.source_note_id,english.learner_confusions.source_note_id),
    status=case when english.learner_confusions.status='resolved' then 'reopened' else 'open' end,
    strength=least(99,english.learner_confusions.strength+1),
    last_signal_at=now(),resolved_at=null,
    metadata=english.learner_confusions.metadata||excluded.metadata,
    updated_at=now()
  returning confusion_id into v_id;
  return v_id;
end $$;
revoke all on function english.upsert_learner_confusion(uuid,text,text,text,text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function english.upsert_learner_confusion(uuid,text,text,text,text,text,uuid,jsonb) to service_role;

create or replace function english.process_context_note_rule_based(p_user_id uuid,p_note_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','english','auth'
as $$
declare
  n english.learner_context_notes%rowtype;
  cid text; is_confusion boolean:=false; is_retention boolean:=false; is_rule boolean:=false; needs_ai boolean:=false;
  related_ids text[]:='{}'::text[]; related_words text[]:='{}'::text[]; rid text; rword text; rcid text;
  action_taken text:='none'; diagnosis_type text:='context_signal'; targeted_kind text:='need_learning';
begin
  select * into n from english.learner_context_notes where note_id=p_note_id and user_id=p_user_id for update;
  if not found then raise exception 'Context note not found'; end if;
  if n.processing_status='done' then return coalesce(n.diagnosis,'{}'::jsonb)||jsonb_build_object('ok',true,'already_processed',true); end if;
  update english.learner_context_notes set processing_status='processing' where note_id=p_note_id;
  select m.concept_id into cid from english.question_concept_mappings m where m.question_id=n.question_id;

  is_confusion:=lower(n.note) ~ '(confus|difference|same meaning|mix( |-|_)up|versus|(^|[^a-z])vs([^a-z]|$)|similar|cannot distinguish|can.t distinguish|problem (in|with))';
  is_retention:=lower(n.note) ~ '(forget|forgot|remember|recall|keep forgetting|not retain|retention)';
  is_rule:=lower(n.note) ~ '(rule|grammar|passive|active voice|narration|preposition|usage rule|structure)';

  select coalesce(array_agg(x.question_id),'{}'::text[]),coalesce(array_agg(x.word),'{}'::text[])
  into related_ids,related_words
  from (
    select q.question_id,trim(q.word) word
    from english.questions q
    left join english.question_concept_mappings qm on qm.question_id=q.question_id
    where q.active and q.question_id<>n.question_id and english.question_visible_to_user(p_user_id,q.question_id)
      and nullif(trim(coalesce(q.word,'')),'') is not null and char_length(trim(q.word))>=4
      and position(lower(trim(q.word)) in lower(n.note))>0
      and (cid is null or qm.concept_id is distinct from cid)
    order by char_length(trim(q.word)) desc,q.question_id limit 4
  ) x;

  if is_confusion then diagnosis_type:='confusion_pair'; targeted_kind:='confusion';
  elsif is_retention then diagnosis_type:='retention_problem'; targeted_kind:='retention_check';
  elsif is_rule then diagnosis_type:='rule_gap'; targeted_kind:='need_learning';
  else diagnosis_type:='context_signal'; targeted_kind:='need_learning'; end if;

  needs_ai:=(is_confusion and cardinality(related_ids)=0) or (not is_confusion and not is_retention and not is_rule);

  if cid is not null and (is_confusion or is_retention or is_rule) then
    perform english.route_to_targeted(p_user_id,n.question_id,'Learner Context',
      case diagnosis_type when 'confusion_pair' then 'Learner supplied a confusion/context signal'
        when 'retention_problem' then 'Learner reported a retention problem'
        when 'rule_gap' then 'Learner reported a rule/usage gap' else 'Learner context needs repair' end);
    update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'targeted_kind',targeted_kind,'source_note_id',p_note_id,'concept_id',cid
    ),updated_at=now() where user_id=p_user_id and question_id=n.question_id;
    action_taken:='targeted_mastery';
  end if;

  for rid,rword in select * from unnest(related_ids,related_words) loop
    select concept_id into rcid from english.question_concept_mappings where question_id=rid;
    perform english.route_to_targeted(p_user_id,rid,'Learner Context Related','Related item named in learner context note');
    update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'targeted_kind','confusion','source_note_id',p_note_id,'related_to_question',n.question_id
    ),updated_at=now() where user_id=p_user_id and question_id=rid;
    if cid is not null then
      perform english.upsert_learner_confusion(p_user_id,cid,n.question_id,rword,rid,rcid,p_note_id,
        jsonb_build_object('source','context','processor','deterministic_v2'));
    end if;
  end loop;

  if cid is not null then
    update english.question_state set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours')
    where user_id=p_user_id and question_id=n.question_id and not coalesce(mastered,false);
  end if;

  update english.learner_context_notes set
    processing_status='done',
    ai_status=case when needs_ai then 'queued' else 'not_needed' end,
    ai_error=null,
    diagnosis=jsonb_build_object(
      'type',diagnosis_type,'action',action_taken,'concept_id',cid,
      'related_question_ids',to_jsonb(related_ids),'related_terms',to_jsonb(related_words),
      'needs_ai',needs_ai,'processor','deterministic_v2'
    ),processed_at=now()
  where note_id=p_note_id;

  if action_taken='targeted_mastery' then
    perform english.log_learning_activity(p_user_id,'context_targeted','Context added to Targeted',
      case when cardinality(related_words)>0 then 'Confusion detected: '||coalesce((select string_agg(x,' ↔ ') from unnest(related_words) x),'related concepts')||' · focused repair queued'
           when diagnosis_type='retention_problem' then 'Retention problem detected · validation queued'
           when diagnosis_type='rule_gap' then 'Rule gap detected · focused repair queued'
           else 'Learning context routed for focused repair' end,
      n.question_id,cid,p_note_id,'targeted',jsonb_build_object('diagnosis',diagnosis_type,'related_terms',related_words),n.created_at);
  elsif needs_ai then
    perform english.log_learning_activity(p_user_id,'context_ai_queued','Context queued for background analysis',
      'Your note needs deeper interpretation; study can continue normally.',n.question_id,cid,p_note_id,null,
      jsonb_build_object('diagnosis',diagnosis_type),n.created_at);
  end if;

  if cid is not null then perform english.recompute_concept_evidence(p_user_id,cid); end if;
  return jsonb_build_object('ok',true,'note_id',p_note_id,'concept_id',cid,'action',action_taken,
    'related_question_ids',related_ids,'related_terms',related_words,'needs_ai',needs_ai);
exception when others then
  update english.learner_context_notes set processing_status='failed',ai_status='failed',ai_error=sqlerrm,
    diagnosis=jsonb_build_object('error',sqlerrm,'processor','deterministic_v2'),processed_at=now()
  where note_id=p_note_id and user_id=p_user_id;
  raise;
end $$;
revoke all on function english.process_context_note_rule_based(uuid,uuid) from public,anon,authenticated;
grant execute on function english.process_context_note_rule_based(uuid,uuid) to service_role;

create or replace function english.recompute_concept_evidence(p_user_id uuid,p_concept_id text)
returns void
language plpgsql security definer
set search_path to 'pg_catalog','english'
as $$
declare r record; v_guessed int:=0; v_confusions int:=0; score numeric:=0; state text:='unseen'; v_next timestamptz;
begin
  with raw as (
    select a.attempted_at occurred_at,a.correct,a.question_id,coalesce(nullif(a.module,''),'practice') variant,a.question_id evidence_key,null::text diagnosis
    from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id
    where a.user_id=p_user_id and m.concept_id=p_concept_id
    union all
    select e.occurred_at,e.correct,e.question_id,coalesce(nullif(e.variant,''),e.source) variant,coalesce(e.question_id,e.source_key) evidence_key,e.metadata->>'diagnosis' diagnosis
    from english.concept_evidence_events e where e.user_id=p_user_id and e.concept_id=p_concept_id
  ), ordered as (select raw.*,lag(occurred_at) over(order by occurred_at,evidence_key) prev_at from raw)
  select count(*)::int attempts,count(*) filter(where correct is true)::int correct,count(*) filter(where correct is false)::int wrong,
    count(distinct evidence_key)::int distinct_questions,count(distinct variant)::int distinct_variants,
    count(*) filter(where correct is true and lower(variant) ~ '(target|sprint|fast|transfer)')::int transfer_successes,
    count(*) filter(where correct is true and prev_at is not null and occurred_at-prev_at>=interval '20 hours')::int delayed_successes,
    count(*) filter(where correct is false and occurred_at>=now()-interval '7 days')::int recent_failures,
    count(*) filter(where lower(coalesce(diagnosis,''))='confusion')::int event_confusions,max(occurred_at) last_attempt_at
  into r from ordered;

  select count(*)::int into v_guessed from english.learner_confidence_signals g
  join english.question_concept_mappings m on m.question_id=g.question_id
  where g.user_id=p_user_id and m.concept_id=p_concept_id and g.signal='guessed' and g.resolved_at is null;

  select count(*)::int into v_confusions from english.learner_confusions c
  where c.user_id=p_user_id and c.status<>'resolved'
    and (c.primary_concept_id=p_concept_id or c.related_concept_id=p_concept_id);
  v_confusions:=v_confusions+coalesce(r.event_confusions,0);

  score:=greatest(0,least(100,
      least(45,coalesce(r.correct,0)*7)+least(20,coalesce(r.distinct_questions,0)*7)
    + least(15,coalesce(r.delayed_successes,0)*7.5)+least(12,coalesce(r.transfer_successes,0)*6)
    - least(30,coalesce(r.recent_failures,0)*12)-least(20,coalesce(v_guessed,0)*5)-least(20,v_confusions*7)
  ));
  state:=case
    when coalesce(r.attempts,0)=0 then 'unseen'
    when coalesce(r.recent_failures,0)>=2 and score<55 then 'weak'
    when (coalesce(r.recent_failures,0)>0 or v_confusions>0 or v_guessed>0) and score>=55 then 'retention_risk'
    when score>=82 and coalesce(r.delayed_successes,0)>=1 and coalesce(r.distinct_questions,0)>=2 and coalesce(r.transfer_successes,0)>=1 then 'exam_ready'
    when score>=60 and coalesce(r.distinct_questions,0)>=2 then 'secure'
    else 'seen' end;
  v_next:=case state when 'weak' then coalesce(r.last_attempt_at,now())+interval '8 hours'
    when 'retention_risk' then least(coalesce(r.last_attempt_at,now())+interval '1 day',now()+interval '12 hours')
    when 'seen' then coalesce(r.last_attempt_at,now())+interval '2 days'
    when 'secure' then coalesce(r.last_attempt_at,now())+interval '6 days'
    when 'exam_ready' then coalesce(r.last_attempt_at,now())+interval '12 days' else null end;

  insert into english.concept_evidence(user_id,concept_id,attempts,correct,wrong,guessed,distinct_questions,distinct_variants,
    transfer_successes,delayed_successes,recent_failures,confusion_count,confidence_score,coverage_state,next_review,last_attempt_at,updated_at)
  values(p_user_id,p_concept_id,coalesce(r.attempts,0),coalesce(r.correct,0),coalesce(r.wrong,0),v_guessed,
    coalesce(r.distinct_questions,0),coalesce(r.distinct_variants,0),coalesce(r.transfer_successes,0),coalesce(r.delayed_successes,0),
    coalesce(r.recent_failures,0),v_confusions,score,state,v_next,r.last_attempt_at,now())
  on conflict(user_id,concept_id) do update set attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,
    guessed=excluded.guessed,distinct_questions=excluded.distinct_questions,distinct_variants=excluded.distinct_variants,
    transfer_successes=excluded.transfer_successes,delayed_successes=excluded.delayed_successes,recent_failures=excluded.recent_failures,
    confusion_count=excluded.confusion_count,confidence_score=excluded.confidence_score,coverage_state=excluded.coverage_state,
    next_review=excluded.next_review,last_attempt_at=excluded.last_attempt_at,updated_at=now();
end $$;

create or replace function english.reconcile_learning_signals_after_attempt()
returns trigger
language plpgsql security definer
set search_path to 'pg_catalog','english'
as $$
declare cid text; c record; correct_q int; wrong_q int; first_correct timestamptz; last_correct timestamptz; previous_status text; r record; clean_q int; clean_wrong int; clean_first timestamptz; clean_last timestamptz;
begin
  select concept_id into cid from english.question_concept_mappings where question_id=new.question_id;
  if cid is null then return new; end if;

  if coalesce(new.correct,false) then
    update english.learner_confidence_signals g set resolved_at=new.attempted_at,resolution_attempt_id=new.attempt_id
    where g.user_id=new.user_id and g.signal='guessed' and g.resolved_at is null and g.created_at<new.attempted_at
      and g.question_id<>new.question_id
      and exists(select 1 from english.question_concept_mappings m where m.question_id=g.question_id and m.concept_id=cid);
  end if;

  for c in select * from english.learner_confusions
    where user_id=new.user_id and (primary_concept_id=cid or related_concept_id=cid)
  loop
    previous_status:=c.status;
    select count(distinct a.question_id) filter(where a.correct)::int,
      count(*) filter(where not a.correct)::int,
      min(a.attempted_at) filter(where a.correct),max(a.attempted_at) filter(where a.correct)
    into correct_q,wrong_q,first_correct,last_correct
    from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id
    where a.user_id=new.user_id and a.attempted_at>=c.last_signal_at
      and (m.concept_id=c.primary_concept_id or (c.related_concept_id is not null and m.concept_id=c.related_concept_id));

    if coalesce(wrong_q,0)>0 then
      update english.learner_confusions set status=case when status='resolved' then 'reopened' else 'open' end,
        strength=least(99,strength+1),resolved_at=null,last_validation_at=new.attempted_at,updated_at=now()
      where confusion_id=c.confusion_id;
    elsif coalesce(correct_q,0)>=2 and first_correct is not null and last_correct-first_correct>=interval '20 hours' then
      update english.learner_confusions set status='resolved',resolved_at=new.attempted_at,last_validation_at=new.attempted_at,updated_at=now()
      where confusion_id=c.confusion_id;
      if previous_status<>'resolved' then
        perform english.log_learning_activity(new.user_id,'confusion_resolved','Confusion resolved',
          coalesce(nullif(c.related_term,''),'Confusion pair')||' · fresh and spaced validation passed',new.question_id,c.primary_concept_id,c.source_note_id,'targeted',
          jsonb_build_object('confusion_id',c.confusion_id),new.attempted_at);
      end if;
    elsif coalesce(correct_q,0)>=2 then
      update english.learner_confusions set status='improving',last_validation_at=new.attempted_at,updated_at=now()
      where confusion_id=c.confusion_id;
    elsif coalesce(correct_q,0)>=1 then
      update english.learner_confusions set status='testing',last_validation_at=new.attempted_at,updated_at=now()
      where confusion_id=c.confusion_id;
    end if;
  end loop;

  if coalesce(new.correct,false) then
    for r in select lr.* from english.learning_route_state lr
      join english.question_concept_mappings m on m.question_id=lr.question_id
      where lr.user_id=new.user_id and lr.route='targeted' and m.concept_id=cid
    loop
      select count(distinct a.question_id) filter(where a.correct)::int,count(*) filter(where not a.correct)::int,
        min(a.attempted_at) filter(where a.correct),max(a.attempted_at) filter(where a.correct)
      into clean_q,clean_wrong,clean_first,clean_last
      from english.attempts a join english.question_concept_mappings am on am.question_id=a.question_id
      where a.user_id=new.user_id and am.concept_id=cid and a.attempted_at>=coalesce(r.targeted_at,'epoch'::timestamptz);

      if coalesce(clean_wrong,0)=0 and coalesce(clean_q,0)>=2 and clean_first is not null and clean_last-clean_first>=interval '20 hours'
         and not exists(select 1 from english.learner_confusions c2 where c2.user_id=new.user_id and c2.status<>'resolved' and (c2.primary_concept_id=cid or c2.related_concept_id=cid))
         and not exists(select 1 from english.learner_confidence_signals g join english.question_concept_mappings gm on gm.question_id=g.question_id where g.user_id=new.user_id and gm.concept_id=cid and g.signal='guessed' and g.resolved_at is null)
      then
        perform english.route_to_fast_track(new.user_id,r.question_id,'Recovered Targeted','Targeted concept recovered with fresh transfer + spaced validation',true);
        update english.learning_route_state set targeted_recovered_at=new.attempted_at where user_id=new.user_id and question_id=r.question_id;
      elsif coalesce(clean_wrong,0)=0 and coalesce(clean_q,0)>=2 then
        update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('targeted_kind','retention_check'),
          last_route_reason='Fresh transfer passed — spaced retention confirmation pending',updated_at=now()
        where user_id=new.user_id and question_id=r.question_id and route='targeted';
      end if;
    end loop;
  end if;

  perform english.recompute_concept_evidence(new.user_id,cid);
  return new;
end $$;
drop trigger if exists zz_english_signal_reconciliation on english.attempts;
create trigger zz_english_signal_reconciliation after insert on english.attempts
for each row execute function english.reconcile_learning_signals_after_attempt();

create or replace function english.english_record_guess(p_question_id text,p_attempt_id text default null)
returns jsonb language plpgsql set search_path to 'pg_catalog','english'
as $$
declare uid uuid:=(select auth.uid()); cid text; aid text:=nullif(trim(coalesce(p_attempt_id,'')),''); inserted boolean:=false; alt_exists boolean:=false;
begin
 if uid is null then raise exception 'authentication required'; end if;
 if not exists(select 1 from english.questions q where q.question_id=p_question_id) then raise exception 'question not found'; end if;
 if aid is null then select a.attempt_id into aid from english.attempts a where a.user_id=uid and a.question_id=p_question_id order by a.attempted_at desc,a.created_at desc limit 1; end if;
 select m.concept_id into cid from english.question_concept_mappings m where m.question_id=p_question_id;
 if aid is not null then
   insert into english.learner_confidence_signals(user_id,question_id,attempt_id,signal) values(uid,p_question_id,aid,'guessed')
   on conflict(user_id,question_id,attempt_id,signal) where attempt_id is not null do nothing; get diagnostics inserted=row_count;
 else
   if not exists(select 1 from english.learner_confidence_signals g where g.user_id=uid and g.question_id=p_question_id and g.signal='guessed' and g.attempt_id is null and g.created_at>now()-interval '10 minutes') then
     insert into english.learner_confidence_signals(user_id,question_id,attempt_id,signal) values(uid,p_question_id,null,'guessed'); inserted:=true;
   end if;
 end if;
 if inserted then
   update english.question_state set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours') where user_id=uid and question_id=p_question_id and not coalesce(mastered,false);
   perform english.route_to_targeted(uid,p_question_id,'I Guessed','Confidence signal needs a fresh transfer check');
   update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('targeted_kind','transfer_check','source_attempt_id',aid),updated_at=now()
   where user_id=uid and question_id=p_question_id;
   perform english.log_learning_activity(uid,'guess_transfer','I Guessed → transfer check','Correctness is preserved; Central Intelligence will seek fresh validation.',p_question_id,cid,null,'targeted',jsonb_build_object('attempt_id',aid),now());
 end if;
 if cid is not null and inserted then perform english.recompute_concept_evidence(uid,cid); end if;
 select exists(select 1 from english.questions q join english.question_concept_mappings m on m.question_id=q.question_id where q.active and m.concept_id=cid and q.question_id<>p_question_id and english.question_visible_to_user(uid,q.question_id)) into alt_exists;
 return jsonb_build_object('ok',true,'signal','guessed','concept_id',cid,'attempt_id',aid,'recorded',inserted,'validation_due',case when inserted then now()+interval '12 hours' else null end,'alternate_available',alt_exists);
end $$;

create or replace function english.daily_reason_code(p_reason text) returns text language sql immutable
as $$ select case p_reason when 'Persistent Weak' then 'PW' when 'Targeted Repair' then 'TARGET' when 'Weak' then 'W' when 'Fragile' then 'FR'
  when 'Due Spaced Revision' then 'DUE' when 'Marked Review' then 'STAR' when 'Difficult Review' then 'DIFF'
  when 'Controlled New' then 'NEW' when 'Learning' then 'LEARN' else 'MIX' end; $$;
create or replace function english.daily_reason_base_score(p_reason text) returns integer language sql immutable
as $$ select case p_reason when 'Persistent Weak' then 1000 when 'Targeted Repair' then 950 when 'Weak' then 900 when 'Fragile' then 800
  when 'Due Spaced Revision' then 720 when 'Learning' then 660 when 'Marked Review' then 640 when 'Difficult Review' then 630
  when 'Controlled New' then 520 when 'Mixed Revision' then 300 else 0 end; $$;
create or replace function english.daily_quota(p_reason text,p_target integer) returns integer language sql immutable
as $$ select greatest(1,floor(p_target*case p_reason when 'Persistent Weak' then .20 when 'Targeted Repair' then .10 when 'Weak' then .16 when 'Fragile' then .14
  when 'Due Spaced Revision' then .15 when 'Learning' then .08 when 'Marked Review' then .05 when 'Difficult Review' then .05
  when 'Controlled New' then .10 when 'Mixed Revision' then .02 else 0 end)::int); $$;
create or replace function english.daily_cap(p_reason text,p_target integer) returns integer language sql immutable
as $$ select greatest(1,ceil(p_target*case p_reason when 'Persistent Weak' then .30 when 'Targeted Repair' then .15 when 'Weak' then .25 when 'Fragile' then .20
  when 'Due Spaced Revision' then .25 when 'Learning' then .15 when 'Marked Review' then .10 when 'Difficult Review' then .10
  when 'Controlled New' then .15 when 'Mixed Revision' then .05 else 1 end)::int); $$;

create or replace function english.daily_reason(p_user_id uuid,p_question_id text,p_batch_date date)
returns text language sql stable security definer set search_path to 'pg_catalog','english','auth'
as $$
with x as (
 select q,coalesce(s.attempts,0) attempts,coalesce(s.status,'New') state,s.next_review,coalesce(s.mastered,false) mastered,
        coalesce(s.last_marked,false) starred,coalesce(d.difficult,false) difficult,
        coalesce(r.route,'') route
 from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
 left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
 left join english.learning_route_state r on r.user_id=p_user_id and r.question_id=q.question_id
 where q.question_id=p_question_id
)
select case when not (q).active or mastered or route='fast_track' then ''
 when route='targeted' then 'Targeted Repair'
 when attempts=0 and english.is_genuine_bank_question(q) then 'Controlled New'
 when next_review is null or next_review>((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata') then ''
 when state='Persistent Weak' then 'Persistent Weak' when state='Weak' then 'Weak' when state='Fragile' then 'Fragile'
 when difficult then 'Difficult Review' when starred then 'Marked Review' when state='Learning' then 'Learning' else 'Due Spaced Revision' end from x;
$$;

create or replace function english.create_daily(p_user_id uuid,p_batch_date date,p_target integer)
returns integer language plpgsql security definer set search_path to 'pg_catalog','english','auth'
as $$
declare v_target integer:=greatest(1,least(120,coalesce(p_target,120))); v_reason text; v_take integer; v_inserted integer; v_count integer:=0;
begin
  create temporary table if not exists pg_temp.ep_daily_candidates(question_id text primary key,concept_key text,concept_id text,concept_state text,concept_confidence numeric,concept_next_review timestamptz,reason text,score numeric,priority integer,signals text[],snapshot jsonb) on commit drop;
  truncate pg_temp.ep_daily_candidates;
  insert into pg_temp.ep_daily_candidates(question_id,concept_key,concept_id,concept_state,concept_confidence,concept_next_review,reason,score,priority,signals,snapshot)
  select q.question_id,coalesce(cm.concept_id,q.question_id),cm.concept_id,coalesce(ce.coverage_state,'unseen'),coalesce(ce.confidence_score,0),ce.next_review,r.reason,
    english.daily_reason_base_score(r.reason)+coalesce(cp.penalty,0)*70
    +least(120,greatest(0,coalesce(floor(extract(epoch from (((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata')-s.next_review))/86400),0)))*12
    +case when coalesce(s.last_marked,false) then 12 else 0 end+case when coalesce(ds.difficult,false) then 10 else 0 end
    +case coalesce(ce.coverage_state,'unseen') when 'weak' then 220 when 'retention_risk' then 180 when 'seen' then 35 when 'unseen' then 25 when 'secure' then -25 when 'exam_ready' then -110 else 0 end
    +case when ce.next_review is not null and ce.next_review<=now() then 80 else 0 end
    +case coalesce(c.exam_relevance,'medium') when 'high' then 20 when 'low' then -15 else 0 end+random()*20,
    english.daily_reason_base_score(r.reason),english.daily_signal_codes(r.reason,coalesce(s.status,'New'),s.next_review is not null and s.next_review<=((p_batch_date::timestamp+interval '1 day - 1 millisecond') at time zone 'Asia/Kolkata'),coalesce(s.last_marked,false),coalesce(ds.difficult,false),coalesce(s.attempts,0)=0 and english.is_genuine_bank_question(q)),
    jsonb_build_object('selectedAt',now(),'batchDate',p_batch_date,'state',coalesce(s.status,'New'),'attempts',coalesce(s.attempts,0),'correct',coalesce(s.correct,0),'wrong',coalesce(s.wrong,0),'accuracy',coalesce(s.accuracy,0),'nextReview',s.next_review,'starred',coalesce(s.last_marked,false),'difficult',coalesce(ds.difficult,false),'category',english.learning_category(q.topic),'categoryPenalty',coalesce(cp.penalty,0),'conceptId',cm.concept_id,'conceptCoverage',coalesce(ce.coverage_state,'unseen'),'conceptConfidence',coalesce(ce.confidence_score,0),'conceptNextReview',ce.next_review,'targeted',r.reason='Targeted Repair')
  from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state ds on ds.user_id=p_user_id and ds.question_id=q.question_id left join english.question_concept_mappings cm on cm.question_id=q.question_id
  left join english.concepts c on c.concept_id=cm.concept_id left join english.concept_evidence ce on ce.user_id=p_user_id and ce.concept_id=cm.concept_id
  left join english.daily_category_penalties(p_user_id) cp on cp.category=english.learning_category(q.topic)
  cross join lateral(select english.daily_reason(p_user_id,q.question_id,p_batch_date) reason) r
  where q.active and english.question_visible_to_user(p_user_id,q.question_id) and not coalesce(s.mastered,false) and r.reason<>''
    and not(p_batch_date=((now() at time zone 'Asia/Kolkata')::date) and exists(select 1 from english.attempts a left join english.question_concept_mappings am on am.question_id=a.question_id where a.user_id=p_user_id and lower(coalesce(a.module,''))='daily' and (a.attempted_at at time zone 'Asia/Kolkata')::date=p_batch_date and coalesce(am.concept_id,a.question_id)=coalesce(cm.concept_id,q.question_id)));

  foreach v_reason in array array['Persistent Weak','Targeted Repair','Weak','Fragile','Due Spaced Revision','Learning','Marked Review','Difficult Review','Controlled New','Mixed Revision'] loop
    exit when v_count>=v_target; v_take:=least(english.daily_quota(v_reason,v_target),v_target-v_count);
    with base as(select c.*,row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_pick from pg_temp.ep_daily_candidates c where c.reason=v_reason and not exists(select 1 from english.daily_current d left join english.question_concept_mappings dm on dm.question_id=d.question_id where d.user_id=p_user_id and coalesce(dm.concept_id,d.question_id)=c.concept_key)),
    pick as(select * from base where concept_pick=1 order by score desc limit v_take)
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,p.question_id,v_count+row_number() over(order by p.score desc)::int,round(p.score)::int,p.reason,p_batch_date,'New',q.topic,coalesce(p.concept_id,q.concept_id),p.signals,p.snapshot from pick p join english.questions q on q.question_id=p.question_id order by p.score desc;
    get diagnostics v_inserted=row_count; v_count:=v_count+v_inserted;
  end loop;
  if v_count<v_target then
    with existing as(select reason,count(*) n from english.daily_current where user_id=p_user_id and quiz_date=p_batch_date group by reason),
    ranked as(select c.*,row_number() over(partition by c.reason order by c.score desc) reason_rn,row_number() over(partition by c.concept_key order by c.score desc,c.question_id) concept_rn from pg_temp.ep_daily_candidates c where not exists(select 1 from english.daily_current d left join english.question_concept_mappings dm on dm.question_id=d.question_id where d.user_id=p_user_id and coalesce(dm.concept_id,d.question_id)=c.concept_key)),
    eligible as(select r.* from ranked r left join existing e on e.reason=r.reason where r.concept_rn=1 and r.reason_rn<=greatest(0,english.daily_cap(r.reason,v_target)-coalesce(e.n,0)) order by r.score desc limit(v_target-v_count))
    insert into english.daily_current(user_id,question_id,sequence,priority,reason,quiz_date,status,topic,concept_id,selection_signals,selection_snapshot)
    select p_user_id,e.question_id,v_count+row_number() over(order by e.score desc)::int,round(e.score)::int,e.reason,p_batch_date,'New',q.topic,coalesce(e.concept_id,q.concept_id),e.signals,e.snapshot from eligible e join english.questions q on q.question_id=e.question_id order by e.score desc;
    get diagnostics v_inserted=row_count; v_count:=v_count+v_inserted;
  end if;
  return v_count;
end $$;

create or replace function public.english_get_targeted_mastery()
returns jsonb language sql stable security definer set search_path to 'pg_catalog','public','english','auth'
as $$
with uid as(select auth.uid() id), targeted as(
 select r.*,m.concept_id,coalesce(c.name,q.word,q.question_id) concept_name,coalesce(c.skill_family,q.topic,'English') skill_family,
   coalesce(ce.coverage_state,'unseen') concept_state,coalesce(ce.confidence_score,0) confidence,ce.next_review,
   case when coalesce(r.metadata->>'targeted_kind','')='confusion' or 'Learner Context'=any(coalesce(r.origins,'{}'::text[])) or 'Learner Context Related'=any(coalesce(r.origins,'{}'::text[])) then 'confusion'
        when coalesce(r.metadata->>'targeted_kind','')='transfer_check' or 'I Guessed'=any(coalesce(r.origins,'{}'::text[])) or 'AI Transfer'=any(coalesce(r.origins,'{}'::text[])) then 'transfer_check'
        when coalesce(r.metadata->>'targeted_kind','')='retention_check' then 'retention_check' else 'need_learning' end kind
 from uid join english.learning_route_state r on r.user_id=uid.id and r.route='targeted'
 join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid.id,q.question_id)
 left join english.question_concept_mappings m on m.question_id=q.question_id left join english.concepts c on c.concept_id=m.concept_id
 left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id
), dedup as(select t.*,row_number() over(partition by coalesce(t.concept_id,t.question_id) order by case t.kind when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 when 'retention_check' then 4 else 5 end,t.updated_at desc) rn from targeted t), base as(select * from dedup where rn=1),
conf as(
 select cf.confusion_id,cf.status,cf.strength,cf.primary_concept_id,cf.related_concept_id,cf.primary_question_id,cf.related_question_id,cf.related_term,cf.opened_at,cf.last_signal_at,cf.resolved_at,
   coalesce(c1.name,q1.word,cf.primary_concept_id) primary_name,coalesce(c2.name,q2.word,cf.related_term,cf.related_concept_id,'Related concept') related_name,
   left(coalesce(n.note,''),180) note
 from uid join english.learner_confusions cf on cf.user_id=uid.id
 left join english.concepts c1 on c1.concept_id=cf.primary_concept_id left join english.concepts c2 on c2.concept_id=cf.related_concept_id
 left join english.questions q1 on q1.question_id=cf.primary_question_id left join english.questions q2 on q2.question_id=cf.related_question_id
 left join english.learner_context_notes n on n.note_id=cf.source_note_id
), recovered as(
 select r.question_id,m.concept_id,coalesce(c.name,q.word,r.question_id) concept_name,r.targeted_recovered_at
 from uid join english.learning_route_state r on r.user_id=uid.id and r.targeted_recovered_at is not null
 join english.questions q on q.question_id=r.question_id left join english.question_concept_mappings m on m.question_id=q.question_id left join english.concepts c on c.concept_id=m.concept_id
 order by r.targeted_recovered_at desc limit 20
)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'summary',jsonb_build_object('active',(select count(*) from base),'dueNow',(select count(*) from base where next_review is null or next_review<=now()),
   'confusions',(select count(*) from conf where status<>'resolved'),'needLearning',(select count(*) from base where kind='need_learning'),
   'transferChecks',(select count(*) from base where kind='transfer_check'),'retentionChecks',(select count(*) from base where kind='retention_check'),
   'recovered',(select count(*) from conf where status='resolved')+(select count(*) from recovered)),
 'confusions',coalesce((select jsonb_agg(jsonb_build_object('confusionId',confusion_id,'status',status,'strength',strength,'primaryConceptId',primary_concept_id,'relatedConceptId',related_concept_id,'primaryQuestionId',primary_question_id,'relatedQuestionId',related_question_id,'primaryName',primary_name,'relatedName',related_name,'note',note,'openedAt',opened_at,'lastSignalAt',last_signal_at,'resolvedAt',resolved_at) order by case status when 'reopened' then 1 when 'open' then 2 when 'testing' then 3 when 'improving' then 4 else 5 end,last_signal_at desc) from conf where status<>'resolved'),'[]'::jsonb),
 'needLearning',coalesce((select jsonb_agg(jsonb_build_object('questionId',question_id,'conceptId',concept_id,'name',concept_name,'skillFamily',skill_family,'state',concept_state,'confidence',confidence,'reason',last_route_reason,'nextReview',next_review) order by updated_at desc) from(select * from base where kind='need_learning' order by updated_at desc limit 24)x),'[]'::jsonb),
 'transferChecks',coalesce((select jsonb_agg(jsonb_build_object('questionId',question_id,'conceptId',concept_id,'name',concept_name,'state',concept_state,'confidence',confidence,'reason',last_route_reason,'nextReview',next_review) order by updated_at desc) from(select * from base where kind='transfer_check' order by updated_at desc limit 24)x),'[]'::jsonb),
 'retentionChecks',coalesce((select jsonb_agg(jsonb_build_object('questionId',question_id,'conceptId',concept_id,'name',concept_name,'state',concept_state,'confidence',confidence,'reason',last_route_reason,'nextReview',next_review) order by coalesce(next_review,'epoch'::timestamptz)) from(select * from base where kind='retention_check' order by coalesce(next_review,'epoch'::timestamptz) limit 24)x),'[]'::jsonb),
 'recovered',coalesce((select jsonb_agg(to_jsonb(x) order by x.at desc) from(
    select primary_concept_id concept_id,primary_name name,resolved_at at,'confusion' source from conf where status='resolved' and resolved_at is not null
    union all select concept_id,concept_name,targeted_recovered_at,'targeted' from recovered
    order by at desc limit 24)x),'[]'::jsonb)
) end from uid;
$$;
revoke all on function public.english_get_targeted_mastery() from public,anon;
grant execute on function public.english_get_targeted_mastery() to authenticated,service_role;

create or replace function public.english_get_targeted_batch(p_count integer default 15,p_kind text default null,p_confusion_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid(); n integer:=greatest(1,least(30,coalesce(p_count,15))); k text:=lower(nullif(trim(coalesce(p_kind,'')),'')); outv jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with focus as(
   select cf.* from english.learner_confusions cf where cf.user_id=uid and p_confusion_id is not null and cf.confusion_id=p_confusion_id
 ), routed as(
   select r.question_id,m.concept_id,r.metadata,r.origins,r.last_route_reason,r.updated_at,ce.coverage_state,ce.confidence_score,ce.next_review,
     case when coalesce(r.metadata->>'targeted_kind','')='confusion' or 'Learner Context'=any(coalesce(r.origins,'{}'::text[])) or 'Learner Context Related'=any(coalesce(r.origins,'{}'::text[])) then 'confusion'
          when coalesce(r.metadata->>'targeted_kind','')='transfer_check' or 'I Guessed'=any(coalesce(r.origins,'{}'::text[])) or 'AI Transfer'=any(coalesce(r.origins,'{}'::text[])) then 'transfer_check'
          when coalesce(r.metadata->>'targeted_kind','')='retention_check' then 'retention_check' else 'need_learning' end kind
   from english.learning_route_state r join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid,q.question_id)
   left join english.question_concept_mappings m on m.question_id=r.question_id left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=m.concept_id
   where r.user_id=uid and r.route='targeted'
 ), filtered as(
   select x.* from routed x where
     (p_confusion_id is null or exists(select 1 from focus f where x.concept_id in(f.primary_concept_id,f.related_concept_id) or x.question_id in(f.primary_question_id,f.related_question_id)))
     and (k is null or x.kind=k)
 ), delivery as(
   select f.*,coalesce(alt.question_id,f.question_id) delivery_question_id,
     row_number() over(partition by coalesce(f.concept_id,f.question_id) order by
       case f.kind when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 when 'retention_check' then 4 else 5 end,
       coalesce(f.next_review,'epoch'::timestamptz),f.updated_at desc) concept_pick
   from filtered f
   left join lateral(
     select q2.question_id from english.questions q2 join english.question_concept_mappings m2 on m2.question_id=q2.question_id
     left join english.question_state s2 on s2.user_id=uid and s2.question_id=q2.question_id
     where f.kind in('transfer_check','confusion') and f.concept_id is not null and m2.concept_id=f.concept_id and q2.question_id<>f.question_id
       and q2.active and english.question_visible_to_user(uid,q2.question_id) and not coalesce(s2.mastered,false)
     order by coalesce(s2.last_attempt,'epoch'::timestamptz),q2.question_id limit 1
   ) alt on true
 ), chosen as(
   select * from delivery where concept_pick=1 order by case kind when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 when 'retention_check' then 4 else 5 end,
     coalesce(next_review,'epoch'::timestamptz),updated_at desc limit n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,c.delivery_question_id)||jsonb_build_object(
   'learningRoute','targeted','targetedKind',c.kind,'targetedReason',c.last_route_reason,'sourceQuestionId',c.question_id,
   'conceptId',c.concept_id,'conceptCoverage',coalesce(c.coverage_state,'unseen'),'conceptConfidence',coalesce(c.confidence_score,0),'conceptNextReview',c.next_review
 ) order by case c.kind when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 when 'retention_check' then 4 else 5 end,c.updated_at desc),'[]'::jsonb) into outv from chosen c;
 return outv;
end $$;
revoke all on function public.english_get_targeted_batch(integer,text,uuid) from public,anon;
grant execute on function public.english_get_targeted_batch(integer,text,uuid) to authenticated,service_role;

create or replace function public.english_get_learning_activity_today()
returns jsonb language sql stable security definer set search_path to 'pg_catalog','public','english','auth'
as $$
with uid as(select auth.uid() id), rows as(
 select a.* from uid join english.learning_intelligence_activity a on a.user_id=uid.id
 where (a.occurred_at at time zone 'Asia/Kolkata')::date=(now() at time zone 'Asia/Kolkata')::date
 order by a.occurred_at desc limit 20
)
select case when (select id from uid) is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'count',(select count(*) from rows),'items',coalesce((select jsonb_agg(jsonb_build_object('id',activity_id,'type',activity_type,'title',title,'detail',detail,'questionId',question_id,'conceptId',concept_id,'route',route,'metadata',metadata,'at',occurred_at) order by occurred_at desc) from rows),'[]'::jsonb)
) end;
$$;
revoke all on function public.english_get_learning_activity_today() from public,anon;
grant execute on function public.english_get_learning_activity_today() to authenticated,service_role;

create or replace function public.english_get_learning_signal_summary()
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); outv jsonb;
begin
 if uid is null then raise exception 'authentication required'; end if;
 select jsonb_build_object(
   'context_total',(select count(*) from english.learner_context_notes where user_id=uid),
   'context_done',(select count(*) from english.learner_context_notes where user_id=uid and processing_status='done'),
   'context_pending',(select count(*) from english.learner_context_notes where user_id=uid and ai_status in('queued','processing')),
   'context_failed',(select count(*) from english.learner_context_notes where user_id=uid and (processing_status='failed' or ai_status='failed')),
   'guessed_total',(select count(*) from english.learner_confidence_signals where user_id=uid and signal='guessed'),
   'guessed_open',(select count(*) from english.learner_confidence_signals where user_id=uid and signal='guessed' and resolved_at is null),
   'confusions_open',(select count(*) from english.learner_confusions where user_id=uid and status<>'resolved'),
   'context_targeted',(select count(*) from english.learning_route_state where user_id=uid and route='targeted' and ('Learner Context'=any(coalesce(origins,'{}'::text[])) or 'Learner Context Related'=any(coalesce(origins,'{}'::text[])))),
   'recent_context',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) from(select note_id,question_id,left(note,160) note,processing_status,ai_status,diagnosis,created_at from english.learner_context_notes where user_id=uid order by created_at desc limit 6)x),
   'today_activity',public.english_get_learning_activity_today()
 ) into outv; return outv;
end $$;
revoke all on function public.english_get_learning_signal_summary() from public,anon;
grant execute on function public.english_get_learning_signal_summary() to authenticated,service_role;

create or replace function public.english_get_home_snapshot()
returns jsonb language sql stable security definer set search_path to 'pg_catalog','public','english','auth'
as $$
with uid as(select auth.uid() id),summary as(select public.english_dashboard_summary() value),
saved as(select count(*) filter(where not mastered)::int eligible,count(*) filter(where not mastered and due)::int due from uid cross join lateral english.saved_revision_candidates(uid.id)),
starred as(select count(*) filter(where starred and not mastered)::int focus,count(*) filter(where difficult and starred and not mastered)::int difficult from uid cross join lateral english.starred_manual_index(uid.id)),
bank as(select count(*)::int total,count(*) filter(where coalesce(s.attempts,0)>0)::int exposed from uid join english.questions q on uid.id is not null and english.is_genuine_bank_question(q) left join english.question_state s on s.user_id=uid.id and s.question_id=q.question_id),
phrasal as(select count(*)::int today_count from uid join english.questions q on uid.id is not null and q.active and english.question_visible_to_user(uid.id,q.question_id) and q.source_id='PHRASAL_DAILY_'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYYMMDD') and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')),
hindu as(select coalesce(jsonb_agg(jsonb_build_object('id',h.hindu_id) order by h.hindu_id),'[]'::jsonb) rows from uid join english.hindu_words h on uid.id is not null and h.active and h.word_date=(now() at time zone 'Asia/Kolkata')::date),
targeted as(select count(*)::int active,count(*) filter(where coalesce(ce.next_review,now())<=now())::int due_now from uid join english.learning_route_state r on r.user_id=uid.id and r.route='targeted' left join english.question_concept_mappings m on m.question_id=r.question_id left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,'studyDay',greatest(1,((now() at time zone 'Asia/Kolkata')::date-date '2026-08-14')+1),'summary',summary.value,
 'intelligence',jsonb_build_object('daily',jsonb_build_object('actionableRemaining',coalesce((summary.value->>'daily_remaining')::int,0),'suppressed',coalesce((summary.value->>'daily_suppressed')::int,0)),'coreCoverage',jsonb_build_object('percent',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end)),
 'phrasal',jsonb_build_object('today',jsonb_build_object('ready',phrasal.today_count>0,'count',phrasal.today_count),'stats',jsonb_build_object('due',0)),
 'bank',jsonb_build_object('total',bank.total,'exposed',bank.exposed,'coverage',case when bank.total>0 then round(bank.exposed*100.0/bank.total,1) else 0 end),
 'targeted',jsonb_build_object('active',targeted.active,'due',targeted.due_now),
 'saved',jsonb_build_object('stats',jsonb_build_object('saved',saved.eligible,'eligible',saved.eligible,'due',saved.due)),
 'starred',jsonb_build_object('stats',jsonb_build_object('focus',starred.focus,'manualDifficult',starred.difficult,'difficult',starred.difficult)),'hindu',hindu.rows
) end from uid cross join summary cross join saved cross join starred cross join bank cross join phrasal cross join hindu cross join targeted;
$$;

-- Backfill existing deterministic context into the new confusion/activity model without changing learner answers.
insert into english.learner_confusions(user_id,primary_concept_id,primary_question_id,related_concept_id,related_question_id,related_term,confusion_key,source_note_id,status,strength,opened_at,last_signal_at,metadata,updated_at)
select n.user_id,m.concept_id,n.question_id,rm.concept_id,rid,term,md5(lower(m.concept_id)||'|'||lower(term)),n.note_id,'open',1,n.created_at,n.created_at,jsonb_build_object('source','context','processor','backfill_v2'),now()
from english.learner_context_notes n join english.question_concept_mappings m on m.question_id=n.question_id
cross join lateral jsonb_array_elements_text(coalesce(n.diagnosis->'related_terms','[]'::jsonb)) term
left join lateral(select q.question_id rid from english.questions q where q.active and lower(trim(coalesce(q.word,'')))=lower(trim(term)) order by q.question_id limit 1) qx on true
left join english.question_concept_mappings rm on rm.question_id=qx.rid
where lower(coalesce(n.diagnosis->>'type',''))='confusion_pair' and nullif(trim(term),'') is not null
on conflict(user_id,confusion_key) do update set last_signal_at=greatest(english.learner_confusions.last_signal_at,excluded.last_signal_at),updated_at=now();

insert into english.learning_intelligence_activity(user_id,activity_type,title,detail,question_id,concept_id,source_note_id,route,metadata,occurred_at)
select n.user_id,'context_targeted','Context added to Targeted',
 case when jsonb_array_length(coalesce(n.diagnosis->'related_terms','[]'::jsonb))>0 then 'Confusion detected · added to focused Targeted repair' else 'Learning context routed for focused repair' end,
 n.question_id,m.concept_id,n.note_id,'targeted',jsonb_build_object('diagnosis',n.diagnosis->>'type','backfill',true),n.created_at
from english.learner_context_notes n left join english.question_concept_mappings m on m.question_id=n.question_id
where n.processing_status='done' and lower(coalesce(n.diagnosis->>'action',''))='targeted_mastery'
on conflict do nothing;

update english.learner_context_notes set ai_status=case when coalesce((diagnosis->>'needs_ai')::boolean,false) then 'queued' else 'not_needed' end
where processing_status='done';

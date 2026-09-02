-- English V2 background intelligence worker.
-- Deterministic/bank-first remains authoritative. Luna is background-only and never blocks the learner.
-- Automatic transfer generation is bounded to explicit confusion / transfer-check signals.

create table if not exists english.context_ai_runtime_guard(
  singleton boolean primary key default true check(singleton),
  token text not null default gen_random_uuid()::text,
  created_at timestamptz not null default now(),
  rotated_at timestamptz not null default now()
);
insert into english.context_ai_runtime_guard(singleton) values(true) on conflict(singleton) do nothing;
alter table english.context_ai_runtime_guard enable row level security;
revoke all on english.context_ai_runtime_guard from public,anon,authenticated;
grant select,update on english.context_ai_runtime_guard to service_role;

create table if not exists english.targeted_transfer_jobs(
  job_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  concept_id text not null references english.concepts(concept_id) on delete cascade,
  source_question_id text not null references english.questions(question_id) on delete cascade,
  source_note_id uuid references english.learner_context_notes(note_id) on delete set null,
  related_term text,
  reason text not null default 'missing_transfer',
  status text not null default 'queued' check(status in ('queued','processing','done','failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz,
  last_error text,
  generated_question_id text references english.questions(question_id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(user_id,concept_id,source_question_id)
);
alter table english.targeted_transfer_jobs enable row level security;
revoke all on english.targeted_transfer_jobs from public,anon,authenticated;
grant select,insert,update,delete on english.targeted_transfer_jobs to service_role;
create index if not exists english_transfer_jobs_status_idx on english.targeted_transfer_jobs(status,next_attempt_at,updated_at);
create index if not exists english_transfer_jobs_user_idx on english.targeted_transfer_jobs(user_id,created_at desc);

-- Generated Targeted items are user-owned just like saved-generated items.
alter table english.question_origins drop constraint if exists question_origins_origin_kind_check;
alter table english.question_origins add constraint question_origins_origin_kind_check
  check(origin_kind=any(array['core','saved_generated','targeted_generated','hindu_generated','demand_generated','other_generated']::text[]));
alter table english.question_origins drop constraint if exists english_question_origins_saved_owner_ck;
alter table english.question_origins drop constraint if exists english_question_origins_owner_ck;
alter table english.question_origins add constraint english_question_origins_owner_ck
  check(origin_kind not in ('saved_generated','targeted_generated') or owner_user_id is not null);

create or replace function english.question_visible_to_user(p_user_id uuid,p_question_id text)
returns boolean language sql stable security definer set search_path to 'pg_catalog','english','auth'
as $$
select case
  when p_user_id is null then false
  when o.question_id is null then true
  when o.origin_kind in ('saved_generated','targeted_generated') then o.owner_user_id=p_user_id
  else true
end
from (select 1) x left join english.question_origins o on o.question_id=p_question_id;
$$;

create or replace function english.context_worker_authorized(p_token text)
returns boolean language sql stable security definer set search_path to 'pg_catalog','english'
as $$ select exists(select 1 from english.context_ai_runtime_guard where singleton and token=p_token); $$;
revoke all on function english.context_worker_authorized(text) from public,anon,authenticated;
grant execute on function english.context_worker_authorized(text) to service_role;

create or replace function english.ensure_transfer_generation_job(
  p_user_id uuid,p_concept_id text,p_source_question_id text,p_source_note_id uuid default null,
  p_related_term text default null,p_reason text default 'missing_transfer'
) returns uuid language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare v_job uuid;
begin
  if p_user_id is null or p_concept_id is null or p_source_question_id is null then return null; end if;
  if exists(
    select 1
    from english.questions q
    join english.question_concept_mappings m on m.question_id=q.question_id
    where q.active and m.concept_id=p_concept_id and q.question_id<>p_source_question_id
      and english.question_visible_to_user(p_user_id,q.question_id)
  ) then return null; end if;

  insert into english.targeted_transfer_jobs(
    user_id,concept_id,source_question_id,source_note_id,related_term,reason,status,metadata
  ) values(
    p_user_id,p_concept_id,p_source_question_id,p_source_note_id,nullif(trim(coalesce(p_related_term,'')),''),
    left(coalesce(nullif(trim(p_reason),''),'missing_transfer'),240),'queued',jsonb_build_object('bankFirstCheckedAt',now())
  )
  on conflict(user_id,concept_id,source_question_id) do update set
    source_note_id=coalesce(excluded.source_note_id,english.targeted_transfer_jobs.source_note_id),
    related_term=coalesce(excluded.related_term,english.targeted_transfer_jobs.related_term),
    reason=excluded.reason,
    status=case when english.targeted_transfer_jobs.status='failed' and english.targeted_transfer_jobs.attempts<3 then 'queued' else english.targeted_transfer_jobs.status end,
    next_attempt_at=case when english.targeted_transfer_jobs.status='failed' and english.targeted_transfer_jobs.attempts<3 then now() else english.targeted_transfer_jobs.next_attempt_at end,
    updated_at=now()
  returning job_id into v_job;
  return v_job;
end $$;
revoke all on function english.ensure_transfer_generation_job(uuid,text,text,uuid,text,text) from public,anon,authenticated;
grant execute on function english.ensure_transfer_generation_job(uuid,text,text,uuid,text,text) to service_role;

-- Deliberately excludes generic need_learning rows: this prevents AI generation flooding.
create or replace function english.enqueue_missing_targeted_transfers(p_limit integer default 8)
returns integer language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare r record; n integer:=0; j uuid;
begin
  for r in
    select lr.user_id,lr.question_id,m.concept_id,
      case when coalesce(lr.metadata->>'targeted_kind','')='confusion' then nullif(lr.metadata->>'source_note_id','')::uuid else null end source_note_id,
      case when coalesce(lr.metadata->>'targeted_kind','')='confusion' then 'Explicit confusion lacks an alternate transfer item'
           else 'I Guessed transfer validation lacks an alternate item' end reason
    from english.learning_route_state lr
    join english.question_concept_mappings m on m.question_id=lr.question_id
    where lr.route='targeted'
      and coalesce(lr.metadata->>'targeted_kind','') in ('confusion','transfer_check')
      and not exists(
        select 1 from english.questions q2
        join english.question_concept_mappings m2 on m2.question_id=q2.question_id
        where q2.active and m2.concept_id=m.concept_id and q2.question_id<>lr.question_id
          and english.question_visible_to_user(lr.user_id,q2.question_id)
      )
    order by case coalesce(lr.metadata->>'targeted_kind','') when 'confusion' then 1 else 2 end,lr.updated_at desc
    limit greatest(1,least(12,coalesce(p_limit,8)))
  loop
    j:=english.ensure_transfer_generation_job(r.user_id,r.concept_id,r.question_id,r.source_note_id,null,r.reason);
    if j is not null then n:=n+1; end if;
  end loop;
  return n;
end $$;
revoke all on function english.enqueue_missing_targeted_transfers(integer) from public,anon,authenticated;
grant execute on function english.enqueue_missing_targeted_transfers(integer) to service_role;

create or replace function english.context_claim(p_token text,p_limit integer default 6)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare outv jsonb;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  update english.learner_context_notes
  set ai_status='queued',ai_next_attempt_at=now(),ai_error='stale background processing recovered'
  where ai_status='processing' and ai_attempted_at<now()-interval '5 minutes' and ai_attempts<3;

  with pick as(
    select n.note_id
    from english.learner_context_notes n
    where n.processing_status='done' and n.ai_status='queued' and n.ai_attempts<3
      and (n.ai_next_attempt_at is null or n.ai_next_attempt_at<=now())
    order by n.created_at,n.note_id
    for update skip locked
    limit greatest(1,least(8,coalesce(p_limit,6)))
  ), upd as(
    update english.learner_context_notes n
    set ai_status='processing',ai_attempts=n.ai_attempts+1,ai_attempted_at=now(),ai_error=null
    from pick p where n.note_id=p.note_id
    returning n.*
  ), payload as(
    select u.note_id,u.user_id,u.question_id,u.note,u.context_snapshot,u.diagnosis,
      m.concept_id,c.name concept_name,c.skill_family,c.description concept_description,
      coalesce(ce.coverage_state,'unseen') coverage_state,coalesce(ce.confidence_score,0) confidence_score,
      coalesce(ce.attempts,0) concept_attempts,coalesce(ce.wrong,0) concept_wrong,coalesce(ce.guessed,0) open_guessed,
      q.word,q.topic,q.question,q.option_a,q.option_b,q.option_c,q.option_d,q.correct,q.explanation,q.question_type,
      (select count(*) from english.questions q2
       join english.question_concept_mappings m2 on m2.question_id=q2.question_id
       where q2.active and m2.concept_id=m.concept_id and english.question_visible_to_user(u.user_id,q2.question_id)) concept_question_count
    from upd u
    left join english.question_concept_mappings m on m.question_id=u.question_id
    left join english.concepts c on c.concept_id=m.concept_id
    left join english.concept_evidence ce on ce.user_id=u.user_id and ce.concept_id=m.concept_id
    join english.questions q on q.question_id=u.question_id
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
    'noteId',note_id,'userId',user_id,'questionId',question_id,'note',note,'contextSnapshot',context_snapshot,
    'currentDiagnosis',diagnosis,'conceptId',concept_id,'conceptName',concept_name,'skillFamily',skill_family,
    'conceptDescription',concept_description,'coverageState',coverage_state,'confidenceScore',confidence_score,
    'conceptAttempts',concept_attempts,'conceptWrong',concept_wrong,'openGuessed',open_guessed,'conceptQuestionCount',concept_question_count,
    'question',jsonb_build_object('word',word,'topic',topic,'text',question,'options',jsonb_build_array(option_a,option_b,option_c,option_d),
      'correctKey',correct,'explanation',explanation,'questionType',question_type)
  ) order by note_id),'[]'::jsonb)) into outv from payload;
  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end $$;

create or replace function public.english_context_claim(p_token text,p_limit integer default 6)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.context_claim(p_token,p_limit); $$;
revoke all on function public.english_context_claim(text,integer) from public,anon,authenticated;
grant execute on function public.english_context_claim(text,integer) to service_role;

create or replace function english.apply_context_ai_diagnosis(
  p_token text,p_note_id uuid,p_diagnosis jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare
  n english.learner_context_notes%rowtype;
  cid text; dtype text; action text; kind text; requires_transfer boolean;
  terms text[]:='{}'::text[]; term text; rid text; rcid text;
  matched integer:=0; job uuid; detail text;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into n from english.learner_context_notes where note_id=p_note_id for update;
  if not found then raise exception 'context note not found'; end if;
  if n.ai_status='done' then return jsonb_build_object('ok',true,'alreadyDone',true); end if;
  if n.ai_status<>'processing' then raise exception 'context note is not claimed'; end if;

  select concept_id into cid from english.question_concept_mappings where question_id=n.question_id;
  dtype:=lower(coalesce(p_diagnosis->>'diagnosis','no_action'));
  if dtype not in ('confusion_pair','retention_problem','lexical_interference','rule_gap','transfer_problem','no_action') then
    raise exception 'invalid context diagnosis';
  end if;
  action:=lower(coalesce(p_diagnosis->>'action','no_action'));
  requires_transfer:=coalesce((p_diagnosis->>'requiresTransfer')::boolean,false);
  select coalesce(array_agg(value),'{}'::text[])
  into terms from jsonb_array_elements_text(coalesce(p_diagnosis->'relatedTerms','[]'::jsonb));

  kind:=case
    when dtype in('confusion_pair','lexical_interference') then 'confusion'
    when dtype='retention_problem' then 'retention_check'
    when dtype='transfer_problem' or action='transfer_check' then 'transfer_check'
    when dtype='no_action' then null
    else 'need_learning'
  end;

  if cid is not null and dtype<>'no_action' then
    perform english.route_to_targeted(n.user_id,n.question_id,'Background Context AI',
      case kind
        when 'confusion' then 'Background analysis confirmed a learner confusion'
        when 'retention_check' then 'Background analysis confirmed a retention problem'
        when 'transfer_check' then 'Background analysis requested fresh transfer evidence'
        else 'Background analysis confirmed a focused learning gap'
      end);
    update english.learning_route_state
    set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'targeted_kind',kind,'source_note_id',p_note_id,'ai_diagnosis',dtype,'ai_model',p_model),updated_at=now()
    where user_id=n.user_id and question_id=n.question_id;
  end if;

  foreach term in array terms loop
    term:=nullif(trim(term),'');
    if term is null then continue; end if;
    rid:=null; rcid:=null;
    select q.question_id,m.concept_id into rid,rcid
    from english.questions q
    left join english.question_concept_mappings m on m.question_id=q.question_id
    where q.active and q.question_id<>n.question_id and english.question_visible_to_user(n.user_id,q.question_id)
      and (lower(trim(coalesce(q.word,'')))=lower(term) or lower(coalesce(q.question,'')) like '%'||lower(term)||'%')
      and (cid is null or m.concept_id is distinct from cid)
    order by case when lower(trim(coalesce(q.word,'')))=lower(term) then 0 else 1 end,q.question_id
    limit 1;

    if rid is not null then
      matched:=matched+1;
      perform english.route_to_targeted(n.user_id,rid,'Background Context AI Related','Related concept found in existing bank');
      update english.learning_route_state
      set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'targeted_kind','confusion','source_note_id',p_note_id,'related_to_question',n.question_id,'ai_model',p_model),updated_at=now()
      where user_id=n.user_id and question_id=rid;
    end if;
    if cid is not null and kind='confusion' then
      perform english.upsert_learner_confusion(n.user_id,cid,n.question_id,term,rid,rcid,p_note_id,
        jsonb_build_object('source','background_ai','model',p_model,'confidence',p_diagnosis->'confidence'));
    end if;
  end loop;

  if cid is not null and kind='confusion' and cardinality(terms)=0 then
    perform english.upsert_learner_confusion(n.user_id,cid,n.question_id,null,null,null,p_note_id,
      jsonb_build_object('source','background_ai','model',p_model,'confidence',p_diagnosis->'confidence'));
  end if;

  if cid is not null and (requires_transfer or kind='transfer_check') then
    job:=english.ensure_transfer_generation_job(
      n.user_id,cid,n.question_id,p_note_id,case when cardinality(terms)>0 then terms[1] else null end,
      'Background context analysis requested fresh transfer'
    );
  end if;

  update english.learner_context_notes
  set ai_status='done',ai_error=null,ai_next_attempt_at=null,processed_at=coalesce(processed_at,now()),
    diagnosis=coalesce(diagnosis,'{}'::jsonb)||jsonb_build_object(
      'type',dtype,'action',case when dtype='no_action' then 'no_action' else 'targeted_mastery' end,
      'related_terms',to_jsonb(terms),'needs_ai',false,'processor','luna_background','model',p_model,
      'confidence',p_diagnosis->'confidence','urgency',p_diagnosis->>'urgency','rationale',p_diagnosis->>'rationale',
      'requires_transfer',requires_transfer,'usage',coalesce(p_usage,'{}'::jsonb))
  where note_id=p_note_id;

  detail:=case
    when dtype='no_action' then 'Background analysis found no extra learning action needed.'
    when kind='confusion' and matched>0 then 'Confusion interpreted · existing bank items added to Targeted.'
    when kind='confusion' then 'Confusion interpreted · focused Targeted repair created.'
    when kind='retention_check' then 'Retention issue interpreted · spaced validation added to Targeted.'
    when kind='transfer_check' and job is not null then 'Fresh transfer evidence requested · generation queued.'
    when kind='transfer_check' then 'Fresh transfer evidence requested · existing bank evidence available.'
    else 'Learning gap interpreted · added to Targeted.'
  end;

  perform english.log_learning_activity(
    n.user_id,
    case when dtype='no_action' then 'context_ai_no_action' else 'context_ai_targeted' end,
    case when dtype='no_action' then 'Context analysed' else 'Background analysis → Targeted' end,
    detail,n.question_id,cid,p_note_id,case when dtype='no_action' then null else 'targeted' end,
    jsonb_build_object('diagnosis',dtype,'model',p_model,'transferJob',job),now()
  );
  if cid is not null then perform english.recompute_concept_evidence(n.user_id,cid); end if;
  return jsonb_build_object('ok',true,'diagnosis',dtype,'targetedKind',kind,'matchedBankItems',matched,'transferJob',job);
end $$;

create or replace function public.english_apply_context_ai_diagnosis(
  p_token text,p_note_id uuid,p_diagnosis jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
) returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.apply_context_ai_diagnosis(p_token,p_note_id,p_diagnosis,p_model,p_usage); $$;
revoke all on function public.english_apply_context_ai_diagnosis(text,uuid,jsonb,text,jsonb) from public,anon,authenticated;
grant execute on function public.english_apply_context_ai_diagnosis(text,uuid,jsonb,text,jsonb) to service_role;

create or replace function english.fail_context_ai(p_token text,p_note_id uuid,p_error text)
returns void language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare a integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select ai_attempts into a from english.learner_context_notes where note_id=p_note_id for update;
  update english.learner_context_notes
  set ai_status=case when coalesce(a,0)>=3 then 'failed' else 'queued' end,
      ai_next_attempt_at=case when coalesce(a,0)>=3 then null else now()+make_interval(mins=>least(30,greatest(1,coalesce(a,1))*5)) end,
      ai_error=left(coalesce(p_error,'background analysis failed'),1000)
  where note_id=p_note_id;
end $$;

create or replace function public.english_fail_context_ai(p_token text,p_note_id uuid,p_error text)
returns void language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.fail_context_ai(p_token,p_note_id,p_error); $$;
revoke all on function public.english_fail_context_ai(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_fail_context_ai(text,uuid,text) to service_role;

create or replace function english.transfer_claim(p_token text,p_limit integer default 1)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare outv jsonb;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  update english.targeted_transfer_jobs
  set status='queued',next_attempt_at=now(),last_error='stale generation recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts<3;

  with pick as(
    select job_id
    from english.targeted_transfer_jobs
    where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
    order by created_at,job_id
    for update skip locked
    limit greatest(1,least(2,coalesce(p_limit,1)))
  ), upd as(
    update english.targeted_transfer_jobs j
    set status='processing',attempts=j.attempts+1,updated_at=now(),last_error=null
    from pick p where j.job_id=p.job_id
    returning j.*
  ), payload as(
    select u.*,c.name concept_name,c.description concept_description,c.skill_family,c.exam_relevance,
      q.topic,q.word,q.question,q.option_a,q.option_b,q.option_c,q.option_d,q.correct,q.explanation,q.question_type,q.subtopic,
      coalesce(n.note,'') learner_note
    from upd u
    join english.concepts c on c.concept_id=u.concept_id
    join english.questions q on q.question_id=u.source_question_id
    left join english.learner_context_notes n on n.note_id=u.source_note_id
  )
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
    'jobId',job_id,'userId',user_id,'conceptId',concept_id,'conceptName',concept_name,'conceptDescription',concept_description,
    'skillFamily',skill_family,'examRelevance',exam_relevance,'sourceQuestionId',source_question_id,'sourceNoteId',source_note_id,
    'relatedTerm',related_term,'reason',reason,'learnerNote',learner_note,
    'sourceQuestion',jsonb_build_object('topic',topic,'word',word,'question',question,
      'options',jsonb_build_array(option_a,option_b,option_c,option_d),'correctKey',correct,'explanation',explanation,
      'questionType',question_type,'subtopic',subtopic)
  ) order by created_at),'[]'::jsonb)) into outv from payload;
  return coalesce(outv,jsonb_build_object('items','[]'::jsonb));
end $$;

create or replace function public.english_transfer_claim(p_token text,p_limit integer default 1)
returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.transfer_claim(p_token,p_limit); $$;
revoke all on function public.english_transfer_claim(text,integer) from public,anon,authenticated;
grant execute on function public.english_transfer_claim(text,integer) to service_role;

create or replace function english.apply_generated_transfer(
  p_token text,p_job_id uuid,p_item jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare
  j english.targeted_transfer_jobs%rowtype;
  src english.questions%rowtype;
  qid text; fam text; skill text;
  qa text:=trim(coalesce(p_item->>'optionA','')); qb text:=trim(coalesce(p_item->>'optionB',''));
  qc text:=trim(coalesce(p_item->>'optionC','')); qd text:=trim(coalesce(p_item->>'optionD',''));
  ckey text:=upper(trim(coalesce(p_item->>'correctKey','')));
  qtext text:=trim(coalesce(p_item->>'question',''));
  quality numeric:=coalesce((p_item->>'qualityScore')::numeric,0);
  ambiguous boolean:=coalesce((p_item->>'ambiguous')::boolean,true);
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select * into j from english.targeted_transfer_jobs where job_id=p_job_id for update;
  if not found then raise exception 'transfer job not found'; end if;
  if j.status='done' then return jsonb_build_object('ok',true,'alreadyDone',true,'questionId',j.generated_question_id); end if;
  if j.status<>'processing' then raise exception 'transfer job is not claimed'; end if;

  if char_length(qtext)<12 or char_length(qtext)>600 then raise exception 'invalid generated question length'; end if;
  if ckey not in ('A','B','C','D') then raise exception 'invalid generated correct key'; end if;
  if least(char_length(qa),char_length(qb),char_length(qc),char_length(qd))<1 then raise exception 'generated option missing'; end if;
  if (select count(distinct lower(v)) from unnest(array[qa,qb,qc,qd]) v)<>4 then raise exception 'generated options are not unique'; end if;
  if ambiguous or quality<0.85 then raise exception 'generated transfer failed quality gate'; end if;
  if exists(select 1 from english.questions where lower(trim(question))=lower(qtext)) then raise exception 'generated transfer duplicates existing question'; end if;

  select * into src from english.questions where question_id=j.source_question_id;
  select m.family_id,c.skill_family into fam,skill
  from english.question_concept_mappings m join english.concepts c on c.concept_id=m.concept_id
  where m.question_id=j.source_question_id;

  qid:='AIT_'||upper(substr(replace(j.job_id::text,'-',''),1,16));
  insert into english.questions(
    question_id,topic,word,question,option_a,option_b,option_c,option_d,correct,explanation,subtopic,question_type,
    source_file,source_page,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,related_words,review_notes,active
  ) values(
    qid,coalesce(src.topic,skill),nullif(trim(coalesce(p_item->>'word','')),''),qtext,qa,qb,qc,qd,ckey,
    trim(coalesce(p_item->>'explanation','Fresh transfer validation.')),src.subtopic,
    coalesce(nullif(trim(p_item->>'questionType'),''),'Transfer / Discrimination'),
    'AI Targeted Transfer',null,j.concept_id,coalesce(nullif(trim(p_item->>'difficulty'),''),'Moderate'),
    'AI_TARGETED_'||upper(substr(replace(j.job_id::text,'-',''),1,12)),'New','Active',coalesce(src.exam_relevance,'high'),j.related_term,
    'Background Luna generated; independent critic approved; quality='||quality::text,true
  );

  insert into english.question_origins(question_id,origin_kind,origin_ref,owner_user_id)
  values(qid,'targeted_generated',j.job_id::text,j.user_id)
  on conflict(question_id) do update set origin_kind=excluded.origin_kind,origin_ref=excluded.origin_ref,owner_user_id=excluded.owner_user_id;

  insert into english.question_concept_mappings(
    question_id,concept_id,family_id,mapping_confidence,mapping_method,model,review_status,relation_type,updated_at
  ) values(qid,j.concept_id,fam,1,'luna_validated_transfer',p_model,'verified','variant',now())
  on conflict(question_id) do update set concept_id=excluded.concept_id,family_id=excluded.family_id,mapping_confidence=1,
    mapping_method=excluded.mapping_method,model=excluded.model,review_status='verified',relation_type='variant',updated_at=now();

  perform english.route_to_targeted(j.user_id,qid,'AI Transfer','Fresh validated transfer generated because the existing bank lacked an alternate item');
  update english.learning_route_state
  set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
    'targeted_kind','transfer_check','generated_for_question',j.source_question_id,'transfer_job_id',j.job_id,'ai_model',p_model),updated_at=now()
  where user_id=j.user_id and question_id=qid;

  update english.targeted_transfer_jobs
  set status='done',generated_question_id=qid,processed_at=now(),updated_at=now(),last_error=null,
      metadata=metadata||jsonb_build_object('model',p_model,'qualityScore',quality,'usage',coalesce(p_usage,'{}'::jsonb))
  where job_id=j.job_id;

  perform english.log_learning_activity(
    j.user_id,'transfer_generated','Fresh transfer prepared',
    'Existing bank had no alternate item · a validated transfer question was added to Targeted.',
    qid,j.concept_id,j.source_note_id,'targeted',
    jsonb_build_object('sourceQuestionId',j.source_question_id,'qualityScore',quality,'model',p_model),now()
  );
  return jsonb_build_object('ok',true,'questionId',qid,'qualityScore',quality);
exception when others then
  if j.job_id is not null then
    update english.targeted_transfer_jobs
    set status=case when attempts>=3 then 'failed' else 'queued' end,
        next_attempt_at=case when attempts>=3 then null else now()+make_interval(mins=>least(30,greatest(1,attempts)*5)) end,
        last_error=left(sqlerrm,1000),updated_at=now()
    where job_id=j.job_id;
  end if;
  raise;
end $$;

create or replace function public.english_apply_generated_transfer(
  p_token text,p_job_id uuid,p_item jsonb,p_model text default 'gpt-5.6-luna',p_usage jsonb default '{}'::jsonb
) returns jsonb language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.apply_generated_transfer(p_token,p_job_id,p_item,p_model,p_usage); $$;
revoke all on function public.english_apply_generated_transfer(text,uuid,jsonb,text,jsonb) from public,anon,authenticated;
grant execute on function public.english_apply_generated_transfer(text,uuid,jsonb,text,jsonb) to service_role;

create or replace function english.fail_transfer_generation(p_token text,p_job_id uuid,p_error text)
returns void language plpgsql security definer set search_path to 'pg_catalog','english'
as $$
declare a integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'context worker unauthorized'; end if;
  select attempts into a from english.targeted_transfer_jobs where job_id=p_job_id for update;
  update english.targeted_transfer_jobs
  set status=case when coalesce(a,0)>=3 then 'failed' else 'queued' end,
      next_attempt_at=case when coalesce(a,0)>=3 then null else now()+make_interval(mins=>least(30,greatest(1,coalesce(a,1))*5)) end,
      last_error=left(coalesce(p_error,'transfer generation failed'),1000),updated_at=now()
  where job_id=p_job_id;
end $$;

create or replace function public.english_fail_transfer_generation(p_token text,p_job_id uuid,p_error text)
returns void language sql security definer set search_path to 'pg_catalog','public','english'
as $$ select english.fail_transfer_generation(p_token,p_job_id,p_error); $$;
revoke all on function public.english_fail_transfer_generation(text,uuid,text) from public,anon,authenticated;
grant execute on function public.english_fail_transfer_generation(text,uuid,text) to service_role;

-- I Guessed stays idempotent and preserves correctness; only missing alternate evidence creates a generation job.
create or replace function english.english_record_guess(p_question_id text,p_attempt_id text default null)
returns jsonb language plpgsql set search_path to 'pg_catalog','english','auth'
as $$
declare
  uid uuid:=auth.uid(); cid text; aid text:=nullif(trim(coalesce(p_attempt_id,'')),'');
  inserted boolean:=false; alt_exists boolean:=false; job uuid;
begin
  if uid is null then raise exception 'authentication required'; end if;
  if not exists(select 1 from english.questions where question_id=p_question_id and english.question_visible_to_user(uid,p_question_id)) then raise exception 'question not found'; end if;
  if aid is null then
    select attempt_id into aid from english.attempts where user_id=uid and question_id=p_question_id order by attempted_at desc,created_at desc limit 1;
  end if;
  select concept_id into cid from english.question_concept_mappings where question_id=p_question_id;

  if aid is not null then
    insert into english.learner_confidence_signals(user_id,question_id,attempt_id,signal)
    values(uid,p_question_id,aid,'guessed')
    on conflict(user_id,question_id,attempt_id,signal) where attempt_id is not null do nothing;
    get diagnostics inserted=row_count;
  elsif not exists(
    select 1 from english.learner_confidence_signals
    where user_id=uid and question_id=p_question_id and signal='guessed' and attempt_id is null and created_at>now()-interval '10 minutes'
  ) then
    insert into english.learner_confidence_signals(user_id,question_id,attempt_id,signal) values(uid,p_question_id,null,'guessed');
    inserted:=true;
  end if;

  select exists(
    select 1 from english.questions q
    join english.question_concept_mappings m on m.question_id=q.question_id
    where q.active and m.concept_id=cid and q.question_id<>p_question_id and english.question_visible_to_user(uid,q.question_id)
  ) into alt_exists;

  if inserted then
    update english.question_state
    set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours')
    where user_id=uid and question_id=p_question_id and not coalesce(mastered,false);
    perform english.route_to_targeted(uid,p_question_id,'I Guessed','Confidence signal needs a fresh transfer check');
    update english.learning_route_state
    set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('targeted_kind','transfer_check','source_attempt_id',aid),updated_at=now()
    where user_id=uid and question_id=p_question_id;
    if cid is not null and not alt_exists then
      job:=english.ensure_transfer_generation_job(uid,cid,p_question_id,null,null,'I Guessed requires a fresh transfer but bank has no alternate');
    end if;
    perform english.log_learning_activity(
      uid,'guess_transfer','I Guessed → transfer check',
      case when job is null then 'Correctness is preserved · fresh validation is queued.'
           else 'Correctness is preserved · a missing transfer item is being prepared.' end,
      p_question_id,cid,null,'targeted',jsonb_build_object('attemptId',aid,'transferJob',job),now()
    );
    if cid is not null then perform english.recompute_concept_evidence(uid,cid); end if;
  end if;

  return jsonb_build_object('ok',true,'signal','guessed','concept_id',cid,'attempt_id',aid,'recorded',inserted,
    'validation_due',case when inserted then now()+interval '12 hours' else null end,'alternate_available',alt_exists,'transfer_job',job);
end $$;

create or replace function english.kick_context_worker(p_context_limit integer default 6,p_transfer_limit integer default 1)
returns bigint language plpgsql security definer set search_path to 'pg_catalog','english','net'
as $$
declare v_token text; v_id bigint; v_has_work boolean:=false;
begin
  perform english.enqueue_missing_targeted_transfers(6);
  update english.learner_context_notes
  set ai_status='queued',ai_next_attempt_at=now(),ai_error='stale background processing recovered'
  where ai_status='processing' and ai_attempted_at<now()-interval '5 minutes' and ai_attempts<3;
  update english.targeted_transfer_jobs
  set status='queued',next_attempt_at=now(),last_error='stale generation recovered',updated_at=now()
  where status='processing' and updated_at<now()-interval '5 minutes' and attempts<3;

  select exists(
    select 1 from english.learner_context_notes where ai_status='queued' and ai_attempts<3 and (ai_next_attempt_at is null or ai_next_attempt_at<=now())
    union all
    select 1 from english.targeted_transfer_jobs where status='queued' and attempts<3 and (next_attempt_at is null or next_attempt_at<=now())
  ) into v_has_work;
  if not v_has_work then return 0; end if;

  select token into v_token from english.context_ai_runtime_guard where singleton;
  if v_token is null then raise exception 'context runtime guard missing'; end if;
  select net.http_post(
    url:='https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-context-worker',
    body:=jsonb_build_object(
      'contextLimit',greatest(1,least(8,coalesce(p_context_limit,6))),
      'transferLimit',greatest(1,least(2,coalesce(p_transfer_limit,1)))
    ),
    params:='{}'::jsonb,
    headers:=jsonb_build_object('Content-Type','application/json','x-english-context-token',v_token),
    timeout_milliseconds:=55000
  ) into v_id;
  return v_id;
end $$;
revoke all on function english.kick_context_worker(integer,integer) from public,anon,authenticated;
grant execute on function english.kick_context_worker(integer,integer) to service_role;

-- Only this worker schedule is replaced. Existing enrichment/semantic schedules remain untouched.
do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname='english-context-intelligence' or command ilike '%kick_context_worker%' loop
    perform cron.unschedule(j.jobid);
  end loop;
  perform cron.schedule('english-context-intelligence','*/2 * * * *','select english.kick_context_worker(6,1);');
end $$;

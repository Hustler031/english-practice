begin;

-- Keep targeted category semantics in one place. Explicit metadata always wins;
-- origins are only a legacy fallback for rows created before targeted_kind existed.
create or replace function english.targeted_route_kind(p_metadata jsonb, p_origins text[])
returns text
language sql
immutable
set search_path = pg_catalog, english
as $$
  select case
    when lower(coalesce(p_metadata->>'targeted_kind','')) in ('confusion','transfer_check','retention_check','need_learning')
      then lower(p_metadata->>'targeted_kind')
    when 'I Guessed'=any(coalesce(p_origins,'{}'::text[])) or 'AI Transfer'=any(coalesce(p_origins,'{}'::text[]))
      then 'transfer_check'
    when 'Learner Context'=any(coalesce(p_origins,'{}'::text[])) or 'Learner Context Related'=any(coalesce(p_origins,'{}'::text[]))
      then 'confusion'
    else 'need_learning'
  end;
$$;

-- Deterministic context parsing must only create confusion relations for an
-- actual confusion note. Phrase matching is token-boundary based so a word
-- such as "Quest" cannot be inferred from the learner writing "questions".
create or replace function english.process_context_note_rule_based(p_user_id uuid, p_note_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $$
declare
  n english.learner_context_notes%rowtype; cid text; rcid text;
  is_confusion boolean:=false; is_retention boolean:=false; is_rule boolean:=false; needs_ai boolean:=false;
  related_ids text[]:='{}'::text[]; related_words text[]:='{}'::text[]; rid text; rword text;
  action_taken text:='none'; diagnosis_type text:='context_signal'; targeted_kind text:='need_learning';
begin
  select * into n from english.learner_context_notes where note_id=p_note_id and user_id=p_user_id for update;
  if not found then raise exception 'Context note not found'; end if;
  if n.processing_status='done' then return coalesce(n.diagnosis,'{}'::jsonb)||jsonb_build_object('ok',true,'already_processed',true); end if;
  update english.learner_context_notes set processing_status='processing' where note_id=p_note_id;
  select concept_id into cid from english.question_concept_mappings where question_id=n.question_id;

  is_confusion:=lower(n.note) ~ '(confus|difference|same meaning|mix( |-|_)up|versus|(^|[^a-z])vs([^a-z]|$)|similar|cannot distinguish|can.t distinguish|problem (in|with))';
  is_retention:=lower(n.note) ~ '(forget|forgot|remember|recall|keep forgetting|not retain|retention)';
  is_rule:=lower(n.note) ~ '(rule|grammar|passive|active voice|narration|preposition|usage rule|structure)';

  if is_confusion then
    select coalesce(array_agg(x.question_id),'{}'::text[]),coalesce(array_agg(x.word),'{}'::text[])
    into related_ids,related_words from(
      select q.question_id,trim(q.word) word
      from english.questions q left join english.question_concept_mappings qm on qm.question_id=q.question_id
      where q.active and q.question_id<>n.question_id and english.question_visible_to_user(p_user_id,q.question_id)
        and nullif(trim(coalesce(q.word,'')),'') is not null and char_length(trim(q.word))>=4
        and position(
          ' '||regexp_replace(lower(trim(q.word)),'[^[:alnum:]]+',' ','g')||' '
          in ' '||regexp_replace(lower(n.note),'[^[:alnum:]]+',' ','g')||' '
        )>0
        and (cid is null or qm.concept_id is distinct from cid)
      order by char_length(trim(q.word)) desc,q.question_id limit 4
    ) x;
  end if;

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
      'targeted_kind',targeted_kind,'source_note_id',p_note_id,'concept_id',cid),updated_at=now()
    where user_id=p_user_id and question_id=n.question_id;
    action_taken:='targeted_mastery';
  end if;

  if is_confusion then
    for rid,rword in select * from unnest(related_ids,related_words) loop
      select concept_id into rcid from english.question_concept_mappings where question_id=rid;
      perform english.route_to_targeted(p_user_id,rid,'Learner Context Related','Related item named in learner context note');
      update english.learning_route_state set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'targeted_kind','confusion','source_note_id',p_note_id,'related_to_question',n.question_id),updated_at=now()
      where user_id=p_user_id and question_id=rid;
      if cid is not null then perform english.upsert_learner_confusion(p_user_id,cid,n.question_id,rword,rid,rcid,p_note_id,
        jsonb_build_object('source','context','processor','deterministic_v2')); end if;
    end loop;
  end if;

  update english.question_state set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours')
  where user_id=p_user_id and question_id=n.question_id and not coalesce(mastered,false);

  update english.learner_context_notes set processing_status='done',
    ai_status=case when needs_ai then 'queued' else 'not_needed' end,ai_error=null,
    diagnosis=jsonb_build_object('type',diagnosis_type,'action',action_taken,'concept_id',cid,
      'related_question_ids',to_jsonb(related_ids),'related_terms',to_jsonb(related_words),
      'needs_ai',needs_ai,'processor','deterministic_v2'),processed_at=now()
  where note_id=p_note_id;

  if action_taken='targeted_mastery' then
    perform english.log_learning_activity(p_user_id,'context_targeted','Context added to Targeted',
      case when cardinality(related_words)>0 then 'Confusion detected: '||array_to_string(related_words,' ↔ ')||' · focused repair queued'
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

-- Luna related terms are learning context, not automatically confusion pairs.
-- Only confusion/lexical-interference diagnoses may create cross-concept
-- confusion rows. Transfer checks stay concept-centric and use bank-first.
create or replace function english.apply_context_ai_diagnosis(
  p_token text, p_note_id uuid, p_diagnosis jsonb,
  p_model text default 'gpt-5.6-luna'::text, p_usage jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'english'
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

  if kind='confusion' then
    foreach term in array terms loop
      term:=nullif(trim(term),'');
      if term is null then continue; end if;
      rid:=null; rcid:=null;
      select q.question_id,m.concept_id into rid,rcid
      from english.questions q
      left join english.question_concept_mappings m on m.question_id=q.question_id
      where q.active and q.question_id<>n.question_id and english.question_visible_to_user(n.user_id,q.question_id)
        and (
          lower(trim(coalesce(q.word,'')))=lower(term)
          or position(
            ' '||regexp_replace(lower(term),'[^[:alnum:]]+',' ','g')||' '
            in ' '||regexp_replace(lower(coalesce(q.question,'')),'[^[:alnum:]]+',' ','g')||' '
          )>0
        )
        and (cid is null or m.concept_id is distinct from cid)
      order by case when lower(trim(coalesce(q.word,'')))=lower(term) then 0 else 1 end,q.question_id
      limit 1;

      if rid is not null then
        matched:=matched+1;
        perform english.route_to_targeted(n.user_id,rid,'Background Context AI Related','Related confusion concept found in existing bank');
        update english.learning_route_state
        set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
          'targeted_kind','confusion','source_note_id',p_note_id,'related_to_question',n.question_id,'ai_model',p_model),updated_at=now()
        where user_id=n.user_id and question_id=rid;
      end if;
      if cid is not null then
        perform english.upsert_learner_confusion(n.user_id,cid,n.question_id,term,rid,rcid,p_note_id,
          jsonb_build_object('source','background_ai','model',p_model,'confidence',p_diagnosis->'confidence'));
      end if;
    end loop;

    if cid is not null and cardinality(terms)=0 then
      perform english.upsert_learner_confusion(n.user_id,cid,n.question_id,null,null,null,p_note_id,
        jsonb_build_object('source','background_ai','model',p_model,'confidence',p_diagnosis->'confidence'));
    end if;
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

-- Repair the one class of historical pollution this bug can create. We keep
-- real attempts as evidence, but remove false confusion rows and false
-- "related context" provenance when the final diagnosis was not a confusion.
do $$
declare r record;
begin
  for r in
    select c.confusion_id,c.user_id,c.primary_concept_id,c.related_concept_id
    from english.learner_confusions c
    join english.learner_context_notes n on n.note_id=c.source_note_id
    where coalesce(n.diagnosis->>'type','') not in ('confusion_pair','lexical_interference')
  loop
    delete from english.learner_confusions where confusion_id=r.confusion_id;
    perform english.recompute_concept_evidence(r.user_id,r.primary_concept_id);
    if r.related_concept_id is not null then perform english.recompute_concept_evidence(r.user_id,r.related_concept_id); end if;
  end loop;
end $$;

delete from english.learning_route_state r
using english.learner_context_notes n
where r.route='targeted'
  and r.metadata->>'source_note_id'=n.note_id::text
  and coalesce(n.diagnosis->>'type','') not in ('confusion_pair','lexical_interference')
  and r.last_route_reason in ('Related concept found in existing bank','Related confusion concept found in existing bank')
  and coalesce(cardinality(r.origins),0)=1
  and (r.origins[1]='Background Context AI Related' or r.origins[1]='Learner Context Related');

update english.learning_route_state r
set origins=array_remove(array_remove(coalesce(r.origins,'{}'::text[]),'Learner Context Related'),'Background Context AI Related'),
    metadata=(coalesce(r.metadata,'{}'::jsonb)-'source_note_id'-'related_to_question'),
    updated_at=now()
from english.learner_context_notes n
where r.metadata->>'source_note_id'=n.note_id::text
  and coalesce(n.diagnosis->>'type','') not in ('confusion_pair','lexical_interference')
  and ('Learner Context Related'=any(coalesce(r.origins,'{}'::text[])) or 'Background Context AI Related'=any(coalesce(r.origins,'{}'::text[])));

-- Focused batch: explicit learner signals outrank generic backlog. A generated
-- transfer is itself the fresh item and must never be swapped back to the old
-- source question. A session nonce rotates equally-ranked backlog concepts.
create or replace function public.english_get_targeted_batch(
  p_count integer default 15, p_kind text default null, p_confusion_id uuid default null
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $$
declare
  uid uuid:=auth.uid();
  n int:=greatest(1,least(30,coalesce(p_count,15)));
  k text:=lower(nullif(trim(coalesce(p_kind,'')),''));
  session_nonce text:=nullif(current_setting('english.targeted_session_nonce',true),'');
  outv jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  with focus as(
    select * from english.learner_confusions
    where user_id=uid and p_confusion_id is not null and confusion_id=p_confusion_id
  ), routed as(
    select r.question_id,m.concept_id,r.metadata,r.origins,r.last_route_reason,r.updated_at,
      ce.coverage_state,ce.confidence_score,ce.next_review,
      english.targeted_route_kind(r.metadata,r.origins) kind
    from english.learning_route_state r
    join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid,q.question_id)
    left join english.question_concept_mappings m on m.question_id=r.question_id
    left join english.concept_evidence ce on ce.user_id=uid and ce.concept_id=m.concept_id
    where r.user_id=uid and r.route='targeted'
  ), filtered as(
    select x.* from routed x
    where (p_confusion_id is null or exists(
      select 1 from focus f where x.concept_id=f.primary_concept_id or x.concept_id=f.related_concept_id
        or x.question_id=f.primary_question_id or x.question_id=f.related_question_id
    )) and (k is null or x.kind=k)
  ), delivery as(
    select f.*,coalesce(alt.question_id,f.question_id) delivery_question_id,
      row_number() over(
        partition by coalesce(f.concept_id,f.question_id)
        order by case f.kind when 'confusion' then 1 when 'transfer_check' then 2 when 'retention_check' then 3 else 4 end,
          f.updated_at desc
      ) concept_pick
    from filtered f
    left join lateral(
      select q2.question_id
      from english.questions q2
      join english.question_concept_mappings m2 on m2.question_id=q2.question_id
      left join english.question_state s2 on s2.user_id=uid and s2.question_id=q2.question_id
      where f.kind in('transfer_check','confusion')
        and not (
          f.kind='transfer_check' and (
            'AI Transfer'=any(coalesce(f.origins,'{}'::text[]))
            or exists(select 1 from english.question_origins qo where qo.question_id=f.question_id and qo.origin_kind='targeted_generated' and qo.owner_user_id=uid)
          )
        )
        and f.concept_id is not null and m2.concept_id=f.concept_id and q2.question_id<>f.question_id
        and q2.active and english.question_visible_to_user(uid,q2.question_id) and not coalesce(s2.mastered,false)
      order by coalesce(s2.last_attempt,'epoch'::timestamptz),
        case when session_nonce is null then q2.question_id else md5(session_nonce||'|'||q2.question_id) end
      limit 1
    ) alt on true
  ), chosen as(
    select * from delivery where concept_pick=1
    order by
      case
        when kind='confusion' then 1
        when kind='transfer_check' then 2
        when kind='retention_check' and (next_review is null or next_review<=now()) then 3
        when kind='need_learning' then 4
        else 5
      end,
      case when session_nonce is not null then md5(session_nonce||'|'||coalesce(concept_id,question_id)) else '' end,
      coalesce(next_review,'epoch'::timestamptz),updated_at desc
    limit n
  )
  select coalesce(jsonb_agg(
    english.question_payload(uid,c.delivery_question_id)||jsonb_build_object(
      'learningRoute','targeted','targetedKind',c.kind,'targetedReason',c.last_route_reason,
      'sourceQuestionId',c.question_id,'conceptId',c.concept_id,'conceptCoverage',coalesce(c.coverage_state,'unseen'),
      'conceptConfidence',coalesce(c.confidence_score,0),'conceptNextReview',c.next_review
    )
    order by
      case
        when c.kind='confusion' then 1
        when c.kind='transfer_check' then 2
        when c.kind='retention_check' and (c.next_review is null or c.next_review<=now()) then 3
        when c.kind='need_learning' then 4
        else 5
      end,
      case when session_nonce is not null then md5(session_nonce||'|'||coalesce(c.concept_id,c.question_id)) else '' end,
      c.updated_at desc
  ),'[]'::jsonb) into outv from chosen c;
  return outv;
end $$;

create or replace function public.english_get_targeted_session(
  p_count integer default 15, p_kind text default null, p_confusion_id uuid default null, p_session_nonce text default null
)
returns jsonb
language plpgsql
volatile security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $$
begin
  perform set_config('english.targeted_session_nonce',coalesce(nullif(trim(p_session_nonce),''),''),true);
  return public.english_get_targeted_batch(p_count,p_kind,p_confusion_id);
end $$;

create or replace function public.english_get_targeted_mastery()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $$
with uid as(select auth.uid() id), targeted as(
  select r.*,m.concept_id,coalesce(c.name,q.word,q.question_id) concept_name,
    coalesce(c.skill_family,q.topic,'English') skill_family,coalesce(ce.coverage_state,'unseen') concept_state,
    coalesce(ce.confidence_score,0) confidence,ce.next_review,
    english.targeted_route_kind(r.metadata,r.origins) kind
  from uid join english.learning_route_state r on r.user_id=uid.id and r.route='targeted'
  join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid.id,q.question_id)
  left join english.question_concept_mappings m on m.question_id=q.question_id
  left join english.concepts c on c.concept_id=m.concept_id
  left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id
), dedup as(
  select t.*,row_number() over(partition by coalesce(t.concept_id,t.question_id) order by
    case t.kind when 'confusion' then 1 when 'transfer_check' then 2 when 'retention_check' then 3 when 'need_learning' then 4 else 5 end,
    t.updated_at desc) rn from targeted t
), base as(select * from dedup where rn=1), conf as(
  select cf.*,coalesce(c1.name,q1.word,cf.primary_concept_id) primary_name,
    coalesce(c2.name,q2.word,cf.related_term,cf.related_concept_id,'Related concept') related_name,
    left(coalesce(n.note,''),180) note
  from uid join english.learner_confusions cf on cf.user_id=uid.id
  left join english.concepts c1 on c1.concept_id=cf.primary_concept_id
  left join english.concepts c2 on c2.concept_id=cf.related_concept_id
  left join english.questions q1 on q1.question_id=cf.primary_question_id
  left join english.questions q2 on q2.question_id=cf.related_question_id
  left join english.learner_context_notes n on n.note_id=cf.source_note_id
), recovered as(
  select r.question_id,m.concept_id,coalesce(c.name,q.word,r.question_id) concept_name,r.targeted_recovered_at
  from uid join english.learning_route_state r on r.user_id=uid.id and r.targeted_recovered_at is not null
  join english.questions q on q.question_id=r.question_id
  left join english.question_concept_mappings m on m.question_id=q.question_id
  left join english.concepts c on c.concept_id=m.concept_id
  order by r.targeted_recovered_at desc limit 20
)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
  'ok',true,
  'summary',jsonb_build_object(
    'active',(select count(*) from base),
    'dueNow',(select count(*) from base where next_review is null or next_review<=now()),
    'confusions',(select count(*) from conf where status<>'resolved'),
    'needLearning',(select count(*) from base where kind='need_learning'),
    'transferChecks',(select count(*) from base where kind='transfer_check'),
    'retentionChecks',(select count(*) from base where kind='retention_check'),
    'recovered',(select count(*) from conf where status='resolved')+(select count(*) from recovered)
  ),
  'confusions',coalesce((select jsonb_agg(jsonb_build_object(
    'confusionId',confusion_id,'status',status,'strength',strength,'primaryConceptId',primary_concept_id,
    'relatedConceptId',related_concept_id,'primaryQuestionId',primary_question_id,'relatedQuestionId',related_question_id,
    'primaryName',primary_name,'relatedName',related_name,'note',note,'openedAt',opened_at,'lastSignalAt',last_signal_at,'resolvedAt',resolved_at
  ) order by last_signal_at desc) from conf where status<>'resolved'),'[]'::jsonb),
  'needLearning',coalesce((select jsonb_agg(jsonb_build_object(
    'questionId',question_id,'conceptId',concept_id,'name',concept_name,'skillFamily',skill_family,'state',concept_state,
    'confidence',confidence,'reason',last_route_reason,'nextReview',next_review
  ) order by updated_at desc) from(select * from base where kind='need_learning' order by updated_at desc limit 24)x),'[]'::jsonb),
  'transferChecks',coalesce((select jsonb_agg(jsonb_build_object(
    'questionId',question_id,'conceptId',concept_id,'name',concept_name,'state',concept_state,'confidence',confidence,
    'reason',last_route_reason,'nextReview',next_review
  ) order by updated_at desc) from(select * from base where kind='transfer_check' order by updated_at desc limit 24)x),'[]'::jsonb),
  'retentionChecks',coalesce((select jsonb_agg(jsonb_build_object(
    'questionId',question_id,'conceptId',concept_id,'name',concept_name,'state',concept_state,'confidence',confidence,
    'reason',last_route_reason,'nextReview',next_review
  ) order by coalesce(next_review,'epoch'::timestamptz)) from(select * from base where kind='retention_check' order by coalesce(next_review,'epoch'::timestamptz) limit 24)x),'[]'::jsonb),
  'recovered',coalesce((select jsonb_agg(to_jsonb(z) order by z.at desc) from(
    select primary_concept_id concept_id,primary_name name,resolved_at at,'confusion' source from conf where status='resolved' and resolved_at is not null
    union all select concept_id,concept_name,targeted_recovered_at,'targeted' from recovered order by at desc limit 24
  )z),'[]'::jsonb)
) end from uid;
$$;

create or replace function public.english_get_targeted_summary()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'english', 'auth'
as $$
with uid as(select auth.uid() id), base as(
  select r.question_id,m.concept_id,r.metadata,r.origins,ce.next_review,
    english.targeted_route_kind(r.metadata,r.origins) kind,r.updated_at
  from uid
  join english.learning_route_state r on r.user_id=uid.id and r.route='targeted'
  join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid.id,q.question_id)
  left join english.question_concept_mappings m on m.question_id=r.question_id
  left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id
), dedup as(
  select b.*,row_number() over(partition by coalesce(b.concept_id,b.question_id) order by
    case b.kind when 'confusion' then 1 when 'transfer_check' then 2 when 'retention_check' then 3 when 'need_learning' then 4 else 5 end,
    b.updated_at desc) rn from base b
), current as(select * from dedup where rn=1), conf as(
  select count(*)::int n from uid join english.learner_confusions c on c.user_id=uid.id where c.status<>'resolved'
)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
  'ok',true,
  'active',(select count(*) from current),
  'dueNow',(select count(*) from current where next_review is null or next_review<=now()),
  'confusions',(select n from conf),
  'needLearning',(select count(*) from current where kind='need_learning'),
  'transferChecks',(select count(*) from current where kind='transfer_check'),
  'retentionChecks',(select count(*) from current where kind='retention_check')
) end from uid;
$$;

commit;

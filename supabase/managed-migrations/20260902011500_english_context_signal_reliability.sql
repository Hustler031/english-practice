create or replace function english.process_context_note_rule_based(p_user_id uuid, p_note_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $$
declare
  n english.learner_context_notes%rowtype;
  cid text;
  is_confusion boolean:=false;
  related_ids text[]:='{}'::text[];
  related_words text[]:='{}'::text[];
  rid text;
  action_taken text:='retention_check';
begin
  select * into n from english.learner_context_notes where note_id=p_note_id and user_id=p_user_id for update;
  if not found then raise exception 'Context note not found'; end if;
  if n.processing_status='done' then return coalesce(n.diagnosis,'{}'::jsonb)||jsonb_build_object('ok',true,'already_processed',true); end if;

  update english.learner_context_notes set processing_status='processing' where note_id=p_note_id;
  select m.concept_id into cid from english.question_concept_mappings m where m.question_id=n.question_id;
  is_confusion:=lower(n.note) ~ '(confus|difference|same meaning|mix( |-|_)up|versus|(^|[^a-z])vs([^a-z]|$)|similar|problem (in|with)|cannot distinguish|can.t distinguish)';

  select coalesce(array_agg(x.question_id),'{}'::text[]),coalesce(array_agg(x.word),'{}'::text[])
  into related_ids,related_words
  from (
    select q.question_id,trim(q.word) word
    from english.questions q
    left join english.question_concept_mappings qm on qm.question_id=q.question_id
    where q.active and q.question_id<>n.question_id
      and nullif(trim(coalesce(q.word,'')),'') is not null
      and char_length(trim(q.word))>=4
      and position(lower(trim(q.word)) in lower(n.note))>0
      and (cid is null or qm.concept_id is distinct from cid)
    order by char_length(trim(q.word)) desc,q.question_id
    limit 3
  ) x;

  update english.question_state
  set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours')
  where user_id=p_user_id and question_id=n.question_id and not coalesce(mastered,false);

  if is_confusion or cardinality(related_ids)>0 then
    perform english.route_to_targeted(p_user_id,n.question_id,'Learner Context','Learner supplied a confusion/context signal');
    action_taken:='targeted_mastery';
  end if;
  foreach rid in array related_ids loop
    perform english.route_to_targeted(p_user_id,rid,'Learner Context Related','Related item named in learner context note');
  end loop;

  update english.learner_context_notes
  set processing_status='done',
      diagnosis=jsonb_build_object(
        'type',case when is_confusion or cardinality(related_ids)>0 then 'confusion_pair' else 'retention_context' end,
        'action',action_taken,
        'concept_id',cid,
        'related_question_ids',to_jsonb(related_ids),
        'related_terms',to_jsonb(related_words),
        'needs_ai',case when is_confusion and cardinality(related_ids)=0 then true else false end,
        'processor','deterministic_v1'
      ),processed_at=now()
  where note_id=p_note_id;

  if cid is not null then perform english.recompute_concept_evidence(p_user_id,cid); end if;
  return jsonb_build_object('ok',true,'note_id',p_note_id,'concept_id',cid,'action',action_taken,'related_question_ids',related_ids,'related_terms',related_words,'needs_ai',is_confusion and cardinality(related_ids)=0);
exception when others then
  update english.learner_context_notes set processing_status='failed',diagnosis=jsonb_build_object('error',sqlerrm,'processor','deterministic_v1'),processed_at=now()
  where note_id=p_note_id and user_id=p_user_id;
  raise;
end $$;

revoke all on function english.process_context_note_rule_based(uuid,uuid) from public,anon,authenticated;
grant execute on function english.process_context_note_rule_based(uuid,uuid) to service_role;

create or replace function english.recompute_concept_evidence(p_user_id uuid, p_concept_id text)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','english'
as $$
declare
  r record;
  v_guessed int:=0;
  v_context_confusions int:=0;
  v_confusions int:=0;
  score numeric:=0;
  state text:='unseen';
  v_next timestamptz;
begin
  with raw as (
    select a.attempted_at occurred_at,a.correct,a.question_id,coalesce(nullif(a.module,''),'practice') variant,a.question_id evidence_key,null::text diagnosis
    from english.attempts a join english.question_concept_mappings m on m.question_id=a.question_id
    where a.user_id=p_user_id and m.concept_id=p_concept_id
    union all
    select e.occurred_at,e.correct,e.question_id,coalesce(nullif(e.variant,''),e.source) variant,coalesce(e.question_id,e.source_key) evidence_key,e.metadata->>'diagnosis' diagnosis
    from english.concept_evidence_events e where e.user_id=p_user_id and e.concept_id=p_concept_id
  ), ordered as (select raw.*,lag(occurred_at) over(order by occurred_at,evidence_key) prev_at from raw)
  select count(*)::int attempts,
    count(*) filter(where correct is true)::int correct,
    count(*) filter(where correct is false)::int wrong,
    count(distinct evidence_key)::int distinct_questions,
    count(distinct variant)::int distinct_variants,
    count(*) filter(where correct is true and lower(variant) ~ '(target|sprint|fast|transfer)')::int transfer_successes,
    count(*) filter(where correct is true and prev_at is not null and occurred_at-prev_at>=interval '20 hours')::int delayed_successes,
    count(*) filter(where correct is false and occurred_at>=now()-interval '7 days')::int recent_failures,
    count(*) filter(where lower(coalesce(diagnosis,''))='confusion')::int confusion_count,
    max(occurred_at) last_attempt_at
  into r from ordered;

  select count(*)::int into v_guessed from english.learner_confidence_signals g
  join english.question_concept_mappings m on m.question_id=g.question_id
  where g.user_id=p_user_id and m.concept_id=p_concept_id and g.signal='guessed';

  select count(*)::int into v_context_confusions from english.learner_context_notes n
  join english.question_concept_mappings m on m.question_id=n.question_id
  where n.user_id=p_user_id and m.concept_id=p_concept_id and n.processing_status='done'
    and lower(coalesce(n.diagnosis->>'type','')) in ('confusion_pair','confusion');

  v_confusions:=coalesce(r.confusion_count,0)+coalesce(v_context_confusions,0);
  score:=greatest(0,least(100,
      least(45,coalesce(r.correct,0)*7)+least(20,coalesce(r.distinct_questions,0)*7)
    + least(15,coalesce(r.delayed_successes,0)*7.5)+least(12,coalesce(r.transfer_successes,0)*6)
    - least(30,coalesce(r.recent_failures,0)*12)-least(20,coalesce(v_guessed,0)*5)-least(20,v_confusions*7)
  ));
  state:=case
    when coalesce(r.attempts,0)=0 then 'unseen'
    when coalesce(r.recent_failures,0)>=2 and score<55 then 'weak'
    when (coalesce(r.recent_failures,0)>0 or v_confusions>0) and score>=55 then 'retention_risk'
    when score>=82 and coalesce(r.delayed_successes,0)>=1 and coalesce(r.distinct_questions,0)>=2 and coalesce(r.transfer_successes,0)>=1 then 'exam_ready'
    when score>=60 and coalesce(r.distinct_questions,0)>=2 then 'secure'
    else 'seen' end;
  v_next:=case state
    when 'weak' then coalesce(r.last_attempt_at,now())+interval '8 hours'
    when 'retention_risk' then least(coalesce(r.last_attempt_at,now())+interval '1 day',now()+interval '12 hours')
    when 'seen' then coalesce(r.last_attempt_at,now())+interval '2 days'
    when 'secure' then coalesce(r.last_attempt_at,now())+interval '6 days'
    when 'exam_ready' then coalesce(r.last_attempt_at,now())+interval '12 days'
    else null end;

  insert into english.concept_evidence(user_id,concept_id,attempts,correct,wrong,guessed,distinct_questions,distinct_variants,transfer_successes,delayed_successes,recent_failures,confusion_count,confidence_score,coverage_state,next_review,last_attempt_at,updated_at)
  values(p_user_id,p_concept_id,coalesce(r.attempts,0),coalesce(r.correct,0),coalesce(r.wrong,0),coalesce(v_guessed,0),coalesce(r.distinct_questions,0),coalesce(r.distinct_variants,0),coalesce(r.transfer_successes,0),coalesce(r.delayed_successes,0),coalesce(r.recent_failures,0),v_confusions,score,state,v_next,r.last_attempt_at,now())
  on conflict(user_id,concept_id) do update set attempts=excluded.attempts,correct=excluded.correct,wrong=excluded.wrong,guessed=excluded.guessed,distinct_questions=excluded.distinct_questions,distinct_variants=excluded.distinct_variants,transfer_successes=excluded.transfer_successes,delayed_successes=excluded.delayed_successes,recent_failures=excluded.recent_failures,confusion_count=excluded.confusion_count,confidence_score=excluded.confidence_score,coverage_state=excluded.coverage_state,next_review=excluded.next_review,last_attempt_at=excluded.last_attempt_at,updated_at=now();
end $$;

create or replace function public.english_save_context_note(p_question_id text,p_note text,p_attempt_id text default null,p_context_snapshot jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); nid uuid; cid text; processed jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from english.questions where question_id=p_question_id and active) then raise exception 'Question not found'; end if;
 if char_length(trim(coalesce(p_note,''))) not between 1 and 600 then raise exception 'Context note must be 1 to 600 characters'; end if;
 select m.concept_id into cid from english.question_concept_mappings m where m.question_id=p_question_id;
 insert into english.learner_context_notes(user_id,question_id,attempt_id,note,context_snapshot)
 values(uid,p_question_id,nullif(trim(coalesce(p_attempt_id,'')),''),trim(p_note),jsonb_strip_nulls(coalesce(p_context_snapshot,'{}'::jsonb)||jsonb_build_object('concept_id',cid,'saved_at',now())))
 returning note_id into nid;
 processed:=english.process_context_note_rule_based(uid,nid);
 return jsonb_build_object('ok',true,'saved',true,'note_id',nid,'concept_id',cid,'processing',coalesce(processed->>'action','done'),'intelligence',processed);
end $$;
revoke all on function public.english_save_context_note(text,text,text,jsonb) from public,anon;
grant execute on function public.english_save_context_note(text,text,text,jsonb) to authenticated,service_role;

create or replace function english.english_record_guess(p_question_id text,p_attempt_id text default null)
returns jsonb language plpgsql set search_path to 'pg_catalog','english'
as $$
declare uid uuid:=(select auth.uid()); cid text; aid text:=nullif(trim(coalesce(p_attempt_id,'')),''); inserted boolean:=false;
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
 if inserted then update english.question_state set next_review=least(coalesce(next_review,now()+interval '12 hours'),now()+interval '12 hours') where user_id=uid and question_id=p_question_id and not coalesce(mastered,false); end if;
 if cid is not null and inserted then perform english.recompute_concept_evidence(uid,cid); end if;
 return jsonb_build_object('ok',true,'signal','guessed','concept_id',cid,'attempt_id',aid,'recorded',inserted,'validation_due',case when inserted then now()+interval '12 hours' else null end);
end $$;

create or replace function public.english_get_learning_signal_summary()
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','english','auth'
as $$
declare uid uuid:=(select auth.uid()); outv jsonb;
begin
 if uid is null then raise exception 'authentication required'; end if;
 select jsonb_build_object(
   'context_total',(select count(*) from english.learner_context_notes where user_id=uid),
   'context_done',(select count(*) from english.learner_context_notes where user_id=uid and processing_status='done'),
   'context_pending',(select count(*) from english.learner_context_notes where user_id=uid and processing_status in ('queued','processing')),
   'context_failed',(select count(*) from english.learner_context_notes where user_id=uid and processing_status='failed'),
   'guessed_total',(select count(*) from english.learner_confidence_signals where user_id=uid and signal='guessed'),
   'context_targeted',(select count(*) from english.learning_route_state where user_id=uid and route='targeted' and 'Learner Context'=any(coalesce(origins,'{}'::text[]))),
   'recent_context',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) from (select note_id,question_id,left(note,160) note,processing_status,diagnosis,created_at from english.learner_context_notes where user_id=uid order by created_at desc limit 6) x)
 ) into outv; return outv;
end $$;
revoke all on function public.english_get_learning_signal_summary() from public,anon;
grant execute on function public.english_get_learning_signal_summary() to authenticated,service_role;

do $$ declare r record; begin
  for r in select user_id,note_id from english.learner_context_notes where processing_status='queued' order by created_at loop
    begin perform english.process_context_note_rule_based(r.user_id,r.note_id); exception when others then null; end;
  end loop;
end $$;
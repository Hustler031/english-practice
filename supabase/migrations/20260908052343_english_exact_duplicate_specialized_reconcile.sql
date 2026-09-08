-- Losslessly converge exact learner-visible duplicate questions onto one canonical QID.
-- The helper is deliberately service-role only and fails closed for semantic lanes that
-- require dedicated reconciliation. No learner/user id is hard-coded.
create or replace function english.merge_exact_duplicate_question(
  p_from text,
  p_to text,
  p_reason text default 'Exact duplicate canonical reconciliation'
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  v_from_hash text;
  v_to_hash text;
  v_cid_from text;
  v_cid_to text;
  v_topic_from text;
  v_topic_to text;
  v_owner_from uuid;
  v_owner_to uuid;
  v_users uuid[] := '{}'::uuid[];
  v_uid uuid;
  v_origins text[];
  v_meta jsonb;
  v_targeted_at timestamptz;
  v_last_failure_at timestamptz;
  v_targeted_recovered_at timestamptz;
  v_starred_resolved_at timestamptz;
  v_kept_failure_count integer;
  v_last_reason text;
  v_baseline_wrong integer;
  v_had_route boolean;
  v_is_phrasal boolean := false;
  v_moved_attempts integer := 0;
  v_moved_exposures integer := 0;
  v_moved_history integer := 0;
begin
  p_from := btrim(coalesce(p_from,''));
  p_to := btrim(coalesce(p_to,''));
  if p_from='' or p_to='' or p_from=p_to then
    raise exception 'Invalid duplicate merge pair: % -> %',p_from,p_to;
  end if;

  select
    md5(lower(regexp_replace(coalesce(q.question,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_a,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_b,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_c,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_d,''),'\s+','','g'))||'|'||
        upper(coalesce(q.correct,''))),
    q.topic,m.concept_id,o.owner_user_id
  into v_from_hash,v_topic_from,v_cid_from,v_owner_from
  from english.questions q
  join english.question_concept_mappings m on m.question_id=q.question_id
  left join english.question_origins o on o.question_id=q.question_id
  where q.question_id=p_from and q.active;
  if not found then raise exception 'Active duplicate source not found: %',p_from; end if;

  select
    md5(lower(regexp_replace(coalesce(q.question,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_a,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_b,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_c,''),'\s+','','g'))||'|'||
        lower(regexp_replace(coalesce(q.option_d,''),'\s+','','g'))||'|'||
        upper(coalesce(q.correct,''))),
    q.topic,m.concept_id,o.owner_user_id
  into v_to_hash,v_topic_to,v_cid_to,v_owner_to
  from english.questions q
  join english.question_concept_mappings m on m.question_id=q.question_id
  left join english.question_origins o on o.question_id=q.question_id
  where q.question_id=p_to and q.active;
  if not found then raise exception 'Active canonical target not found: %',p_to; end if;

  if v_from_hash is distinct from v_to_hash or v_cid_from is distinct from v_cid_to then
    raise exception 'Refusing non-identical merge % -> % (payload/concept mismatch)',p_from,p_to;
  end if;
  if v_owner_to is not null and (v_owner_from is null or v_owner_from is distinct from v_owner_to) then
    raise exception 'Refusing to move public/different-owner question % into private canonical %',p_from,p_to;
  end if;

  if exists(select 1 from english.mastery_events where question_id in (p_from,p_to))
     or exists(select 1 from english.fast_track_failure_decision_intent where question_id in (p_from,p_to))
     or exists(select 1 from english.recall_checks where existing_question_id in (p_from,p_to))
     or exists(select 1 from english.user_question_revisions where question_id in (p_from,p_to))
     or exists(select 1 from english.question_revision_proposals where question_id in (p_from,p_to))
     or exists(select 1 from english.question_quality_reviews where question_id in (p_from,p_to))
     or exists(select 1 from english.question_quality_flags where question_id in (p_from,p_to))
     or exists(select 1 from english.learner_confusions where primary_question_id in (p_from,p_to) or related_question_id in (p_from,p_to))
     or exists(select 1 from english.targeted_transfer_jobs where source_question_id in (p_from,p_to) or generated_question_id in (p_from,p_to))
     or exists(select 1 from english.practice_set_items where question_id in (p_from,p_to)) then
    raise exception 'Duplicate pair % / % has a protected semantic reference',p_from,p_to;
  end if;

  select coalesce(array_agg(distinct x.user_id),'{}'::uuid[]) into v_users
  from (
    select user_id from english.attempts where question_id in (p_from,p_to)
    union select user_id from english.question_state where question_id in (p_from,p_to)
    union select user_id from english.learning_route_state where question_id in (p_from,p_to)
    union select user_id from english.star_events where question_id in (p_from,p_to)
    union select user_id from english.difficult_state where question_id in (p_from,p_to)
    union select user_id from english.quiz_session_exposures where question_id in (p_from,p_to)
    union select user_id from english.daily_current where question_id in (p_from,p_to)
    union select user_id from english.daily_history where question_id in (p_from,p_to)
    union select user_id from english.learner_context_notes where question_id in (p_from,p_to)
    union select user_id from english.learning_intelligence_activity where question_id in (p_from,p_to)
    union select user_id from english.concept_evidence_events where question_id in (p_from,p_to)
    union select user_id from english.sprint_bank_items where question_id in (p_from,p_to)
  ) x;

  v_is_phrasal := lower(coalesce(v_topic_from,'')) like 'phrasal%'
                  or lower(coalesce(v_topic_to,'')) like 'phrasal%'
                  or exists(select 1 from english.phrasal_daily_items where question_id in (p_from,p_to))
                  or exists(select 1 from english.phrasal_question_aliases where canonical_question_id in (p_from,p_to));

  update english.saved_items set practice_question_id=p_to,updated_at=now() where practice_question_id=p_from;
  update english.saved_items set origin_question_id=p_to,updated_at=now() where origin_question_id=p_from;
  update english.sprint_bank_items set question_id=p_to where question_id=p_from;
  update english.sprint_items set canonical_question_id=p_to where canonical_question_id=p_from;
  update english.question_generation_provenance set source_question_id=p_to where source_question_id=p_from;

  delete from english.daily_current f
  where f.question_id=p_from
    and exists(select 1 from english.daily_current t where t.user_id=f.user_id and t.question_id=p_to);
  update english.daily_current
  set question_id=p_to,concept_id=v_cid_to,topic=v_topic_to,
      selection_snapshot=coalesce(selection_snapshot,'{}'::jsonb)||jsonb_build_object(
        'duplicateReconciledFrom',p_from,'canonicalQuestionId',p_to,'duplicateReconciledAt',now())
  where question_id=p_from;

  update english.daily_history t
  set priority=greatest(coalesce(t.priority,0),coalesce(f.priority,0)),
      status=case when lower(coalesce(t.status,''))='completed' or lower(coalesce(f.status,''))='completed' then 'Completed' else coalesce(t.status,f.status) end,
      reason=case when btrim(coalesce(t.reason,''))='' then f.reason else t.reason end,
      archived_at=greatest(t.archived_at,f.archived_at),concept_id=v_cid_to,topic=v_topic_to
  from english.daily_history f
  where f.question_id=p_from and t.question_id=p_to and t.user_id=f.user_id and t.quiz_date=f.quiz_date;
  delete from english.daily_history f
  where f.question_id=p_from
    and exists(select 1 from english.daily_history t where t.user_id=f.user_id and t.quiz_date=f.quiz_date and t.question_id=p_to);
  update english.daily_history set question_id=p_to,concept_id=v_cid_to,topic=v_topic_to where question_id=p_from;
  get diagnostics v_moved_history = row_count;

  update english.daily_analysis_retention_history t
  set is_retention_risk=coalesce(t.is_retention_risk,false) or coalesce(f.is_retention_risk,false),
      captured_at=greatest(t.captured_at,f.captured_at)
  from english.daily_analysis_retention_history f
  where f.question_id=p_from and t.question_id=p_to and t.user_id=f.user_id and t.quiz_date=f.quiz_date;
  delete from english.daily_analysis_retention_history f
  where f.question_id=p_from
    and exists(select 1 from english.daily_analysis_retention_history t where t.user_id=f.user_id and t.quiz_date=f.quiz_date and t.question_id=p_to);
  update english.daily_analysis_retention_history set question_id=p_to where question_id=p_from;

  delete from english.star_events f
  where f.question_id=p_from
    and exists(select 1 from english.star_events t where t.user_id=f.user_id and t.question_id=p_to and t.event_at=f.event_at and t.action=f.action);
  update english.star_events set question_id=p_to where question_id=p_from;

  delete from english.quiz_session_exposures f
  where f.question_id=p_from
    and exists(select 1 from english.quiz_session_exposures t where t.user_id=f.user_id and t.session_id=f.session_id and t.question_id=p_to);
  update english.quiz_session_exposures set question_id=p_to where question_id=p_from;
  get diagnostics v_moved_exposures = row_count;

  insert into english.difficult_state(user_id,question_id,difficult,updated_at)
  select user_id,p_to,bool_or(difficult),max(updated_at)
  from english.difficult_state where question_id in (p_from,p_to)
  group by user_id
  on conflict(user_id,question_id) do update set
    difficult=english.difficult_state.difficult or excluded.difficult,
    updated_at=greatest(english.difficult_state.updated_at,excluded.updated_at);
  delete from english.difficult_state where question_id=p_from;

  update english.attempts
  set question_id=p_to,concept_id=v_cid_to,topic=v_topic_to
  where question_id=p_from;
  get diagnostics v_moved_attempts = row_count;
  update english.attempts set concept_id=v_cid_to,topic=v_topic_to where question_id=p_to;

  update english.learner_confidence_signals set question_id=p_to where question_id=p_from;
  update english.learner_context_notes set question_id=p_to where question_id=p_from;
  update english.learning_intelligence_activity set question_id=p_to,concept_id=v_cid_to where question_id=p_from;
  update english.concept_evidence_events set question_id=p_to,concept_id=v_cid_to where question_id=p_from;
  update english.ai_interventions set question_id=p_to where question_id=p_from;
  update english.learning_route_events set question_id=p_to where question_id=p_from;

  update english.phrasal_daily_items t
  set metadata=coalesce(t.metadata,'{}'::jsonb)||coalesce(f.metadata,'{}'::jsonb)||jsonb_build_object(
        'exactDuplicateMergedFrom',p_from,'exactDuplicateMergedAt',now()),
      original_question_id=case when t.original_question_id=p_from then p_to else t.original_question_id end,
      concept_id=v_cid_to
  from english.phrasal_daily_items f
  where f.question_id=p_from and t.question_id=p_to and t.batch_date=f.batch_date;
  delete from english.phrasal_daily_items f
  where f.question_id=p_from
    and exists(select 1 from english.phrasal_daily_items t where t.batch_date=f.batch_date and t.question_id=p_to);
  update english.phrasal_daily_items
  set question_id=p_to,
      original_question_id=case when original_question_id=p_from then p_to else original_question_id end,
      concept_id=v_cid_to,
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('exactDuplicateMergedFrom',p_from,'exactDuplicateMergedAt',now())
  where question_id=p_from;
  update english.phrasal_daily_items set original_question_id=p_to where original_question_id=p_from;

  if exists(select 1 from english.phrasal_question_aliases where alias_question_id in (p_from,p_to)) then
    raise exception 'Refusing duplicate merge with an existing alias endpoint: % / %',p_from,p_to;
  end if;
  update english.phrasal_question_aliases set canonical_question_id=p_to where canonical_question_id=p_from;
  if v_is_phrasal then
    insert into english.phrasal_question_aliases(alias_question_id,canonical_question_id,reason,created_at)
    values(p_from,p_to,'exact_duplicate_canonical_reconcile',now())
    on conflict(alias_question_id) do update set canonical_question_id=excluded.canonical_question_id,reason=excluded.reason;
  end if;

  if exists(select 1 from english.phrasal_question_variants where question_id=p_from) then
    if exists(select 1 from english.phrasal_question_variants where question_id=p_to) then
      update english.phrasal_question_variants
      set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('exactDuplicateMergedFrom',p_from,'exactDuplicateMergedAt',now())
      where question_id=p_to;
      delete from english.phrasal_question_variants where question_id=p_from;
    else
      update english.phrasal_question_variants set question_id=p_to,concept_id=v_cid_to where question_id=p_from;
    end if;
  end if;

  foreach v_uid in array v_users loop
    select exists(select 1 from english.learning_route_state r where r.user_id=v_uid and r.question_id in (p_from,p_to)) into v_had_route;

    select coalesce(array_agg(distinct o order by o),'{}'::text[])
    into v_origins
    from english.learning_route_state r
    cross join lateral unnest(coalesce(r.origins,'{}'::text[])) o
    where r.user_id=v_uid and r.question_id in (p_from,p_to);

    select
      coalesce((select metadata from english.learning_route_state where user_id=v_uid and question_id=p_from),'{}'::jsonb)
      ||coalesce((select metadata from english.learning_route_state where user_id=v_uid and question_id=p_to),'{}'::jsonb)
      ||jsonb_build_object('exactDuplicateReconciledAt',now(),'mergedQuestionId',p_from,'canonicalQuestionId',p_to),
      min(targeted_at),max(last_failure_at),max(targeted_recovered_at),max(starred_resolved_at),max(kept_failure_count)
    into v_meta,v_targeted_at,v_last_failure_at,v_targeted_recovered_at,v_starred_resolved_at,v_kept_failure_count
    from english.learning_route_state
    where user_id=v_uid and question_id in (p_from,p_to);

    select last_route_reason into v_last_reason
    from english.learning_route_state
    where user_id=v_uid and question_id in (p_from,p_to)
    order by updated_at desc nulls last,question_id limit 1;

    if v_targeted_at is not null then
      select count(*) filter(where not coalesce(correct,false))::int into v_baseline_wrong
      from english.attempts
      where user_id=v_uid and question_id=p_to and attempted_at<=v_targeted_at;
    else
      v_baseline_wrong:=0;
    end if;

    delete from english.learning_route_state where user_id=v_uid and question_id in (p_from,p_to);
    if v_had_route then
      insert into english.learning_route_state(
        user_id,question_id,route,fast_track_status,origins,baseline_wrong,
        entered_fast_track_at,next_fast_track_check,fast_track_mastered_at,
        pending_failure_decision,kept_failure_count,last_failure_at,targeted_at,
        targeted_recovered_at,starred_resolved_at,last_route_reason,metadata,updated_at
      ) values(
        v_uid,p_to,'unclassified',null,coalesce(v_origins,'{}'::text[]),coalesce(v_baseline_wrong,0),
        null,null,null,false,coalesce(v_kept_failure_count,0),v_last_failure_at,v_targeted_at,
        v_targeted_recovered_at,v_starred_resolved_at,
        coalesce(v_last_reason,'Exact duplicate reconciliation; route recalculation pending'),coalesce(v_meta,'{}'::jsonb),now()
      );
    end if;

    delete from english.question_state where user_id=v_uid and question_id in (p_from,p_to);
    delete from english.question_quality_metrics where user_id=v_uid and question_id in (p_from,p_to);
    delete from english.question_distractor_metrics where user_id=v_uid and question_id in (p_from,p_to);

    if exists(select 1 from english.attempts where user_id=v_uid and question_id=p_to) then
      perform english.recompute_question_state(v_uid,p_to);
      perform english.recompute_question_quality(v_uid,p_to);
    end if;
    perform english.recompute_concept_evidence(v_uid,v_cid_to);
  end loop;

  update english.questions
  set active=false,content_status='Merged Duplicate',updated_at=now()
  where question_id=p_from;

  return jsonb_build_object(
    'ok',true,'from',p_from,'to',p_to,'conceptId',v_cid_to,'reason',p_reason,
    'movedAttempts',v_moved_attempts,'movedExposures',v_moved_exposures,'movedHistory',v_moved_history,
    'affectedUsers',cardinality(v_users),'phrasal',v_is_phrasal
  );
end;
$function$;

revoke all on function english.merge_exact_duplicate_question(text,text,text) from public,anon,authenticated;
grant execute on function english.merge_exact_duplicate_question(text,text,text) to service_role;

-- Reconcile every remaining exact payload duplicate inside the same canonical concept.
do $block$
declare
  g record;
  v_to text;
  v_from text;
begin
  for g in
    with norm as (
      select q.question_id,
        md5(lower(regexp_replace(coalesce(q.question,''),'\s+','','g'))||'|'||
            lower(regexp_replace(coalesce(q.option_a,''),'\s+','','g'))||'|'||
            lower(regexp_replace(coalesce(q.option_b,''),'\s+','','g'))||'|'||
            lower(regexp_replace(coalesce(q.option_c,''),'\s+','','g'))||'|'||
            lower(regexp_replace(coalesce(q.option_d,''),'\s+','','g'))||'|'||upper(coalesce(q.correct,''))) payload_key,
        m.concept_id
      from english.questions q
      join english.question_concept_mappings m on m.question_id=q.question_id
      where q.active
    )
    select payload_key,concept_id,array_agg(question_id order by question_id) qids
    from norm group by payload_key,concept_id having count(*)>1
  loop
    select qid into v_to
    from unnest(g.qids) qid
    order by
      (case when exists(select 1 from english.daily_current d where d.question_id=qid) then 1000000 else 0 end
       +case when exists(select 1 from english.sprint_bank_items s where s.question_id=qid) then 500000 else 0 end
       +case when exists(select 1 from english.difficult_state d where d.question_id=qid and d.difficult) then 250000 else 0 end
       +case when (select o.owner_user_id from english.question_origins o where o.question_id=qid) is null then 10000 else 0 end
       +25000*(select count(*) from english.phrasal_question_aliases a where a.canonical_question_id=qid)
       +5000*(select count(*) from english.phrasal_daily_items p where p.question_id=qid)
       +1000*(select count(*) from english.attempts a where a.question_id=qid)
       +200*(select count(*) from english.star_events s where s.question_id=qid)
       +100*(select count(*) from english.learner_context_notes n where n.question_id=qid)
       +100*(select count(*) from english.learning_intelligence_activity a where a.question_id=qid)
       +50*(select count(*) from english.quiz_session_exposures e where e.question_id=qid)
       +25*(select count(*) from english.daily_history h where h.question_id=qid)) desc,
      qid
    limit 1;

    foreach v_from in array g.qids loop
      if v_from<>v_to and exists(select 1 from english.questions where question_id=v_from and active) then
        perform english.merge_exact_duplicate_question(v_from,v_to,'Specialized exact-payload canonical reconciliation');
      end if;
    end loop;
  end loop;

  for g in
    select distinct user_id,quiz_date
    from english.daily_current
    where quiz_date=(now() at time zone 'Asia/Kolkata')::date
  loop
    perform english.repair_daily_shortfall(g.user_id,g.quiz_date,120);
  end loop;
end;
$block$;

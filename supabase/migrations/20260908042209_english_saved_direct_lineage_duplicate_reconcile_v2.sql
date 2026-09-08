-- Lossless reconciliation for recursive My Saved duplicates.
-- This is deliberately generic: no user id, Saved id, Question_ID or Concept_ID is hard-coded.
-- Only direct parent->child Saved lineages with identical learner-visible MCQ payloads,
-- identical authoritative family/intent, and no complex active route state are eligible.

do $$
declare
  r record;
  v_duplicate_q text;
  v_canonical_concept text;
  v_duplicate_concept text;
  v_old_concept text;
  v_parent_status text;
  v_child_status text;
begin
  for r in
    with base as (
      select s.user_id,s.saved_id,s.word,s.context,s.origin_question_id,s.gpt_status,s.created_at,
             english.saved_anchor_key(s.word) anchor,
             english.resolve_saved_type_authoritative(coalesce(t.capture_type,'AUTO'),s.word,s.context,coalesce(oq.topic,'')) family,
             english.resolve_saved_learning_intent_authoritative(coalesce(t.learning_intent,'AUTO'),s.word,
               english.resolve_saved_type_authoritative(coalesce(t.capture_type,'AUTO'),s.word,s.context,coalesce(oq.topic,''))) intent,
             g.question_id generated_qid,g.topic,g.question,g.option_a,g.option_b,g.option_c,g.option_d,g.correct,
             qm.concept_id
      from english.saved_items s
      left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
      left join english.questions oq on oq.question_id=s.origin_question_id
      join english.question_origins go
        on go.origin_kind='saved_generated' and go.origin_ref=s.saved_id and go.owner_user_id=s.user_id
      join english.questions g on g.question_id=go.question_id and g.active
      left join english.question_concept_mappings qm on qm.question_id=g.question_id
      where s.active
    ), pairs as (
      select p.user_id,p.saved_id parent_saved,c.saved_id child_saved,
             p.generated_qid parent_q,c.generated_qid child_q,
             p.concept_id parent_concept,c.concept_id child_concept,
             p.family,p.intent,p.topic parent_topic,c.topic child_topic,
             case p.family
               when 'PV' then 'PHRASAL' when 'V' then 'VOC' when 'SM' then 'SPELLING'
               when 'OWS' then 'OWS' when 'IP' then 'IDIOM' when 'CU' then 'GRAMMAR'
               else null end expected_cat
      from base p
      join base c
        on c.user_id=p.user_id
       and c.origin_question_id=p.generated_qid
       and c.saved_id<>p.saved_id
      where c.anchor=p.anchor and c.family=p.family and c.intent=p.intent
        and p.concept_id is not null and c.concept_id is not null
        and btrim(coalesce(c.question,''))=btrim(coalesce(p.question,''))
        and btrim(coalesce(c.option_a,''))=btrim(coalesce(p.option_a,''))
        and btrim(coalesce(c.option_b,''))=btrim(coalesce(p.option_b,''))
        and btrim(coalesce(c.option_c,''))=btrim(coalesce(p.option_c,''))
        and btrim(coalesce(c.option_d,''))=btrim(coalesce(p.option_d,''))
        and upper(btrim(coalesce(c.correct,'')))=upper(btrim(coalesce(p.correct,'')))
        and not exists (
          select 1 from english.learning_route_state lr
          where lr.user_id=p.user_id and lr.question_id in (p.generated_qid,c.generated_qid)
            and coalesce(lr.route,'unclassified')<>'unclassified'
        )
        and not exists (select 1 from english.daily_current d where d.user_id=p.user_id and d.question_id in (p.generated_qid,c.generated_qid))
        and not exists (select 1 from english.difficult_state d where d.user_id=p.user_id and d.question_id in (p.generated_qid,c.generated_qid) and d.difficult)
        and not exists (select 1 from english.mastery_events m where m.user_id=p.user_id and m.question_id in (p.generated_qid,c.generated_qid) and m.active and m.restored_on is null)
        and not exists (select 1 from english.learner_confidence_signals g where g.user_id=p.user_id and g.question_id in (p.generated_qid,c.generated_qid) and g.resolved_at is null)
        and not exists (select 1 from english.learner_context_notes n where n.user_id=p.user_id and n.question_id in (p.generated_qid,c.generated_qid) and lower(coalesce(n.ai_status,'')) in ('pending','queued','processing'))
        and not exists (select 1 from english.question_revision_proposals x where x.user_id=p.user_id and x.question_id in (p.generated_qid,c.generated_qid) and x.status in ('queued','processing','ready'))
        and not exists (select 1 from english.question_quality_reviews x where x.user_id=p.user_id and x.question_id in (p.generated_qid,c.generated_qid) and x.status in ('queued','processing'))
    )
    select *,
      case
        when english.canonical_category(child_topic)=expected_cat
         and english.canonical_category(parent_topic)<>expected_cat then child_q
        when english.canonical_category(parent_topic)=expected_cat
         and english.canonical_category(child_topic)<>expected_cat then parent_q
        when (select count(*) from english.attempts a where a.user_id=pairs.user_id and a.question_id=child_q)
             >= (select count(*) from english.attempts a where a.user_id=pairs.user_id and a.question_id=parent_q)
          then child_q else parent_q
      end canonical_q
    from pairs
  loop
    v_duplicate_q:=case when r.canonical_q=r.parent_q then r.child_q else r.parent_q end;
    v_canonical_concept:=case when r.canonical_q=r.parent_q then r.parent_concept else r.child_concept end;
    v_duplicate_concept:=case when r.canonical_q=r.parent_q then r.child_concept else r.parent_concept end;

    select gpt_status into v_parent_status from english.saved_items where saved_id=r.parent_saved;
    select gpt_status into v_child_status from english.saved_items where saved_id=r.child_saved;

    -- Keep the original Saved lineage; reuse the child enrichment only when it is
    -- already Ready and the parent is not.
    if lower(btrim(coalesce(v_child_status,'')))='ready'
       and lower(btrim(coalesce(v_parent_status,'')))<>'ready' then
      update english.saved_items p
      set meaning=c.meaning,
          part_of_speech=c.part_of_speech,
          synonyms=c.synonyms,
          antonyms=c.antonyms,
          example=c.example,
          explanation=c.explanation,
          question=c.question,
          option_a=c.option_a,
          option_b=c.option_b,
          option_c=c.option_c,
          option_d=c.option_d,
          correct_option=c.correct_option,
          gpt_status=c.gpt_status,
          gpt_updated_at=c.gpt_updated_at,
          gpt_source=c.gpt_source,
          status='Added',
          practice_question_id=r.canonical_q,
          updated_at=now()
      from english.saved_items c
      where p.saved_id=r.parent_saved and c.saved_id=r.child_saved;
    else
      update english.saved_items
      set status='Added',practice_question_id=r.canonical_q,updated_at=now()
      where saved_id=r.parent_saved;
    end if;

    insert into english.saved_enrichment_item_state(
      user_id,saved_id,state,attempt_count,lease_id,last_error,last_error_at,next_attempt_at,last_success_at,updated_at
    )
    select s.user_id,s.saved_id,'ready',coalesce(es.attempt_count,0),null,null,null,null,now(),now()
    from english.saved_items s
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    where s.saved_id=r.parent_saved
    on conflict(user_id,saved_id) do update set
      state='ready',lease_id=null,last_error=null,last_error_at=null,next_attempt_at=null,
      last_success_at=now(),updated_at=now();

    update english.question_origins
    set origin_ref=r.parent_saved,owner_user_id=r.user_id
    where question_id=r.canonical_q and origin_kind='saved_generated';

    -- Attempts are the authoritative learning evidence. Move them, do not recreate
    -- or delete them, and preserve attempt ids/submission keys/timestamps.
    update english.attempts
    set question_id=r.canonical_q,concept_id=v_canonical_concept
    where user_id=r.user_id and question_id=v_duplicate_q;

    -- Preserve exposure history while respecting the unique session/question key.
    delete from english.quiz_session_exposures e
    where e.user_id=r.user_id and e.question_id=v_duplicate_q
      and exists (
        select 1 from english.quiz_session_exposures c
        where c.user_id=e.user_id and c.session_id=e.session_id and c.question_id=r.canonical_q
      );
    update english.quiz_session_exposures
    set question_id=r.canonical_q
    where user_id=r.user_id and question_id=v_duplicate_q;

    -- Preserve the learner's star actions exactly.
    insert into english.star_events(user_id,question_id,event_at,starred_date,day_no,action,source_row)
    select user_id,r.canonical_q,event_at,starred_date,day_no,action,source_row
    from english.star_events
    where user_id=r.user_id and question_id=v_duplicate_q
    on conflict(user_id,question_id,event_at,action) do nothing;
    delete from english.star_events
    where user_id=r.user_id and question_id=v_duplicate_q;

    -- Candidates are guarded to unclassified route state. Merge only the provenance
    -- labels; actual route decisions continue to belong to Central Intelligence.
    if exists(select 1 from english.learning_route_state where user_id=r.user_id and question_id=r.canonical_q) then
      update english.learning_route_state c
      set origins=(
            select coalesce(array_agg(distinct x order by x),'{}'::text[])
            from unnest(coalesce(c.origins,'{}'::text[]) || coalesce(o.origins,'{}'::text[])) x
          ),
          metadata=coalesce(c.metadata,'{}'::jsonb)||jsonb_build_object('duplicateIdentityReconciledAt',now()),
          updated_at=now()
      from english.learning_route_state o
      where c.user_id=r.user_id and c.question_id=r.canonical_q
        and o.user_id=r.user_id and o.question_id=v_duplicate_q;
      delete from english.learning_route_state where user_id=r.user_id and question_id=v_duplicate_q;
    elsif exists(select 1 from english.learning_route_state where user_id=r.user_id and question_id=v_duplicate_q) then
      update english.learning_route_state
      set question_id=r.canonical_q,
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('duplicateIdentityReconciledAt',now()),
          updated_at=now()
      where user_id=r.user_id and question_id=v_duplicate_q;
    end if;

    update english.question_concept_mappings
    set concept_id=v_canonical_concept,
        mapping_confidence=1,
        mapping_method='duplicate_identity_reconciled',
        review_status='verified',
        updated_at=now()
    where question_id=v_duplicate_q;
    update english.questions
    set concept_id=v_canonical_concept,updated_at=now()
    where question_id=v_duplicate_q;
    update english.saved_concept_mappings
    set concept_id=v_canonical_concept,mapping_confidence=1,
        mapping_method='duplicate_identity_reconciled',updated_at=now()
    where user_id=r.user_id and saved_id in (r.parent_saved,r.child_saved);

    delete from english.question_state where user_id=r.user_id and question_id=v_duplicate_q;
    delete from english.question_quality_metrics where user_id=r.user_id and question_id=v_duplicate_q;
    delete from english.question_distractor_metrics where user_id=r.user_id and question_id=v_duplicate_q;

    update english.saved_items
    set origin_question_id=r.canonical_q,updated_at=now()
    where user_id=r.user_id and active and origin_question_id=v_duplicate_q
      and saved_id<>r.parent_saved;

    update english.saved_items
    set active=false,status='Merged',practice_question_id=r.canonical_q,updated_at=now()
    where user_id=r.user_id and saved_id=r.child_saved;
    delete from english.saved_enrichment_item_state
    where user_id=r.user_id and saved_id=r.child_saved;

    update english.questions
    set active=false,content_status='Merged Duplicate',updated_at=now()
    where question_id=v_duplicate_q;

    perform english.recompute_question_state(r.user_id,r.canonical_q);
    perform english.recompute_question_quality(r.user_id,r.canonical_q);
    perform english.recompute_concept_evidence(r.user_id,v_canonical_concept);

    v_old_concept:=v_duplicate_concept;
    if v_old_concept is distinct from v_canonical_concept
       and not exists(select 1 from english.question_concept_mappings m where m.concept_id=v_old_concept)
       and not exists (
         select 1 from english.saved_concept_mappings sm
         join english.saved_items si on si.saved_id=sm.saved_id and si.user_id=sm.user_id
         where sm.concept_id=v_old_concept and si.active
       ) then
      delete from english.concept_evidence where concept_id=v_old_concept;
      update english.concepts
      set active=false,
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
            'mergedInto',v_canonical_concept,'mergedAt',now()
          ),
          updated_at=now()
      where concept_id=v_old_concept;
    end if;
  end loop;
end $$;

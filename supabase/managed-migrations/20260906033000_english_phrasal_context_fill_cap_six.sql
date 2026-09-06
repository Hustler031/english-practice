-- Cap adaptive Daily Phrasal context-fill/filler slots at six.
-- Central Intelligence still selects the exact 20 concepts.

create or replace function public.english_get_phrasal_hybrid_maintenance_batch(p_mode text default 'smart',p_count integer default 20)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  base jsonb;
  out jsonb:='[]'::jsonb;
  x jsonb;
  eligible_rank integer:=0;
  cid text;
  first_attempt timestamptz;
  attempt_count integer;
  pre_rollout boolean;
  mature boolean;
  context_eligible boolean;
  activation timestamptz;
  requested text;
  legacy_family text;
  sense text;
  sense_gloss text;
  recent jsonb;
  recent_stems jsonb;
  reference_variant jsonb;
  known_senses jsonb;
  selected_qid text;
  selected_variant_family text;
  selected_attempt_count integer:=0;
  recent_three_correct integer:=0;
  selected_variant_cooled boolean:=false;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  base:=public.english_get_phrasal_maintenance_batch(p_mode,p_count);
  if not english.ai_feature_enabled('phrasal_context_fill_v1') then return base; end if;

  select activated_at into activation
  from english.ai_content_feature_flags where flag='phrasal_context_fill_v1';

  for x in select value from jsonb_array_elements(base) loop
    cid:=coalesce(nullif(x->>'phrasalConceptId',''),nullif(x->>'conceptId',''));
    legacy_family:=coalesce(nullif(x->>'missingFamily',''),nullif(x->>'phrasalQuestionFamily',''),'recognition');
    if legacy_family not in ('recognition','recall','confusion') then legacy_family:='recognition'; end if;
    selected_qid:=coalesce(nullif(x->>'id',''),nullif(x->>'questionId',''));

    select min(a.attempted_at),count(a.*)::int
    into first_attempt,attempt_count
    from english.questions q
    left join english.attempts a on a.question_id=q.question_id and a.user_id=uid
    where coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid;

    selected_variant_family:=null;
    selected_attempt_count:=0;
    recent_three_correct:=0;
    selected_variant_cooled:=false;
    if selected_qid is not null then
      select v.question_family into selected_variant_family
      from english.phrasal_question_variants v where v.question_id=selected_qid;
    end if;
    if english.ai_feature_enabled('phrasal_variant_rotation_v1')
       and selected_qid is not null and selected_variant_family='context_fill' then
      select count(*)::int into selected_attempt_count
      from english.attempts a
      where a.user_id=uid and a.question_id=selected_qid;

      select count(*) filter(where z.correct)::int into recent_three_correct
      from (
        select a.correct
        from english.attempts a
        where a.user_id=uid and a.question_id=selected_qid
        order by a.attempted_at desc,a.created_at desc,a.attempt_id desc
        limit 3
      ) z;

      selected_variant_cooled:=selected_attempt_count>=5
        or (selected_attempt_count>=3 and recent_three_correct=3);
    end if;

    pre_rollout:=activation is not null and first_attempt is not null and first_attempt<activation;
    mature:=first_attempt is not null and attempt_count>=3 and first_attempt<=now()-interval '7 days';
    context_eligible:=pre_rollout or mature or selected_variant_cooled;
    if context_eligible then eligible_rank:=eligible_rank+1; end if;
    requested:=case when context_eligible and eligible_rank<=6 then 'context_fill' else legacy_family end;

    sense:=null;
    sense_gloss:=null;
    if selected_qid is not null then
      select v.sense_key into sense
      from english.phrasal_question_variants v
      where v.question_id=selected_qid;
    end if;
    if sense is null then
      select s.sense_key,s.gloss into sense,sense_gloss
      from english.phrasal_concept_senses s
      where s.concept_id=cid and s.active
      order by s.priority desc,s.created_at,s.sense_key limit 1;
    else
      select s.gloss into sense_gloss
      from english.phrasal_concept_senses s
      where s.concept_id=cid and s.sense_key=sense and s.active;
    end if;
    sense:=coalesce(sense,'legacy_default');

    select coalesce(jsonb_agg(jsonb_build_object(
      'senseKey',s.sense_key,'gloss',coalesce(s.gloss,''),'priority',s.priority
    ) order by s.priority desc,s.created_at,s.sense_key),'[]'::jsonb)
    into known_senses
    from english.phrasal_concept_senses s
    where s.concept_id=cid and s.active;

    select coalesce(jsonb_agg(v.variant_fingerprint order by v.created_at desc)
      filter(where nullif(v.variant_fingerprint,'') is not null),'[]'::jsonb)
    into recent
    from (select * from english.phrasal_question_variants where concept_id=cid order by created_at desc limit 8) v;

    select coalesce(jsonb_agg(r.question order by r.last_attempt desc nulls last,r.question),'[]'::jsonb)
    into recent_stems
    from (
      select q.question,max(a.attempted_at) last_attempt
      from english.questions q
      left join english.attempts a on a.question_id=q.question_id and a.user_id=uid
      where q.active and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid
        and btrim(coalesce(q.question,''))<>''
      group by q.question
      order by max(a.attempted_at) desc nulls last,q.question
      limit 8
    ) r;

    -- Preserve the exact card selected by existing Central Intelligence as the
    -- semantic reference. Only fall back to another visible card when the
    -- selected legacy payload has no usable content at all.
    reference_variant:=x;
    if btrim(coalesce(reference_variant->>'question',''))=''
       and btrim(coalesce(reference_variant->>'explanation',''))=''
       and btrim(coalesce(reference_variant->>'word',''))='' then
      select english.question_payload(uid,q.question_id) into reference_variant
      from english.questions q
      where q.active and english.question_visible_to_user(uid,q.question_id)
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid
      order by
        case when english.phrasal_question_family(q)=legacy_family then 0 else 1 end,
        q.question_id
      limit 1;
    end if;

    out:=out||jsonb_build_array(x||jsonb_build_object(
      'senseKey',sense,'senseGloss',coalesce(sense_gloss,''),'knownSenses',coalesce(known_senses,'[]'::jsonb),
      'requestedQuestionFamily',requested,'legacyFamily',legacy_family,
      'historicalExposureBeforeRollout',pre_rollout,'contextMaturityEligible',mature,'contextEligible',context_eligible,
      'selectedVariantCooled',selected_variant_cooled,'selectedVariantAttemptCount',selected_attempt_count,
      'recentVariantFingerprints',coalesce(recent,'[]'::jsonb),'recentConceptStems',coalesce(recent_stems,'[]'::jsonb),
      'referenceVariant',coalesce(reference_variant,'{}'::jsonb),
      'contextBootstrapRank',case when context_eligible then eligible_rank else null end
    ));
  end loop;
  return out;
end $$;
revoke all on function public.english_get_phrasal_hybrid_maintenance_batch(text,integer) from public, anon;
grant execute on function public.english_get_phrasal_hybrid_maintenance_batch(text,integer) to authenticated, service_role;

-- Daily Phrasal 20 becomes a fixed curriculum lane:
-- 4 recognition + 8 usage/recall + 8 confusion/contrast.
-- Missing requested surfaces remain content gaps for the ChatGPT-owned private publisher.

create or replace function public.english_get_phrasal_daily_curriculum_batch(p_count integer default 20)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); n integer:=greatest(1,least(20,coalesce(p_count,20))); out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if n<>20 then raise exception 'Phrasal Daily curriculum is fixed at exactly 20 questions'; end if;

  create temporary table if not exists pg_temp.phrasal_daily_concepts
  on commit drop as select * from english.phrasal_concepts_v2(uid) with no data;
  truncate pg_temp.phrasal_daily_concepts;
  insert into pg_temp.phrasal_daily_concepts
  select * from english.phrasal_concepts_v2(uid)
  where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0);

  create temporary table if not exists pg_temp.phrasal_daily_plan(
    slot_no integer primary key,bucket text not null,desired_family text not null,
    concept_id text unique not null,selection_reason text not null
  ) on commit drop;
  truncate pg_temp.phrasal_daily_plan;

  insert into pg_temp.phrasal_daily_plan(slot_no,bucket,desired_family,concept_id,selection_reason)
  select row_number() over(order by priority,coalesce(days_since_revision,1000000000) desc,concept_id)::int,
         'recognition','recognition',concept_id,reason
  from (
    select c.*,
      case when recognition_weak then 1 when recognition_attempts=0 then 2 when state='Persistent Weak' then 3
           when state='Weak' then 4 when due then 5 when state='Fragile' then 6 else 7 end priority,
      case when recognition_weak then 'Recognition Weak' when recognition_attempts=0 then 'Recognition Unproven'
           when state in ('Persistent Weak','Weak') then state when due then 'Due Recognition Maintenance'
           else 'Recognition Maintenance' end reason
    from pg_temp.phrasal_daily_concepts c
    order by priority,coalesce(days_since_revision,1000000000) desc,concept_id limit 4
  ) x;

  insert into pg_temp.phrasal_daily_plan(slot_no,bucket,desired_family,concept_id,selection_reason)
  select 4+row_number() over(order by priority,coalesce(days_since_revision,1000000000) desc,concept_id)::int,
         'usage_recall',desired_family,concept_id,reason
  from (
    select c.*,
      case when usage_weak then 'context_fill' when recall_weak then 'recall'
           when recognition_strong and usage_attempts=0 then 'context_fill'
           when recognition_strong and recall_attempts=0 then 'recall'
           when due then 'context_fill'
           else case when usage_attempts<=recall_attempts then 'context_fill' else 'recall' end end desired_family,
      case when usage_weak then 1 when recall_weak then 2 when recognition_strong and usage_attempts=0 then 3
           when recognition_strong and recall_attempts=0 then 4 when due then 5
           when state in ('Persistent Weak','Weak','Fragile') then 6 else 7 end priority,
      case when usage_weak then 'Contextual Usage Weak' when recall_weak then 'Active Recall Weak'
           when recognition_strong and usage_attempts=0 then 'Meaning Known · Usage Unproven'
           when recognition_strong and recall_attempts=0 then 'Meaning Known · Recall Unproven'
           when due then 'Due Transfer Practice' else 'Usage / Recall Rotation' end reason
    from pg_temp.phrasal_daily_concepts c
    where not exists(select 1 from pg_temp.phrasal_daily_plan p where p.concept_id=c.concept_id)
    order by priority,coalesce(days_since_revision,1000000000) desc,concept_id limit 8
  ) x;

  insert into pg_temp.phrasal_daily_plan(slot_no,bucket,desired_family,concept_id,selection_reason)
  select 12+row_number() over(order by priority,coalesce(days_since_revision,1000000000) desc,concept_id)::int,
         'confusion','confusion',concept_id,reason
  from (
    select c.*,
      case when confusion_weak then 1 when recognition_strong and confusion_attempts=0 then 2
           when usage_strong and confusion_attempts=0 then 3 when due then 4 when state='Strong' then 5
           when state in ('Fragile','Learning') then 6 else 7 end priority,
      case when confusion_weak then 'Confusion Weak'
           when recognition_strong and confusion_attempts=0 then 'Meaning Known · Contrast Unproven'
           when usage_strong and confusion_attempts=0 then 'Usage Known · Contrast Unproven'
           when due then 'Due Contrast Transfer' else 'Confusion / Contrast Rotation' end reason
    from pg_temp.phrasal_daily_concepts c
    where not exists(select 1 from pg_temp.phrasal_daily_plan p where p.concept_id=c.concept_id)
    order by priority,coalesce(days_since_revision,1000000000) desc,concept_id limit 8
  ) x;

  if (select count(*) from pg_temp.phrasal_daily_plan)<>20 then
    raise exception 'Phrasal Daily curriculum could not produce exact 20 unique concepts';
  end if;

  with exact_variant as (
    select p.slot_no,q.question_id,
      row_number() over(partition by p.slot_no order by
        count(a.*) filter(where lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')),
        coalesce(max(a.attempted_at) filter(where lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')),'epoch'::timestamptz),
        count(a.*),q.question_id) rn
    from pg_temp.phrasal_daily_plan p
    join english.questions q on coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=p.concept_id and q.active
    left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
    left join english.attempts a on a.user_id=uid and a.question_id=q.question_id
    where english.question_visible_to_user(uid,q.question_id) and not coalesce(s.mastered,false)
      and english.phrasal_effective_family(q)=p.desired_family
    group by p.slot_no,q.question_id
  ), variants as (
    select p.slot_no,jsonb_agg(jsonb_build_object('questionId',q.question_id,'family',english.phrasal_effective_family(q)) order by q.question_id) variants
    from pg_temp.phrasal_daily_plan p
    join english.questions q on coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=p.concept_id and q.active
    where english.question_visible_to_user(uid,q.question_id) group by p.slot_no
  ), assembled as (
    select p.slot_no,
      case when ev.question_id is not null then
        english.question_payload(uid,ev.question_id)||jsonb_build_object(
          'slotStatus','serviceable','contentGap',false,'phrasalConceptId',p.concept_id,
          'phrasalSelectionLane','daily_curriculum','dailyBucket',p.bucket,
          'phrasalLearningNeed',case when p.desired_family='context_fill' then 'usage' else p.desired_family end,
          'phrasalQuestionFamily',p.desired_family,'requestedQuestionFamily',p.desired_family,
          'phrasalSelectionReason',p.selection_reason)
      else jsonb_build_object(
          'slotStatus','content_gap','contentGap',true,'phrasalConceptId',p.concept_id,
          'phrasalSelectionLane','daily_curriculum','dailyBucket',p.bucket,
          'phrasalLearningNeed',case when p.desired_family='context_fill' then 'usage' else p.desired_family end,
          'missingFamily',p.desired_family,'requestedQuestionFamily',p.desired_family,
          'availableVariants',coalesce(v.variants,'[]'::jsonb),'phrasalSelectionReason',p.selection_reason)
      end j
    from pg_temp.phrasal_daily_plan p
    left join exact_variant ev on ev.slot_no=p.slot_no and ev.rn=1
    left join variants v on v.slot_no=p.slot_no
  )
  select coalesce(jsonb_agg(j order by slot_no),'[]'::jsonb) into out from assembled;
  return out;
end;
$function$;

grant execute on function public.english_get_phrasal_daily_curriculum_batch(integer) to authenticated;

-- Keep the established hybrid metadata decorator but stop its old fixed-six usage override
-- for the new Daily curriculum. The requested family from the 4/8/8 selector is authoritative.
create or replace function public.english_get_phrasal_hybrid_maintenance_batch(p_mode text default 'smart', p_count integer default 20)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare
  uid uuid:=auth.uid(); base jsonb; out jsonb:='[]'::jsonb; x jsonb; eligible_rank integer:=0;
  cid text; first_attempt timestamptz; attempt_count integer; pre_rollout boolean; mature boolean; context_eligible boolean;
  activation timestamptz; requested text; legacy_family text; sense text; sense_gloss text; recent jsonb; recent_stems jsonb;
  reference_variant jsonb; known_senses jsonb; selected_qid text; selected_variant_family text;
  selected_attempt_count integer:=0; recent_three_correct integer:=0; selected_variant_cooled boolean:=false;
  is_daily_curriculum boolean:=false;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  is_daily_curriculum:=lower(btrim(coalesce(p_mode,'smart')))='smart' and coalesce(p_count,20)=20;
  if is_daily_curriculum then base:=public.english_get_phrasal_daily_curriculum_batch(20);
  else base:=public.english_get_phrasal_maintenance_batch(p_mode,p_count); end if;
  if not english.ai_feature_enabled('phrasal_context_fill_v1') and not is_daily_curriculum then return base; end if;

  select activated_at into activation from english.ai_content_feature_flags where flag='phrasal_context_fill_v1';
  for x in select value from jsonb_array_elements(base) loop
    cid:=coalesce(nullif(x->>'phrasalConceptId',''),nullif(x->>'conceptId',''));
    legacy_family:=coalesce(nullif(x->>'phrasalQuestionFamily',''),nullif(x->>'missingFamily',''),'recognition');
    if legacy_family not in ('recognition','recall','confusion','context_fill') then legacy_family:='recognition'; end if;
    selected_qid:=coalesce(nullif(x->>'id',''),nullif(x->>'questionId',''));

    select min(a.attempted_at),count(a.*)::int into first_attempt,attempt_count
    from english.questions q left join english.attempts a on a.question_id=q.question_id and a.user_id=uid
    where coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid;

    selected_variant_family:=null; selected_attempt_count:=0; recent_three_correct:=0; selected_variant_cooled:=false;
    if selected_qid is not null then
      select v.question_family into selected_variant_family from english.phrasal_question_variants v where v.question_id=selected_qid;
    end if;
    if english.ai_feature_enabled('phrasal_variant_rotation_v1') and selected_qid is not null and selected_variant_family='context_fill' then
      select count(*)::int into selected_attempt_count from english.attempts a where a.user_id=uid and a.question_id=selected_qid;
      select count(*) filter(where z.correct)::int into recent_three_correct from (
        select a.correct from english.attempts a where a.user_id=uid and a.question_id=selected_qid
        order by a.attempted_at desc,a.created_at desc,a.attempt_id desc limit 3) z;
      selected_variant_cooled:=selected_attempt_count>=5 or (selected_attempt_count>=3 and recent_three_correct=3);
    end if;

    pre_rollout:=activation is not null and first_attempt is not null and first_attempt<activation;
    mature:=first_attempt is not null and attempt_count>=3 and first_attempt<=now()-interval '7 days';
    context_eligible:=pre_rollout or mature or selected_variant_cooled;
    if context_eligible then eligible_rank:=eligible_rank+1; end if;
    requested:=coalesce(nullif(x->>'requestedQuestionFamily',''),'');
    if requested='' then requested:=case when context_eligible and eligible_rank<=6 then 'context_fill' else legacy_family end; end if;

    sense:=null; sense_gloss:=null;
    if selected_qid is not null then select v.sense_key into sense from english.phrasal_question_variants v where v.question_id=selected_qid; end if;
    if sense is null then
      select s.sense_key,s.gloss into sense,sense_gloss from english.phrasal_concept_senses s
      where s.concept_id=cid and s.active order by s.priority desc,s.created_at,s.sense_key limit 1;
    else select s.gloss into sense_gloss from english.phrasal_concept_senses s where s.concept_id=cid and s.sense_key=sense and s.active; end if;
    sense:=coalesce(sense,'legacy_default');

    select coalesce(jsonb_agg(jsonb_build_object('senseKey',s.sense_key,'gloss',coalesce(s.gloss,''),'priority',s.priority)
      order by s.priority desc,s.created_at,s.sense_key),'[]'::jsonb) into known_senses
    from english.phrasal_concept_senses s where s.concept_id=cid and s.active;
    select coalesce(jsonb_agg(v.variant_fingerprint order by v.created_at desc) filter(where nullif(v.variant_fingerprint,'') is not null),'[]'::jsonb)
    into recent from (select * from english.phrasal_question_variants where concept_id=cid order by created_at desc limit 8) v;
    select coalesce(jsonb_agg(r.question order by r.last_attempt desc nulls last,r.question),'[]'::jsonb) into recent_stems
    from (select q.question,max(a.attempted_at) last_attempt from english.questions q
      left join english.attempts a on a.question_id=q.question_id and a.user_id=uid
      where q.active and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid and btrim(coalesce(q.question,''))<>''
      group by q.question order by max(a.attempted_at) desc nulls last,q.question limit 8) r;

    reference_variant:=x;
    if btrim(coalesce(reference_variant->>'question',''))='' and btrim(coalesce(reference_variant->>'explanation',''))=''
       and btrim(coalesce(reference_variant->>'word',''))='' then
      select english.question_payload(uid,q.question_id) into reference_variant from english.questions q
      where q.active and english.question_visible_to_user(uid,q.question_id)
        and coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid
      order by case when english.phrasal_effective_family(q)=requested then 0
                    when english.phrasal_effective_family(q)=legacy_family then 1 else 2 end,q.question_id limit 1;
    end if;

    out:=out||jsonb_build_array(x||jsonb_build_object(
      'senseKey',sense,'senseGloss',coalesce(sense_gloss,''),'knownSenses',coalesce(known_senses,'[]'::jsonb),
      'requestedQuestionFamily',requested,'legacyFamily',legacy_family,
      'historicalExposureBeforeRollout',pre_rollout,'contextMaturityEligible',mature,'contextEligible',context_eligible,
      'selectedVariantCooled',selected_variant_cooled,'selectedVariantAttemptCount',selected_attempt_count,
      'recentVariantFingerprints',coalesce(recent,'[]'::jsonb),'recentConceptStems',coalesce(recent_stems,'[]'::jsonb),
      'referenceVariant',coalesce(reference_variant,'{}'::jsonb),
      'contextBootstrapRank',case when context_eligible then eligible_rank else null end));
  end loop;
  return out;
end;
$function$;
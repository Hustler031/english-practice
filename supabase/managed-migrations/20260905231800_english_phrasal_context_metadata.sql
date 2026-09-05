-- Additive Phrasal concept -> sense -> family -> variant metadata.
-- Legacy questions remain valid with concept-level/family fallback.

create table if not exists english.phrasal_concept_senses (
  concept_id text not null,
  sense_key text not null,
  gloss text,
  active boolean not null default true,
  priority integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(concept_id,sense_key)
);
alter table english.phrasal_concept_senses enable row level security;
revoke all on english.phrasal_concept_senses from public, anon, authenticated;
grant select,insert,update on english.phrasal_concept_senses to service_role;

create table if not exists english.phrasal_question_variants (
  question_id text primary key references english.questions(question_id) on delete cascade,
  concept_id text not null,
  sense_key text,
  question_family text not null check (question_family in ('recognition','recall','confusion','context_fill')),
  variant_key text,
  variant_fingerprint text,
  generator_provider text,
  critic_provider text,
  quality_score numeric,
  critic_decision text,
  repair_count integer not null default 0 check (repair_count between 0 and 2),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table english.phrasal_question_variants enable row level security;
revoke all on english.phrasal_question_variants from public, anon, authenticated;
grant select,insert,update on english.phrasal_question_variants to service_role;
create unique index if not exists phrasal_question_variants_fingerprint_uq
  on english.phrasal_question_variants(concept_id,variant_fingerprint)
  where nullif(variant_fingerprint,'') is not null;
create index if not exists phrasal_question_variants_concept_family_idx
  on english.phrasal_question_variants(concept_id,question_family,created_at desc);

create or replace function english.phrasal_effective_family(q english.questions)
returns text
language sql stable security definer
set search_path='pg_catalog','english'
as $$
select coalesce(
  (select v.question_family from english.phrasal_question_variants v where v.question_id=q.question_id),
  english.phrasal_question_family(q)
)
$$;
revoke all on function english.phrasal_effective_family(english.questions) from public, anon;
grant execute on function english.phrasal_effective_family(english.questions) to authenticated, service_role;

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
    requested:=case when context_eligible and eligible_rank<=8 then 'context_fill' else legacy_family end;

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

-- Additive evidence read model for richer sense/family analysis. It does not
-- replace or mutate the existing concept-level Central Intelligence state.
create or replace function public.english_get_phrasal_sense_evidence(p_concept_id text default null)
returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  uid uuid:=auth.uid();
  result jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'conceptId',e.concept_id,
    'senseKey',e.sense_key,
    'senseGloss',coalesce(s.gloss,''),
    'questionFamily',e.question_family,
    'attempts',e.attempts,
    'correct',e.correct_count,
    'accuracy',case when e.attempts>0 then round((e.correct_count::numeric/e.attempts::numeric)*100,1) else null end,
    'distinctVariants',e.distinct_variants,
    'lastAttempt',e.last_attempt
  ) order by e.last_attempt desc nulls last,e.concept_id,e.sense_key,e.question_family),'[]'::jsonb)
  into result
  from (
    select v.concept_id,coalesce(nullif(v.sense_key,''),'legacy_default') sense_key,v.question_family,
      count(a.*)::int attempts,
      count(a.*) filter(where a.correct)::int correct_count,
      count(distinct v.question_id)::int distinct_variants,
      max(a.attempted_at) last_attempt
    from english.phrasal_question_variants v
    join english.attempts a on a.question_id=v.question_id and a.user_id=uid
    where p_concept_id is null or v.concept_id=p_concept_id
    group by v.concept_id,coalesce(nullif(v.sense_key,''),'legacy_default'),v.question_family
  ) e
  left join english.phrasal_concept_senses s on s.concept_id=e.concept_id and s.sense_key=e.sense_key;
  return coalesce(result,'[]'::jsonb);
end $$;
revoke all on function public.english_get_phrasal_sense_evidence(text) from public, anon;
grant execute on function public.english_get_phrasal_sense_evidence(text) to authenticated, service_role;

create or replace function english.maintenance_phrasal_batch(p_count integer default 20)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid; v_owner_count integer;
  v_count integer:=greatest(1,least(20,coalesce(p_count,20)));
  v_items jsonb; v_day date:=(now() at time zone 'Asia/Kolkata')::date; v_source_id text;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_items:=case when english.ai_feature_enabled('phrasal_context_fill_v1')
    then public.english_get_phrasal_hybrid_maintenance_batch('smart',v_count)
    else public.english_get_phrasal_maintenance_batch('smart',v_count) end;
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  return jsonb_build_object('ok',true,'date',v_day,'sourceId',v_source_id,'sourceFile','Phrasal Daily '||to_char(v_day,'YYYY-MM-DD'),
    'count',jsonb_array_length(coalesce(v_items,'[]'::jsonb)),'existingToday',(select count(*) from english.questions q where q.active and q.source_id=v_source_id),'items',coalesce(v_items,'[]'::jsonb));
end $$;

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
  recent jsonb;
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

    select min(a.attempted_at),count(a.*)::int
    into first_attempt,attempt_count
    from english.questions q
    left join english.attempts a on a.question_id=q.question_id and a.user_id=uid
    where coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=cid;

    pre_rollout:=activation is not null and first_attempt is not null and first_attempt<activation;
    mature:=first_attempt is not null and attempt_count>=3 and first_attempt<=now()-interval '7 days';
    -- A contextual item is an ordinary four-option MCQ. Do not substitute it into a
    -- recall self-assessment or confusion-specific legacy slot; this preserves old card semantics.
    context_eligible:=(pre_rollout or mature) and legacy_family='recognition';
    if context_eligible then eligible_rank:=eligible_rank+1; end if;

    requested:=case
      when context_eligible and eligible_rank<=8 then 'context_fill'
      else legacy_family
    end;

    select s.sense_key into sense
    from english.phrasal_concept_senses s
    where s.concept_id=cid and s.active
    order by s.priority desc,s.created_at,s.sense_key limit 1;
    sense:=coalesce(sense,'legacy_default');

    select coalesce(jsonb_agg(v.variant_fingerprint order by v.created_at desc)
      filter(where nullif(v.variant_fingerprint,'') is not null),'[]'::jsonb)
    into recent
    from (select * from english.phrasal_question_variants where concept_id=cid order by created_at desc limit 8) v;

    out:=out||jsonb_build_array(x||jsonb_build_object(
      'senseKey',sense,
      'requestedQuestionFamily',requested,
      'legacyFamily',legacy_family,
      'historicalExposureBeforeRollout',pre_rollout,
      'contextMaturityEligible',mature,
      'contextEligible',context_eligible,
      'recentVariantFingerprints',coalesce(recent,'[]'::jsonb),
      'contextBootstrapRank',case when context_eligible then eligible_rank else null end
    ));
  end loop;
  return out;
end $$;
revoke all on function public.english_get_phrasal_hybrid_maintenance_batch(text,integer) from public, anon;
grant execute on function public.english_get_phrasal_hybrid_maintenance_batch(text,integer) to authenticated, service_role;

create or replace function english.maintenance_phrasal_batch(p_count integer default 20)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare
  v_owner uuid;
  v_owner_count integer;
  v_count integer:=greatest(1,least(20,coalesce(p_count,20)));
  v_items jsonb;
  v_day date:=(now() at time zone 'Asia/Kolkata')::date;
  v_source_id text;
begin
  select count(*),max(u.id::text)::uuid into v_owner_count,v_owner
  from auth.users u where u.deleted_at is null;
  if v_owner_count<>1 then raise exception 'Phrasal maintenance requires exactly one active auth owner'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_items:=case when english.ai_feature_enabled('phrasal_context_fill_v1')
    then public.english_get_phrasal_hybrid_maintenance_batch('smart',v_count)
    else public.english_get_phrasal_maintenance_batch('smart',v_count) end;
  v_source_id:='PHRASAL_DAILY_'||to_char(v_day,'YYYYMMDD');
  return jsonb_build_object(
    'ok',true,'date',v_day,'sourceId',v_source_id,'sourceFile','Phrasal Daily '||to_char(v_day,'YYYY-MM-DD'),
    'count',jsonb_array_length(coalesce(v_items,'[]'::jsonb)),
    'existingToday',(select count(*) from english.questions q where q.active and q.source_id=v_source_id),
    'items',coalesce(v_items,'[]'::jsonb)
  );
end $$;

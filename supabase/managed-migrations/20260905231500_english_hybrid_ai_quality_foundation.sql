-- English V2 hybrid AI quality foundation.
-- Additive only. All rollout flags default OFF until validation succeeds.

create table if not exists english.ai_content_feature_flags (
  flag text primary key,
  enabled boolean not null default false,
  activated_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint ai_content_feature_flags_name check (flag in (
    'gemini_content_v1','groq_critic_v1','phrasal_sense_v1','phrasal_context_fill_v1',
    'phrasal_variant_rotation_v1','chatgpt_sprint_v1','hindu_tone_v1'
  ))
);

insert into english.ai_content_feature_flags(flag) values
 ('gemini_content_v1'),('groq_critic_v1'),('phrasal_sense_v1'),('phrasal_context_fill_v1'),
 ('phrasal_variant_rotation_v1'),('chatgpt_sprint_v1'),('hindu_tone_v1')
on conflict(flag) do nothing;

alter table english.ai_content_feature_flags enable row level security;
revoke all on english.ai_content_feature_flags from public, anon, authenticated;
grant select,insert,update on english.ai_content_feature_flags to service_role;

create or replace function english.ai_feature_enabled(p_flag text)
returns boolean
language sql stable security definer
set search_path='pg_catalog','english'
as $$
  select coalesce((select enabled from english.ai_content_feature_flags where flag=p_flag),false)
$$;
revoke all on function english.ai_feature_enabled(text) from public, anon;
grant execute on function english.ai_feature_enabled(text) to authenticated, service_role;

create or replace function public.english_set_ai_content_feature(p_flag text,p_enabled boolean)
returns jsonb
language plpgsql security definer
set search_path='pg_catalog','public','english'
as $$
declare r english.ai_content_feature_flags%rowtype;
begin
  if p_flag not in ('gemini_content_v1','groq_critic_v1','phrasal_sense_v1','phrasal_context_fill_v1','phrasal_variant_rotation_v1','chatgpt_sprint_v1','hindu_tone_v1') then
    raise exception 'Unknown English AI feature flag';
  end if;
  insert into english.ai_content_feature_flags(flag,enabled,activated_at,updated_at)
  values(p_flag,coalesce(p_enabled,false),case when p_enabled then now() else null end,now())
  on conflict(flag) do update set
    enabled=excluded.enabled,
    activated_at=case when excluded.enabled then coalesce(english.ai_content_feature_flags.activated_at,now()) else english.ai_content_feature_flags.activated_at end,
    updated_at=now()
  returning * into r;
  return jsonb_build_object('ok',true,'flag',r.flag,'enabled',r.enabled,'activatedAt',r.activated_at);
end $$;
revoke all on function public.english_set_ai_content_feature(text,boolean) from public, anon, authenticated;
grant execute on function public.english_set_ai_content_feature(text,boolean) to service_role;

create table if not exists english.content_generation_audits (
  audit_id uuid primary key default gen_random_uuid(),
  lane text not null check (lane in ('phrasal','hindu','saved','tone','sprint')),
  entity_key text,
  generator_provider text not null,
  generator_model text,
  critic_provider text,
  critic_model text,
  quality_score numeric,
  critic_decision text,
  repair_count integer not null default 0 check (repair_count between 0 and 2),
  question_family text,
  sense_key text,
  variant_key text,
  variant_fingerprint text,
  publication_result text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table english.content_generation_audits enable row level security;
revoke all on english.content_generation_audits from public, anon, authenticated;
grant select,insert,update on english.content_generation_audits to service_role;
create index if not exists content_generation_audits_lane_created_idx on english.content_generation_audits(lane,created_at desc);

create or replace function english.generated_item_hard_gates_pass(p_item jsonb)
returns boolean
language sql immutable
set search_path='pg_catalog'
as $$
select
  coalesce((p_item->'quality'->>'score')::numeric,0) >= 85
  and upper(coalesce(p_item->'quality'->>'decision','')) in ('PASS','PASS_WITH_MINOR_ISSUES')
  and coalesce((p_item->'quality'->'hardGates'->>'exactlyOneCorrect')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'correctKeyMatches')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'linguisticallyValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'conceptPreserved')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'sensePreserved')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'learnerRequestPreserved')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noFactualError')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noLexicalGrammarError')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'requiredOptionsValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'explanationMatchesQuestion')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'explanationMatchesAnswer')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noStaleExplanation')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noAmbiguity')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'noSecondCorrectOption')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'intentSpecificTaskValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'questionFamilyValid')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'plausibleDistractors')::boolean,false)
  and coalesce((p_item->'quality'->'hardGates'->>'distractorsNotObvious')::boolean,false)
$$;

create or replace function english.assert_generated_items_quality(p_items jsonb,p_allow_needs_review boolean default false)
returns void
language plpgsql immutable
set search_path='pg_catalog','english'
as $$
declare x jsonb; n integer:=0;
begin
  if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' then
    raise exception 'Generated payload must be an array';
  end if;
  for x in select value from jsonb_array_elements(p_items) loop
    n:=n+1;
    if p_allow_needs_review and lower(coalesce(x->>'gptStatus',''))='needs review' then continue; end if;
    if not english.generated_item_hard_gates_pass(x) then raise exception 'AI quality gate rejected item %',n; end if;
  end loop;
end $$;

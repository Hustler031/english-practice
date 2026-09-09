-- Make non-meaning My Saved enrichment deterministic at the writer boundary.
--
-- The worker already receives authoritative requiredQuestionFamily / requiredLearningIntent
-- and keeps strict deterministic + Luna quality gates. The failure mode was earlier:
-- lower writer tiers could still interpret a generic context as a semantic vocabulary task,
-- so valid SM / USAGE / CU / CONFUSION requests repeatedly failed the existing gates.
-- Inject a short family-specific generation contract into the worker-only context payload.
-- The stored learner context is not modified and the quality gates are not weakened.

create or replace function english.saved_enrichment_prepare_worker_item(p_item jsonb)
returns jsonb
language sql
immutable
set search_path to 'pg_catalog','english'
as $function$
with x as (
  select
    coalesce(p_item,'{}'::jsonb) as item,
    btrim(coalesce(p_item->>'context','')) as learner_context,
    upper(btrim(coalesce(p_item->>'captureType','AUTO'))) as capture_type,
    upper(btrim(coalesce(p_item->>'resolvedType','V'))) as resolved_type,
    upper(btrim(coalesce(p_item->>'requiredLearningIntent','MEANING'))) as learning_intent
), y as (
  select *, case when capture_type in ('V','SM','OWS','PV','IP','CU') then capture_type else resolved_type end as family
  from x
), z as (
  select *,
    case
      when family='SM' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is an SM spelling-confusion task. The MCQ stem MUST explicitly test spelling/correctly-written/incorrectly-written form. Keep the learner-supplied confusable targets together where relevant. Use four plausible orthographic/spelling candidates with exactly one defensible answer. Do not turn this into a synonym or generic meaning question. Meaning/explanation may teach lexical distinctions, but the tested question must remain spelling-family.'
      when family='SM' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is an SM spelling task regardless of how the raw request is phrased. The MCQ stem MUST explicitly test spelling/correctly-written/incorrectly-written form. For a single target, use four plausible spelling variants from the same orthographic family with exactly one standard spelling. Do not turn this into a synonym, fill-in-the-blank, or generic meaning question.'
      when family='CU' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is a CU grammar/usage/confusable-rule task. Keep all supplied confusable targets together in one diagnostic MCQ. The stem and/or explanation must make the usage/grammar/distinction explicit, with exactly one defensible answer. Do not reduce it to a generic synonym question.'
      when family='CU' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is a CU grammar/usage rule task. Test the actual rule, collocation, grammatical distinction, or correct usage explicitly. Use exactly one defensible answer and explain why A, B, C and D succeed or fail under the rule.'
      when family='V' and learning_intent='USAGE' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is V vocabulary USAGE, not a direct-meaning card. Test natural contextual use, collocation, or sentence fit of the target. Make all four options plausible and exactly one idiomatic/semantically correct in context. Explain A, B, C and D explicitly.'
      when family='V' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is V vocabulary CONFUSION. Keep every learner-supplied confusable target together in the same diagnostic MCQ and contrast their precise meanings/usages. Do not ask only for the synonym/meaning of one target. Exactly one option must be defensible; explain A, B, C and D.'
      when family='OWS' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is an OWS confusion task. Keep the supplied one-word-substitution terms together and test the exact definition-to-term distinctions in one diagnostic MCQ. Exactly one answer; explain every option.'
      when family='OWS' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is a one-word-substitution task. Test the precise definition or scenario against four plausible OWS terms, with exactly one defensible answer and A-D explanation.'
      when family='PV' and learning_intent='USAGE' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is phrasal-verb USAGE. Test the target phrasal verb in a natural sentence/collocation and preserve its particle(s). Use exactly one idiomatic answer and explain A-D.'
      when family='PV' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is phrasal-verb CONFUSION. Keep the supplied phrasal verbs together and diagnose their meaning/usage distinctions in one MCQ. Exactly one defensible answer; explain A-D.'
      when family='PV' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is a phrasal-verb task. Test the actual phrasal-verb meaning/recall, preserving its particle(s), with four plausible same-domain choices and exactly one answer.'
      when family='IP' and learning_intent='USAGE' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is idiom/phrase USAGE. Test the idiom in a natural context, not as a bare unrelated vocabulary item. Exactly one idiomatic answer; explain A-D.'
      when family='IP' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is idiom/phrase CONFUSION. Keep the supplied phrases together and test their precise contextual distinctions in one MCQ. Exactly one answer; explain A-D.'
      when family='IP' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is an idiom/phrase task. Test its precise idiomatic meaning with four plausible choices and exactly one defensible answer.'
      when learning_intent='USAGE' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): The required learning intent is USAGE. Test natural use/collocation/contextual fit rather than only asking for a direct meaning. Exactly one answer; explain A-D.'
      when learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): The required learning intent is CONFUSION. Keep all supplied confusable targets together in the same diagnostic MCQ. Do not collapse to a one-target synonym question. Exactly one answer; explain A-D.'
      else
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): Preserve the required question family and learning intent exactly. Use four plausible distinct SSC-level options, exactly one defensible answer, and explain A-D.'
    end as worker_contract
  from y
)
select jsonb_set(
  item,
  '{context}',
  to_jsonb(concat_ws(E'\n\n', nullif(learner_context,''), worker_contract)),
  true
)
from z;
$function$;

revoke all on function english.saved_enrichment_prepare_worker_item(jsonb) from public,anon,authenticated;
grant execute on function english.saved_enrichment_prepare_worker_item(jsonb) to service_role;

create or replace function public.english_saved_enrichment_worker_claim(p_token text, p_limit integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','english'
as $function$
declare
  v_lease uuid;
  v_expires timestamptz;
  v_new_lease uuid;
  v_raw jsonb;
  v_items jsonb;
  v_batch jsonb;
  v_limit integer:=1;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;

  update english.saved_enrichment_item_state es
  set state='retrying',
      attempt_count=greatest(es.attempt_count-1,0),
      transient_failure_count=es.transient_failure_count+1,
      lease_id=null,
      last_error=coalesce(es.last_error,'stale saved-enrichment processing recovered'),
      last_error_at=now(),
      last_error_class='lease_timeout',
      next_attempt_at=now()+interval '15 minutes',
      updated_at=now()
  where es.state='processing'
    and es.updated_at<now()-interval '12 minutes';

  select lease_id,lease_expires_at into v_lease,v_expires
  from english.saved_enrichment_worker_state where singleton=true for update;

  if v_lease is not null and v_expires is not null and v_expires>now() then
    return jsonb_build_object('ok',true,'busy',true,'count',0,'items','[]'::jsonb);
  end if;

  v_raw:=english.maintenance_saved_enrichment_batch(25);
  select coalesce(jsonb_agg(english.saved_enrichment_prepare_worker_item(j) order by ord),'[]'::jsonb)
  into v_items
  from (
    select j,ord
    from jsonb_array_elements(coalesce(v_raw->'items','[]'::jsonb)) with ordinality x(j,ord)
    join english.saved_items s on s.saved_id=j->>'savedId' and s.active
    left join english.saved_enrichment_item_state es on es.user_id=s.user_id and es.saved_id=s.saved_id
    where coalesce(es.state,'') not in ('processing','failed')
      and not (coalesce(es.state,'')='retrying' and es.next_attempt_at is not null and es.next_attempt_at>now())
    order by ord
    limit v_limit
  ) picked;

  v_batch:=jsonb_build_object('ok',true,'count',jsonb_array_length(v_items),'items',v_items);
  if jsonb_array_length(v_items)=0 then
    update english.saved_enrichment_worker_state
    set lease_id=null,lease_expires_at=null,last_started_at=now(),last_finished_at=now(),last_count=0,last_error=null,updated_at=now()
    where singleton=true;
    return v_batch||jsonb_build_object('busy',false,'leaseId',null);
  end if;

  v_new_lease:=gen_random_uuid();
  update english.saved_enrichment_worker_state
  set lease_id=v_new_lease,lease_expires_at=now()+interval '10 minutes',last_started_at=now(),last_error=null,updated_at=now()
  where singleton=true;

  insert into english.saved_enrichment_item_state(user_id,saved_id,state,attempt_count,lease_id,last_attempt_at,next_attempt_at,updated_at)
  select s.user_id,j->>'savedId','processing',1,v_new_lease,now(),null,now()
  from jsonb_array_elements(v_items) j
  join english.saved_items s on s.saved_id=j->>'savedId' and s.active
  on conflict(user_id,saved_id) do update set
    state='processing',attempt_count=english.saved_enrichment_item_state.attempt_count+1,lease_id=excluded.lease_id,
    last_attempt_at=excluded.last_attempt_at,next_attempt_at=null,updated_at=now();

  return v_batch||jsonb_build_object('busy',false,'leaseId',v_new_lease);
end
$function$;

revoke all on function public.english_saved_enrichment_worker_claim(text,integer) from public,anon,authenticated;
grant execute on function public.english_saved_enrichment_worker_claim(text,integer) to service_role;

-- Static contract smoke checks: these fail the migration if worker metadata is not
-- specialized for the two production failure families seen on 2026-09-09.
do $check$
declare
  v_sm text;
  v_usage text;
begin
  v_sm := english.saved_enrichment_prepare_worker_item(jsonb_build_object(
    'savedId','TEST_SM','context','','captureType','SM','resolvedType','SM','requiredLearningIntent','MEANING'
  ))->>'context';
  if v_sm !~ 'spelling task' or v_sm !~ 'MCQ stem MUST explicitly test spelling' then
    raise exception 'Saved SM worker contract smoke check failed';
  end if;

  v_usage := english.saved_enrichment_prepare_worker_item(jsonb_build_object(
    'savedId','TEST_USAGE','context','','captureType','V','resolvedType','V','requiredLearningIntent','USAGE'
  ))->>'context';
  if v_usage !~ 'vocabulary USAGE' or v_usage !~ 'natural contextual use' then
    raise exception 'Saved USAGE worker contract smoke check failed';
  end if;
end
$check$;

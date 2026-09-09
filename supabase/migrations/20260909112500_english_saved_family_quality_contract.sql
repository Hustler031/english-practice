-- Tighten non-simple My Saved writer guidance without changing learner data,
-- category semantics, deterministic hard gates, or Luna's >=85 PASS threshold.
-- The two strengthened patterns were validated against the live Luna critic:
-- SM spelling pattern: 96/PASS; V+USAGE confusable-neighbour pattern: 97/PASS.

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
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is an SM spelling-confusion task. The MCQ stem MUST explicitly test spelling/correctly-written/incorrectly-written form. Keep the learner-supplied confusable targets together where relevant. Every wrong spelling must be a realistic orthographic neighbour, not gibberish: use a plausible single spelling error such as one omitted/extra/replaced letter, a consonant-doubling error, or a suffix/vowel error. Exactly one option must be standard. Explanation must identify the precise spelling defect in A, B, C and D. Do not turn this into a synonym or generic meaning question.'
      when family='SM' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is an SM spelling task regardless of origin context. Use the proven SSC pattern: an explicit correctly-spelt/incorrectly-spelt stem, preferably with a short accurate meaning clue for the target; the standard target spelling as exactly one option; and three close spelling variants. EACH wrong variant must contain one plausible orthographic error only (for example one omitted/extra/replaced letter, consonant doubling, or suffix/vowel error), stay visually close to the target, and never be random gibberish. Do not use semantic definitions or sentence-length options. Explanation must explicitly label A-D and name the exact spelling error in every wrong option.'
      when family='CU' and learning_intent='CONFUSION' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is a CU grammar/usage/confusable-rule task. Keep all supplied confusable targets together in one diagnostic MCQ. The stem and/or explanation must make the usage/grammar/distinction explicit, with exactly one defensible answer. Do not reduce it to a generic synonym question.'
      when family='CU' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is a CU grammar/usage rule task. Test the actual rule, collocation, grammatical distinction, or correct usage explicitly. Use exactly one defensible answer and explain why A, B, C and D succeed or fail under the rule.'
      when family='V' and learning_intent='USAGE' then
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): This is V vocabulary USAGE, not a direct-meaning card. Prefer an SSC-style "Which sentence uses the target correctly?" task with four complete, natural-looking sentence options. The correct sentence must use the target in its exact sense/collocation. EVERY wrong sentence must be a realistic same-neighbourhood trap that would become natural if the target were replaced by one specific confusable or close usage competitor; prefer orthographic/lexical confusables, near-neighbour verbs, or collocational competitors. Never use a plainly direct antonym/opposite as the sole trap, an unrelated meaning, absurd context, or obviously ungrammatical filler. In the explanation, explicitly label A-D and NAME the better replacement/confusable for each wrong sentence. Preserve exactly one defensible answer.'
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
        'GENERATION CONTRACT (authoritative worker metadata, not learner prose): The required learning intent is USAGE. Test natural use/collocation/contextual fit rather than direct meaning. Wrong options must be realistic same-neighbourhood competitors, never plain antonyms or unrelated filler, and the A-D explanation must state the exact replacement/usage distinction. Exactly one answer.'
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

comment on function english.saved_enrichment_prepare_worker_item(jsonb) is
  'Adds authoritative non-persistent writer guidance to My Saved claim payloads. SM and USAGE guidance enforces Luna-validated hard-distractor patterns without changing saved learner context.';

-- Keep the learner's saved target authoritative during My Saved enrichment.
-- The source question can be only a capture location (including when the learner saved a distractor),
-- so source context must never redefine the saved target.

CREATE OR REPLACE FUNCTION english.saved_enrichment_prepare_worker_item(p_item jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO 'pg_catalog', 'english'
AS $function$
with x as (
  select
    coalesce(p_item,'{}'::jsonb) as item,
    btrim(coalesce(p_item->>'context','')) as learner_context,
    btrim(coalesce(p_item->>'word','')) as saved_target,
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
  to_jsonb(concat_ws(E'\n\n',
    case when saved_target<>'' then
      'PRIMARY SAVED TARGET (AUTHORITATIVE): "'||saved_target||'". Generate the enrichment for this exact saved target only. The origin/source question or context may describe the parent question, its correct answer, or another option because the learner can save a distractor; it is supporting context only and MUST NEVER replace or redefine the saved target. If family=V and requiredLearningIntent=MEANING, anchor the target explicitly in the final MCQ: either the question must contain the saved target or the correct option text must be exactly the saved target.'
    end,
    nullif(learner_context,''),
    worker_contract
  )),
  true
)
from z;
$function$;

CREATE OR REPLACE FUNCTION public.english_saved_enrichment_worker_apply(p_token text, p_lease_id uuid, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'english'
AS $function$
declare
  x jsonb;
  v_saved_id text;
  v_saved_word text;
  v_capture text;
  v_resolved text;
  v_family text;
  v_required_intent text;
  v_question text;
  v_correct_key text;
  v_correct_text text;
  v_target_norm text;
  v_question_norm text;
  v_correct_norm text;
  v_word_count integer;
begin
  if not english.context_worker_authorized(p_token) then raise exception 'saved enrichment worker unauthorized'; end if;
  if not exists(select 1 from english.saved_enrichment_worker_state where singleton=true and lease_id=p_lease_id and lease_expires_at>now()) then raise exception 'saved enrichment worker lease is missing or expired'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Saved enrichment items must be an array'; end if;

  for x in select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    v_saved_id:=btrim(coalesce(x->>'savedId',''));
    select s.word,coalesce(t.capture_type,'AUTO'),coalesce(t.resolved_type,'V')
      into v_saved_word,v_capture,v_resolved
    from english.saved_items s
    left join english.saved_item_types t on t.user_id=s.user_id and t.saved_id=s.saved_id
    where s.saved_id=v_saved_id and s.active
    limit 1;
    if not found then raise exception 'Saved enrichment item % does not exist',v_saved_id; end if;

    if upper(btrim(coalesce(x->>'captureType','')))<>v_capture then
      raise exception 'Saved item % capture type mismatch: expected %, got %',v_saved_id,v_capture,coalesce(x->>'captureType','');
    end if;

    v_family:=case when v_capture='AUTO' then v_resolved else v_capture end;
    v_required_intent:=upper(btrim(coalesce(x->>'requiredLearningIntent','MEANING')));
    v_question:=btrim(coalesce(x->>'question',''));

    if v_family='SM' and v_question !~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)' then
      raise exception 'Saved item % resolves to SM but generated question is not spelling-family',v_saved_id;
    end if;
    if v_family='V' and v_question ~* '(spell|spelt|spelled|misspell|correctly[[:space:]]+written|incorrectly[[:space:]]+written)' then
      raise exception 'Saved item % resolves to V but generated question is spelling-family',v_saved_id;
    end if;

    v_word_count:=coalesce(array_length(regexp_split_to_array(btrim(coalesce(v_saved_word,'')),'[[:space:]]+'),1),0);
    if v_family='V'
       and v_required_intent='MEANING'
       and btrim(coalesce(v_saved_word,''))<>''
       and char_length(btrim(v_saved_word))<=70
       and v_word_count<=3
       and v_saved_word !~ '[,/;]'
       and lower(v_saved_word) !~ '(^|[[:space:]])(and|vs|versus)([[:space:]]|$)'
    then
      v_correct_key:=upper(btrim(coalesce(x->>'correctOption','')));
      v_correct_text:=case v_correct_key
        when 'A' then coalesce(x->>'optionA','')
        when 'B' then coalesce(x->>'optionB','')
        when 'C' then coalesce(x->>'optionC','')
        when 'D' then coalesce(x->>'optionD','')
        else '' end;
      v_target_norm:=btrim(regexp_replace(lower(v_saved_word),'[^a-z0-9]+',' ','g'));
      v_question_norm:=btrim(regexp_replace(lower(v_question),'[^a-z0-9]+',' ','g'));
      v_correct_norm:=btrim(regexp_replace(lower(v_correct_text),'[^a-z0-9]+',' ','g'));
      if v_target_norm<>''
         and position(' '||v_target_norm||' ' in ' '||v_question_norm||' ')=0
         and v_correct_norm<>v_target_norm
      then
        raise exception 'Saved item % target identity mismatch: generated item does not test authoritative saved target "%"',v_saved_id,v_saved_word;
      end if;
    end if;
  end loop;

  if english.ai_feature_enabled('groq_critic_v1') then perform english.assert_generated_items_quality(p_items,true); end if;
  return english.maintenance_apply_saved_enrichment(p_items);
end;
$function$;

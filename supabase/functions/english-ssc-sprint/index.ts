import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const allowedModes = new Set(["standard", "weakness", "trap", "mistakes"]);
const counts: Record<string, number> = { standard: 25, weakness: 15, trap: 15, mistakes: 10 };
const diagnosisLabels = ["Knowledge Gap", "Confusion", "Rule Gap", "Careless", "Time Pressure", "Misread", "Distractor Trap"];
const actions = ["Targeted Mastery", "Weakness Drill", "Trap Practice", "Execution Review", "No Route Change"];
const model = "gpt-5.6-luna";

type Slot = { position: number; difficultyTier: "Easy"|"Moderate"|"Hard"; domain?: "GrammarTransformation"|"LexicalUsage" };
type Usage = { input: number; output: number; reasoning: number; total: number };
type AiResult = { data: any; usage: Usage; responseId: string; model: string };

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

function outputText(payload: any) {
  if (typeof payload?.output_text === "string") return payload.output_text;
  for (const item of payload?.output || []) {
    for (const content of item?.content || []) {
      if (content?.type === "output_text" && typeof content.text === "string") return content.text;
    }
  }
  return "";
}

function usageFrom(payload: any): Usage {
  const u = payload?.usage || {};
  const input = Number(u.input_tokens || 0);
  const output = Number(u.output_tokens || 0);
  const reasoning = Number(u.output_tokens_details?.reasoning_tokens || u.reasoning_tokens || 0);
  const total = Number(u.total_tokens || input + output);
  return {
    input: Number.isFinite(input) ? Math.max(0, input) : 0,
    output: Number.isFinite(output) ? Math.max(0, output) : 0,
    reasoning: Number.isFinite(reasoning) ? Math.max(0, reasoning) : 0,
    total: Number.isFinite(total) ? Math.max(0, total) : 0,
  };
}

async function openaiJson(name: string, schema: Record<string, unknown>, instructions: string, input: unknown): Promise<AiResult> {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("OPENAI_API_KEY is not configured for english-ssc-sprint");
  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Authorization": `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      reasoning: { effort: "medium" },
      instructions,
      input: JSON.stringify(input),
      text: { format: { type: "json_schema", name, strict: true, schema } },
    }),
  });
  const raw = await res.json();
  if (!res.ok) throw new Error(raw?.error?.message || `OpenAI request failed (${res.status})`);
  const text = outputText(raw);
  if (!text) throw new Error("OpenAI returned no structured output");
  return { data: JSON.parse(text), usage: usageFrom(raw), responseId: String(raw?.id || ""), model: String(raw?.model || model) };
}

async function logUsage(
  supabase: any,
  requestGroup: string,
  requestType: string,
  mode: string,
  result: AiResult,
  sessionId: string | null = null,
  metadata: Record<string, unknown> = {},
) {
  try {
    await supabase.rpc("english_log_sprint_ai_usage", {
      p_request_group: requestGroup,
      p_request_type: requestType,
      p_mode: mode,
      p_model: result.model,
      p_input_tokens: result.usage.input,
      p_output_tokens: result.usage.output,
      p_reasoning_tokens: result.usage.reasoning,
      p_total_tokens: result.usage.total,
      p_response_id: result.responseId || null,
      p_session_id: sessionId,
      p_metadata: metadata,
    });
  } catch {
    // Cost telemetry must never make a valid Sprint unavailable.
  }
}

const optionSchema = {
  type: "object", additionalProperties: false, required: ["key", "text"],
  properties: {
    key: { type: "string", enum: ["A", "B", "C", "D"] },
    text: { type: "string", minLength: 1 },
  },
};

function sprintSchema(count: number) {
  return {
    type: "object", additionalProperties: false, required: ["items"], properties: {
      items: {
        type: "array", minItems: count, maxItems: count, items: {
          type: "object", additionalProperties: false,
          required: [
            "itemKey", "category", "questionType", "question", "options", "correctKey",
            "explanation", "sourceType", "canonicalQuestionId", "ambiguous", "qualityScore", "metadata",
          ],
          properties: {
            itemKey: { type: "string", minLength: 1 },
            category: { type: "string", minLength: 1 },
            questionType: { type: "string", minLength: 1 },
            question: { type: "string", minLength: 1 },
            options: { type: "array", minItems: 4, maxItems: 4, items: optionSchema },
            correctKey: { type: "string", enum: ["A", "B", "C", "D"] },
            explanation: { type: "string", minLength: 1 },
            sourceType: { type: "string", enum: ["GPT Generated", "GPT Variant of Known Concept"] },
            canonicalQuestionId: { type: ["string", "null"] },
            ambiguous: { type: "boolean", enum: [false] },
            qualityScore: { type: "number", minimum: 0.8, maximum: 1 },
            metadata: {
              type: "object", additionalProperties: false,
              required: ["conceptKey", "trapTested", "difficultyTier", "discriminationScore", "trapStrength", "generationReason", "domain"],
              properties: {
                conceptKey: { type: "string", minLength: 1 },
                trapTested: { type: "string", minLength: 1 },
                difficultyTier: { type: "string", enum: ["Easy", "Moderate", "Hard"] },
                discriminationScore: { type: "number", minimum: 0, maximum: 1 },
                trapStrength: { type: "number", minimum: 0, maximum: 1 },
                generationReason: { type: "string", minLength: 1 },
                domain: { type: "string", enum: ["GrammarTransformation", "LexicalUsage"] },
              },
            },
          },
        },
      },
    },
  };
}

function criticSchema(count: number) {
  return {
    type: "object", additionalProperties: false, required: ["items"], properties: {
      items: {
        type: "array", minItems: count, maxItems: count, items: {
          type: "object", additionalProperties: false,
          required: [
            "itemKey", "pass", "sscRealism", "difficultyFit", "distractorStrength",
            "ambiguity", "obviousAnswer", "grammaticalValidity", "oneDefensibleAnswer",
            "intendedConceptFit", "duplicateConcept", "excessiveFamiliarity", "reasons",
          ],
          properties: {
            itemKey: { type: "string", minLength: 1 },
            pass: { type: "boolean" },
            sscRealism: { type: "number", minimum: 0, maximum: 1 },
            difficultyFit: { type: "number", minimum: 0, maximum: 1 },
            distractorStrength: { type: "number", minimum: 0, maximum: 1 },
            ambiguity: { type: "boolean" },
            obviousAnswer: { type: "boolean" },
            grammaticalValidity: { type: "number", minimum: 0, maximum: 1 },
            oneDefensibleAnswer: { type: "boolean" },
            intendedConceptFit: { type: "number", minimum: 0, maximum: 1 },
            duplicateConcept: { type: "boolean" },
            excessiveFamiliarity: { type: "boolean" },
            reasons: { type: "array", items: { type: "string" }, maxItems: 6 },
          },
        },
      },
    },
  };
}

function analysisSchema(count: number) {
  return {
    type: "object", additionalProperties: false, required: ["items"], properties: {
      items: { type: "array", minItems: count, maxItems: count, items: {
        type: "object", additionalProperties: false,
        required: ["position", "diagnosis", "action", "confusedWith", "rationale"],
        properties: {
          position: { type: "integer", minimum: 1, maximum: 25 },
          diagnosis: { type: "string", enum: diagnosisLabels },
          action: { type: "string", enum: actions },
          confusedWith: { type: "string" },
          rationale: { type: "string", minLength: 1 },
        },
      } },
    },
  };
}

function shuffle<T>(source: T[]) {
  const a = [...source];
  for (let i = a.length - 1; i > 0; i--) {
    const bytes = new Uint32Array(1);
    crypto.getRandomValues(bytes);
    const j = bytes[0] % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function repeat<T>(value: T, count: number) {
  return Array.from({ length: Math.max(0, count) }, () => value);
}

function slotPlan(mode: string, context: any): Slot[] {
  const count = counts[mode];
  const diff = context?.blueprint?.difficulty || {};
  const easy = Math.max(0, Number(diff.easy ?? (mode === "standard" ? 5 : 2)));
  const moderate = Math.max(0, Number(diff.moderate ?? Math.max(0, count - easy - 5)));
  const hard = Math.max(0, Number(diff.hard ?? Math.max(0, count - easy - moderate)));
  let tiers = shuffle([
    ...repeat<"Easy">("Easy", easy),
    ...repeat<"Moderate">("Moderate", moderate),
    ...repeat<"Hard">("Hard", hard),
  ]);
  if (tiers.length !== count) tiers = shuffle([
    ...repeat<"Easy">("Easy", mode === "standard" ? 5 : 2),
    ...repeat<"Moderate">("Moderate", Math.max(0, count - (mode === "standard" ? 12 : 7))),
    ...repeat<"Hard">("Hard", mode === "standard" ? 7 : 5),
  ]).slice(0, count);

  if (mode === "standard") {
    const grammar = Number(context?.blueprint?.questionMix?.grammarTransformation ?? 11);
    const lexical = count - grammar;
    const domains = shuffle([
      ...repeat<"GrammarTransformation">("GrammarTransformation", grammar),
      ...repeat<"LexicalUsage">("LexicalUsage", lexical),
    ]);
    return tiers.map((difficultyTier, i) => ({ position: i + 1, difficultyTier, domain: domains[i] }));
  }
  return tiers.map((difficultyTier, i) => ({ position: i + 1, difficultyTier }));
}

function normalized(s: unknown) {
  return String(s || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function localProblems(items: any[], slots: Slot[], context: any) {
  const problems = new Map<number, string[]>();
  const cooldown = new Set((Array.isArray(context?.cooldownConcepts) ? context.cooldownConcepts : []).map((x: any) => normalized(x)));
  const seenQuestion = new Set<string>();
  const seenConcept = new Set<string>();

  items.forEach((item, i) => {
    const p: string[] = [];
    const slot = slots[i];
    const q = normalized(item?.question);
    const concept = normalized(item?.metadata?.conceptKey);
    const options = Array.isArray(item?.options) ? item.options : [];
    const optionTexts = options.map((x: any) => normalized(x?.text)).filter(Boolean);
    const keys = options.map((x: any) => String(x?.key || "").toUpperCase());
    const qt = normalized(item?.questionType);

    if (!q || !concept) p.push("missing question/concept");
    if (seenQuestion.has(q)) p.push("duplicate question wording");
    if (seenConcept.has(concept)) p.push("duplicate conceptKey in same Sprint");
    if (q) seenQuestion.add(q);
    if (concept) seenConcept.add(concept);
    if (cooldown.has(concept)) p.push("same-day fast-correct concept is on cooldown");
    if (options.length !== 4 || new Set(optionTexts).size !== 4 || new Set(keys).size !== 4) p.push("options are not four unique A/B/C/D choices");
    if (!["A", "B", "C", "D"].includes(String(item?.correctKey || "").toUpperCase())) p.push("invalid correct key");
    if (/reading|comprehension|passage|cloze/.test(qt)) p.push("RC/passage content is forbidden");
    if (slot && item?.metadata?.difficultyTier !== slot.difficultyTier) p.push(`slot requires ${slot.difficultyTier}`);
    if (slot?.domain && item?.metadata?.domain !== slot.domain) p.push(`slot requires ${slot.domain}`);
    if (item?.ambiguous !== false) p.push("item self-flags ambiguity");
    if (Number(item?.qualityScore || 0) < 0.8) p.push("qualityScore below 0.80");
    if (p.length) problems.set(i, p);
  });
  return problems;
}

function criticAccepted(row: any) {
  return row?.pass === true
    && Number(row?.sscRealism || 0) >= 0.75
    && Number(row?.difficultyFit || 0) >= 0.75
    && Number(row?.distractorStrength || 0) >= 0.72
    && row?.ambiguity === false
    && row?.obviousAnswer === false
    && Number(row?.grammaticalValidity || 0) >= 0.9
    && row?.oneDefensibleAnswer === true
    && Number(row?.intendedConceptFit || 0) >= 0.8
    && row?.duplicateConcept === false
    && row?.excessiveFamiliarity === false;
}

function failedPositions(items: any[], slots: Slot[], context: any, critics: any[]) {
  const failed = new Map<number, string[]>();
  for (const [i, reasons] of localProblems(items, slots, context)) failed.set(i, [...reasons]);
  const byKey = new Map((critics || []).map((x: any) => [String(x.itemKey || ""), x]));
  items.forEach((item, i) => {
    const c = byKey.get(String(item?.itemKey || ""));
    if (!c || !criticAccepted(c)) {
      const reasons = [...(failed.get(i) || [])];
      reasons.push(...(Array.isArray(c?.reasons) && c.reasons.length ? c.reasons : ["critic rejected item"]));
      failed.set(i, [...new Set(reasons)]);
    }
  });
  return failed;
}

function annotateCritic(items: any[], critics: any[]) {
  const byKey = new Map((critics || []).map((x: any) => [String(x.itemKey || ""), x]));
  return items.map(item => {
    const c = byKey.get(String(item?.itemKey || ""));
    const criticScore = c ? Number(((Number(c.sscRealism || 0) + Number(c.difficultyFit || 0) + Number(c.distractorStrength || 0) + Number(c.grammaticalValidity || 0) + Number(c.intendedConceptFit || 0)) / 5).toFixed(3)) : 0;
    return {
      ...item,
      metadata: {
        ...(item?.metadata || {}),
        criticPassed: !!c && criticAccepted(c),
        criticScore,
        criticReasons: Array.isArray(c?.reasons) ? c.reasons.slice(0, 6) : [],
      },
    };
  });
}

const generationInstructions = `You are the English V2 SSC CGL Sprint generator. Build fair, high-discrimination SSC objective-English questions for a strong learner.

NON-NEGOTIABLE PRODUCT CONTRACT
- Standard Sprint is an EXAM SIMULATION, not a disguised weakness drill. Follow the supplied blueprint and slotPlan exactly.
- Never generate Reading Comprehension, cloze passages, passage-dependent items, or multi-question passages.
- Difficulty must come from close distractors, subtle rules, realistic context, longer structures, transformation complexity, and confusable usage — never obscure GRE/CAT vocabulary or trivia.
- Every item must have exactly one defensible answer and four plausible, distinct A/B/C/D options.
- At least 2–3 distractors should be close enough that the learner must actually know/process the rule. Reject cartoonishly unrelated distractors and obvious-answer items.
- Standard should contain a real range of Easy speed checks, proper SSC Moderate items, and Hard/high-discrimination items exactly as slotPlan requests.
- Standard's GrammarTransformation slots cover Error Detection, Sentence Improvement, Voice, Narration, Grammar Usage, Fixed Preposition/usage or Fill-in-the-Blank. LexicalUsage slots cover Vocabulary, Synonym/Antonym, Idioms, OWS, Phrasal Verbs, Spelling and other lexical usage.
- For Error Detection, prefer realistic multi-clause sentences: mostly about 18–30 words, with some 30–40-word items. Bury the error naturally; use genuine No Error when appropriate. Avoid toy errors such as "The boys is playing."
- Error Detection concept inventory can include SVA, relative reference, parallelism, pronoun case/agreement, articles/determiners, comparison, modifiers, participles, conditionals, inversion, tense sequence, gerund/infinitive, adjective/adverb, redundancy, conjunction pairs, prepositions, reported speech, noun number, countability and idiomatic grammar.
- Sentence Improvement must use meaningful phrases/clauses and almost-correct alternatives; require full-sentence processing.
- Voice should include SSC-relevant complex tenses, modal perfects, two-object constructions, interrogatives, imperatives/requests, reporting structures, clauses and passive infinitive/gerund patterns. Avoid basic "He writes a letter" transformations.
- Narration should include interrogatives, commands, requests, exclamations, universal truths, modal/reporting-verb traps, time/place changes and multi-clause speech. Options should differ subtly in reporting verb, tense, pronoun, word order or time expression.
- Vocabulary must be moderate-to-hard SSC-oriented; distractors are semantic neighbours. Avoid very common items and avoid obscure non-SSC words merely for difficulty.
- Sprint Phrasal Verb items must be contextual and use genuinely confusable same-base/nearby alternatives.
- Idioms should test contextual meaning/usage with close interpretations. OWS should be SSC-relevant with conceptual neighbours. Spelling should use real trouble words with four plausible near-neighbour spellings. Fixed-preposition/usage items may test two linked constructions.
- Use supplied previousMistakes as transfer seeds: new wording/context, not verbatim replay. Wrong concepts deserve fresh transfer variants.
- Use slowCorrectSeeds as hesitation evidence where useful, but do not turn Standard into remediation.
- Never use a concept listed in cooldownConcepts unless the context itself contains a later genuine wrong that clearly overrides cooldown.
- Weakness/Trap/Mistakes modes are remediation: heavily use fresh transfer contexts, recurring confusions and close distractors, never verbatim seed replay.
- sourceType is GPT Generated unless a supplied canonical seed genuinely underlies a fresh variant; then GPT Variant of Known Concept is allowed and canonicalQuestionId may copy only that real seed.
- Never claim generated content is SSC PYQ.
- metadata.difficultyTier and metadata.domain MUST match the corresponding slotPlan target. discriminationScore measures expected discrimination; trapStrength measures distractor closeness; qualityScore is content integrity, not difficulty.
- explanation is for post-Sprint review only; it must not leak the answer into the question/options.
- Do a private self-check before returning, but do not rely on self-rating alone; a separate critic will audit every item.`;

const criticInstructions = `You are the independent pre-serve critic for an SSC CGL English Sprint. Be strict, not agreeable.
Evaluate every item against its requested slot and the supplied learner context.
Reject an item when ANY of these applies:
- not realistic SSC objective-English material;
- requested Easy/Moderate/Hard tier is mislabeled;
- distractors are weak/unrelated, or the answer is obvious without full processing;
- ambiguity exists or more than one option is defensible;
- grammar/transformation itself is invalid;
- intended concept is not genuinely tested;
- concept is duplicated elsewhere in the set without a strong adaptive reason;
- item is excessively familiar/basic for this learner;
- Error Detection is a toy one-rule sentence when a Moderate/Hard slot was requested;
- Voice/Narration is elementary when a Moderate/Hard slot was requested;
- vocabulary difficulty comes from obscurity rather than SSC discrimination.
Pass only fair, discriminating items. Give concise repair reasons.`;

const repairInstructions = generationInstructions + `
This is SELECTIVE REPAIR. Generate ONLY replacements for the failed slots supplied in failedSlots, in exactly that order.
Preserve each failed slot's required difficultyTier and domain. Do not rewrite or duplicate acceptedItems.
Use failedReasons to repair the actual defect. Return exactly the requested number of replacements.`;

const analysisInstructions = `You are the English V2 SSC Sprint mistake analyst. Diagnose each genuinely WRONG answer using only the supplied completed-Sprint evidence.
Unanswered items are not in this input and must never be diagnosed as wrong.
Distinguish genuine learning problems from execution errors. Use Targeted Mastery only for a real Knowledge Gap, Rule Gap, durable Confusion, or recurring Distractor Trap. Careless, Time Pressure, and Misread should normally remain execution evidence and must not pollute the Targeted queue. Weakness Drill or Trap Practice can be recommended without routing to Targeted. Keep confusedWith concise and specific. Return one diagnosis for every supplied wrong position, no more and no less.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "POST required" }, 405);

  try {
    const auth = req.headers.get("Authorization") || "";
    if (!auth.startsWith("Bearer ")) return reply({ ok: false, error: "Authentication required" }, 401);

    const url = Deno.env.get("SUPABASE_URL");
    const anon = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !anon) throw new Error("Supabase function environment is incomplete");

    const supabase = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return reply({ ok: false, error: "Authentication required" }, 401);

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "create").toLowerCase();

    if (action === "create") {
      const mode = String(body?.mode || "standard").toLowerCase();
      if (!allowedModes.has(mode)) return reply({ ok: false, error: "Unknown Sprint mode" }, 400);

      const { data: context, error: contextError } = await supabase.rpc("english_get_sprint_generation_context", { p_mode: mode });
      if (contextError) throw contextError;

      const count = counts[mode];
      const slots = slotPlan(mode, context);
      const requestGroup = crypto.randomUUID();

      const generation = await openaiJson(
        "english_ssc_sprint",
        sprintSchema(count),
        generationInstructions,
        { ...context, slotPlan: slots },
      );
      await logUsage(supabase, requestGroup, "generation", mode, generation, null, { itemCount: count });

      let items = generation.data.items;
      let finalCritics: any[] = [];

      for (let round = 0; round < 3; round++) {
        const critic = await openaiJson(
          `english_ssc_sprint_critic_${round + 1}`,
          criticSchema(count),
          criticInstructions,
          { mode, blueprint: context?.blueprint || {}, recentStandardPerformance: context?.recentStandardPerformance || {}, slotPlan: slots, items },
        );
        await logUsage(supabase, requestGroup, "critic", mode, critic, null, { round: round + 1, itemCount: count });
        finalCritics = critic.data.items || [];

        const failed = failedPositions(items, slots, context, finalCritics);
        if (!failed.size) break;
        if (round === 2) {
          const summary = [...failed.entries()].map(([i, r]) => `Q${i + 1}: ${r.join("; ")}`).join(" | ");
          throw new Error(`Sprint critic could not produce a clean set after selective repair: ${summary}`);
        }

        const failedIndexes = [...failed.keys()].sort((a, b) => a - b);
        const failedSlots = failedIndexes.map(i => ({
          ...slots[i],
          itemKey: items[i]?.itemKey,
          failedReasons: failed.get(i),
        }));
        const acceptedItems = items
          .map((item: any, i: number) => failed.has(i) ? null : ({
            position: i + 1,
            conceptKey: item?.metadata?.conceptKey,
            questionType: item?.questionType,
            difficultyTier: item?.metadata?.difficultyTier,
            domain: item?.metadata?.domain,
            question: item?.question,
          }))
          .filter(Boolean);

        const repair = await openaiJson(
          `english_ssc_sprint_selective_repair_${round + 1}`,
          sprintSchema(failedIndexes.length),
          repairInstructions,
          { mode, blueprint: context?.blueprint || {}, failedSlots, acceptedItems, context },
        );
        await logUsage(supabase, requestGroup, "repair", mode, repair, null, { round: round + 1, failedCount: failedIndexes.length });

        const replacements = repair.data.items || [];
        if (replacements.length !== failedIndexes.length) throw new Error("Selective Sprint repair returned the wrong item count");
        failedIndexes.forEach((index, j) => { items[index] = replacements[j]; });
      }

      const remaining = failedPositions(items, slots, context, finalCritics);
      if (remaining.size) throw new Error("Sprint failed final pre-serve validation");
      items = annotateCritic(items, finalCritics);
      if (items.some((x: any) => x?.metadata?.criticPassed !== true)) throw new Error("Sprint contains an unapproved critic item");

      const created = await supabase.rpc("english_create_sprint_session", {
        p_mode: mode,
        p_items: items,
        p_blueprint: {
          ...(context?.blueprint || {}),
          slotPlan: slots,
          critic: { enabled: true, selectiveRepair: true, rounds: 3 },
          generatedAt: new Date().toISOString(),
        },
      });
      if (created.error) throw created.error;

      const sessionId = String(created.data?.sessionId || "");
      if (sessionId) {
        try {
          await supabase.rpc("english_attach_sprint_ai_usage", { p_request_group: requestGroup, p_session_id: sessionId });
        } catch {
          // Best effort telemetry attachment only.
        }
      }
      return reply(created.data);
    }

    if (action === "analyze") {
      const sessionId = String(body?.sessionId || "");
      if (!sessionId) return reply({ ok: false, error: "sessionId required" }, 400);

      const { data: context, error: contextError } = await supabase.rpc("english_get_sprint_analysis_context", { p_session_id: sessionId });
      if (contextError) throw contextError;
      const wrong = Array.isArray(context?.wrongItems) ? context.wrongItems : [];

      if (!wrong.length) {
        const saved = await supabase.rpc("english_save_sprint_analysis", { p_session_id: sessionId, p_analysis: [] });
        if (saved.error) throw saved.error;
        return reply({ ok: true, analysis: [], targetedAdded: 0 });
      }

      const requestGroup = crypto.randomUUID();
      const analyzed = await openaiJson(
        "english_ssc_sprint_analysis",
        analysisSchema(wrong.length),
        analysisInstructions,
        context,
      );
      await logUsage(supabase, requestGroup, "analysis", String(context?.mode || ""), analyzed, sessionId, { wrongCount: wrong.length });

      const positions = new Set(wrong.map((x: any) => Number(x.position)));
      if (!Array.isArray(analyzed.data.items) || analyzed.data.items.some((x: any) => !positions.has(Number(x.position)))) {
        throw new Error("Sprint analysis positions do not match wrong items");
      }
      const saved = await supabase.rpc("english_save_sprint_analysis", { p_session_id: sessionId, p_analysis: analyzed.data.items });
      if (saved.error) throw saved.error;
      return reply({ ok: true, analysis: analyzed.data.items, targetedAdded: saved.data?.targetedAdded || 0 });
    }

    return reply({ ok: false, error: "Unknown action" }, 400);
  } catch (error) {
    console.error("english-ssc-sprint", error);
    return reply({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});

import {
  ANTIGRAVITY_AGENT, ANTIGRAVITY_MODEL, LUNA_MODEL, GEMINI_RARE_RESCUE_MODEL,
  fourOptionCodeGate, runAntigravityLunaPipeline,
} from "../_shared/english-antigravity-luna.ts";

type Db = any;
type Json = Record<string, any>;

const normText = (v: string) => v.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const compactPhrasalTarget = (v: string) => {
  const s = String(v || "").trim();
  if (!s || s.length > 80) return false;
  const words = s.replace(/[\/|]+/g, " ").match(/[A-Za-z]+(?:'[A-Za-z]+)?/g) || [];
  return words.length >= 2 && words.length <= 6;
};
const keyedReferenceOption = (reference: Json) => {
  const key = String(reference?.correctKey || "").toUpperCase();
  if (!["A", "B", "C", "D"].includes(key)) return "";
  const hit = Array.isArray(reference?.options)
    ? reference.options.find((x: any) => String(x?.key || "").toUpperCase() === key)
    : null;
  return String(hit?.text || reference?.[`option${key}`] || "").trim();
};
function resolvePhrasalTarget(item: Json, reference: Json, conceptId: string) {
  const raw = String(reference?.word || item?.word || "").trim();
  if (compactPhrasalTarget(raw)) return raw;
  const idMatch = String(conceptId || "").match(/^(?:PV_|phrasal_)(.+)$/i);
  if (idMatch) {
    const fromId = idMatch[1].replace(/_/g, " ").trim();
    if (compactPhrasalTarget(fromId)) return fromId;
  }
  const question = String(reference?.question || item?.question || "");
  const keyed = keyedReferenceOption(reference);
  const answerIdentifiesTarget = /phrasal verb|which pair|_{2,}|=\s*\?/i.test(question);
  if (answerIdentifiesTarget && compactPhrasalTarget(keyed)) return keyed;
  return "";
}
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown Phrasal generation error");
const sha256 = async (text: string) => {
  const bytes = new TextEncoder().encode(text.trim().toLowerCase().replace(/\s+/g, " "));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((x) => x.toString(16).padStart(2, "0")).join("");
};
async function mapLimit<T, R>(values: T[], limit: number, fn: (v: T, i: number) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(values.length);
  let cursor = 0;
  const workers = Array.from({ length: Math.min(limit, values.length) }, async () => {
    while (true) {
      const i = cursor++;
      if (i >= values.length) return;
      out[i] = await fn(values[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}
async function featureEnabled(db: Db, flag: string) {
  const { data, error } = await db.rpc("english_ai_content_feature_enabled", { p_flag: flag });
  if (error) throw new Error(`FEATURE_READ_FAILED: ${error.message}`);
  return data === true;
}
async function audit(db: Db, items: Json[]) {
  if (!items.length) return;
  const { error } = await db.rpc("english_record_content_generation_audits", { p_items: items });
  if (error) throw new Error(`AUDIT_FAILED: ${error.message}`);
}
async function releaseClaim(db: Db, runId: string, reason: unknown) {
  if (!runId) return;
  try {
    await db.rpc("english_release_content_task_claim", {
      p_run_id: runId,
      p_lane: "phrasal",
      p_reason: errorText(reason).slice(0, 800),
    });
  } catch { /* best-effort lease recovery; original error remains authoritative */ }
}

const baseItemSchema: any = {
  type: "object",
  additionalProperties: false,
  required: [
    "word", "senseKey", "senseGloss", "question", "questionType",
    "optionA", "optionB", "optionC", "optionD", "correctKey", "explanation",
    "tip", "usageNote", "example", "memoryAid", "related", "difficulty",
  ],
  properties: {
    word: { type: "string" },
    senseKey: { type: "string", pattern: "^[a-z0-9_]{2,80}$" },
    senseGloss: { type: "string", minLength: 2, maxLength: 240 },
    question: { type: "string" },
    questionType: { type: "string" },
    optionA: { type: "string" },
    optionB: { type: "string" },
    optionC: { type: "string" },
    optionD: { type: "string" },
    correctKey: { type: "string", enum: ["A", "B", "C", "D"] },
    explanation: { type: "string" },
    tip: { type: "string" },
    usageNote: { type: "string" },
    example: { type: "string" },
    memoryAid: { type: "string" },
    related: { type: "string" },
    difficulty: { type: "string", enum: ["Medium", "Hard"] },
  },
};
function phrasalSchema(family: string, targetWord: string) {
  const schema = structuredClone(baseItemSchema) as any;
  schema.properties.word = { type: "string", enum: [targetWord] };
  if (family === "recall") {
    schema.properties.questionType = { type: "string", enum: ["Reverse Recall Card"] };
    schema.properties.optionA = { type: "string", enum: ["Yaad tha"] };
    schema.properties.optionB = { type: "string", enum: ["Confused"] };
    schema.properties.optionC = { type: "string", enum: ["Bhool gaya"] };
    schema.properties.optionD = { type: "string", enum: [""] };
    schema.properties.correctKey = { type: "string", enum: ["A"] };
  } else {
    schema.properties.optionA = { type: "string", minLength: 1 };
    schema.properties.optionB = { type: "string", minLength: 1 };
    schema.properties.optionC = { type: "string", minLength: 1 };
    schema.properties.optionD = { type: "string", minLength: 1 };
    if (family === "context_fill") schema.properties.questionType = { type: "string", enum: ["Context Fill"] };
  }
  return schema;
}

function normalizeContextFillDraft(draft: Json, assignment: Json) {
  if (String(assignment?.requestedFamily || "").toLowerCase() !== "context_fill") return;
  const targetWord = String(assignment?.targetWord || "").trim();
  if (!targetWord) return;
  draft.word = targetWord;
  draft.questionType = "Context Fill";

  const keys = ["A", "B", "C", "D"] as const;
  const key = keys.includes(String(draft?.correctKey || "").toUpperCase() as any)
    ? String(draft.correctKey).toUpperCase() as "A"|"B"|"C"|"D"
    : keys[Math.abs(String(assignment?.conceptId || targetWord).split("").reduce((n: number, ch: string) => n + ch.charCodeAt(0), 0)) % 4];
  const targetNorm = normText(targetWord);
  const seen = new Set<string>();
  const distractors: string[] = [];
  const add = (value: unknown) => {
    const text = String(value || "").trim();
    const norm = normText(text);
    if (!text || !norm || norm === targetNorm || seen.has(norm)) return;
    seen.add(norm);
    distractors.push(text);
  };

  // Keep useful Antigravity distractors first.
  keys.forEach(k => add(draft?.[`option${k}`]));

  // Canonical bank is a deterministic structural fallback, not a second writer.
  const reference = assignment?.referenceVariant || {};
  if (Array.isArray(reference?.options)) reference.options.forEach((x: any) => {
    const text = String(x?.text || "").trim();
    if (compactPhrasalTarget(text)) add(text);
  });
  keys.forEach(k => {
    const text = String(reference?.[`option${k}`] || "").trim();
    if (compactPhrasalTarget(text)) add(text);
  });
  String(reference?.related || "").split(/[;,|]/).forEach((text: string) => {
    if (compactPhrasalTarget(text)) add(text);
  });

  draft.correctKey = key;
  let cursor = 0;
  keys.forEach(k => {
    if (k === key) draft[`option${k}`] = targetWord;
    else if (distractors[cursor]) draft[`option${k}`] = distractors[cursor++];
  });
}

function phrasalCodeGate(draft: Json, assignment: Json) {
  const issues: string[] = [];
  const requested = String(assignment.requestedFamily || "recognition").toLowerCase();
  const targetWord = String(assignment.targetWord || "").trim();
  const preferredSenseKey = String(assignment.preferredSenseKey || "legacy_default");
  const outputSenseKey = String(draft?.senseKey || "").trim();
  const outputSenseGloss = String(draft?.senseGloss || "").trim();

  if (!/^[a-z0-9_]{2,80}$/.test(outputSenseKey)) issues.push("senseKey must be valid lower_snake_case");
  if (!outputSenseGloss) issues.push("senseGloss is blank");
  if (preferredSenseKey !== "legacy_default" && outputSenseKey !== preferredSenseKey) issues.push(`senseKey must remain ${preferredSenseKey}`);
  if (targetWord && normText(String(draft?.word || "")) !== normText(targetWord)) issues.push("target phrasal verb word must be preserved exactly");
  if (!["Medium", "Hard"].includes(String(draft?.difficulty || ""))) issues.push("difficulty must be Medium or Hard");

  if (requested === "recall") {
    if (draft?.questionType !== "Reverse Recall Card") issues.push("recall questionType must be Reverse Recall Card");
    if (draft?.optionA !== "Yaad tha" || draft?.optionB !== "Confused" || draft?.optionC !== "Bhool gaya" || draft?.optionD !== "" || draft?.correctKey !== "A") {
      issues.push("Reverse Recall options/key contract drifted");
    }
    if (!String(draft?.question || "").trim()) issues.push("question is blank");
    if (!String(draft?.explanation || "").trim()) issues.push("explanation is blank");
    const target = normText(targetWord), front = normText(String(draft?.question || ""));
    if (target && front.includes(target)) issues.push("Reverse Recall front leaks the target phrasal verb");
  } else {
    issues.push(...fourOptionCodeGate(draft, "correctKey"));
    if (requested === "context_fill" && draft?.questionType !== "Context Fill") issues.push("context-fill questionType must be Context Fill");
  }
  return issues;
}

const legacyOption = (reference: Json, key: "A"|"B"|"C"|"D") => {
  const hit = Array.isArray(reference?.options)
    ? reference.options.find((x: any) => String(x?.key || "").toUpperCase() === key)
    : null;
  return String(hit?.text ?? reference?.[`option${key}`] ?? "").trim();
};
function legacyPhrasal(item: Json) {
  const conceptId = String(item?.phrasalConceptId || item?.conceptId || "");
  const requested = String(item?.requestedQuestionFamily || item?.missingFamily || item?.phrasalQuestionFamily || "recognition").toLowerCase();
  const legacy = String(item?.legacyFamily || item?.missingFamily || item?.phrasalQuestionFamily || requested || "recognition").toLowerCase();
  const reference = Object.keys(item?.referenceVariant || {}).length ? item.referenceVariant : item;
  const targetWord = resolvePhrasalTarget(item, reference, conceptId);
  if (!conceptId || !targetWord) return null;
  if (item?.contentGap === true || String(item?.slotStatus || "").toLowerCase() === "content_gap") return null;
  if (requested === "context_fill" || requested !== legacy) return null;

  const draft: Json = {
    word: targetWord,
    senseKey: String(item?.senseKey || "legacy_default"),
    senseGloss: String(item?.senseGloss || ""),
    question: String(reference?.question || "").trim(),
    questionType: String(reference?.questionType || "").trim(),
    optionA: legacyOption(reference, "A"),
    optionB: legacyOption(reference, "B"),
    optionC: legacyOption(reference, "C"),
    optionD: legacyOption(reference, "D"),
    correctKey: String(reference?.correctKey || "").toUpperCase(),
    explanation: String(reference?.explanation || "").trim(),
    tip: String(reference?.tip || ""),
    usageNote: String(reference?.usageNote || ""),
    example: String(reference?.example || reference?.exampleSentence || ""),
    memoryAid: String(reference?.memoryAid || ""),
    related: String(reference?.related || reference?.relatedWords || ""),
    difficulty: String(reference?.difficulty || item?.difficulty || "Medium"),
    sourcePage: String(reference?.sourcePage || ""),
    sourceUrl: String(reference?.sourceUrl || ""),
  };
  if (!draft.question || !draft.explanation) return null;
  if (requested === "recall") {
    if (draft.questionType !== "Reverse Recall Card" || draft.optionA !== "Yaad tha" || draft.optionB !== "Confused" || draft.optionC !== "Bhool gaya" || draft.optionD !== "" || draft.correctKey !== "A") return null;
    if (normText(draft.question).includes(normText(targetWord))) return null;
  } else if (fourOptionCodeGate(draft, "correctKey").length) return null;

  return {
    ...draft,
    conceptId,
    requestedQuestionFamily: requested,
    questionFamily: requested,
    legacyFamily: legacy,
    family: requested,
    baseQuestionId: String(reference?.id || reference?.questionId || item?.id || item?.questionId || ""),
    contentGap: false,
    generatorProvider: "legacy_bank",
    generatorModel: "canonical_bank",
    criticProvider: null,
    criticModel: null,
    quality: null,
    repairCount: 0,
    codeRepairCount: 0,
    rareRescue: false,
    writerRequests: 0,
    criticRequests: 0,
    variantFingerprint: "",
    variantKey: "",
  };
}

async function generatePhrasal(item: Json) {
  const conceptId = String(item?.phrasalConceptId || item?.conceptId || "");
  const requested = String(item?.requestedQuestionFamily || item?.missingFamily || item?.phrasalQuestionFamily || "recognition").toLowerCase();
  const legacy = String(item?.legacyFamily || item?.missingFamily || item?.phrasalQuestionFamily || requested || "recognition").toLowerCase();
  const reference = Object.keys(item?.referenceVariant || {}).length ? item.referenceVariant : item;
  const knownSenses = Array.isArray(item?.knownSenses) ? item.knownSenses : [];
  const preferredSenseKey = String(item?.senseKey || "legacy_default");
  const targetWord = resolvePhrasalTarget(item, reference, conceptId);
  if (!conceptId || !targetWord || !String(reference?.question || reference?.explanation || reference?.word || "").trim()) {
    throw new Error(`PHRASAL_REFERENCE_MISSING_OR_TARGET_UNRESOLVED: ${conceptId || "unknown"}`);
  }

  const assignment = {
    conceptId,
    preferredSenseKey,
    requestedFamily: requested,
    legacyFamily: legacy,
    targetWord,
    referenceVariant: reference,
    knownSenses,
    selectedVariantCooled: item?.selectedVariantCooled === true,
    recentConceptStems: Array.isArray(item?.recentConceptStems) ? item.recentConceptStems : [],
    recentVariantFingerprints: Array.isArray(item?.recentVariantFingerprints) ? item.recentVariantFingerprints : [],
  };

  const instructions = `You are Antigravity, the WRITER for exactly ONE SSC CGL Phrasal Verb learning card selected by Central Intelligence. Central Intelligence owns WHAT concept, sense and family must be taught; you own only HOW to teach that fixed assignment well. Preserve targetWord exactly and preserve the exact meaning/sense evidenced by referenceVariant. Do not substitute another sense merely because the phrasal verb has multiple meanings. If preferredSenseKey is not legacy_default, reuse it exactly. Otherwise create a short lower_snake_case semantic senseKey for THIS evidenced sense and provide a precise senseGloss. requestedFamily is binding.\n\ncontext_fill: create a natural sentence-level cloze/usage MCQ testing the intended sense. Use four close, plausible phrasal-verb choices with exactly one defensible answer. Do not make distractors cheaply eliminable by grammar, length, or unrelated meaning. questionType must be exactly \"Context Fill\". Do not exactly or semantically repeat recentConceptStems.\nrecall: preserve the EXISTING Reverse Recall Card contract. The front must be a meaning/situation cue and MUST NOT reveal targetWord. questionType=\"Reverse Recall Card\"; A=\"Yaad tha\"; B=\"Confused\"; C=\"Bhool gaya\"; D=\"\"; correctKey=\"A\". Explanation may reveal and teach targetWord after recall.\nrecognition/confusion: normal four-option SSC MCQ with close, defensible distractors and exactly one answer.\nDifficulty must be Medium or Hard, not artificially obscure. Return the complete JSON item only.`;

  let reviewed: Awaited<ReturnType<typeof runAntigravityLunaPipeline<any>>>;
  try {
    reviewed = await runAntigravityLunaPipeline<any>({
    instructions,
    input: assignment,
    schema: phrasalSchema(requested, targetWord),
    criticContext: {
      lane: "phrasal",
      ...assignment,
      recallContract: requested === "recall"
        ? { front: "meaning/situation cue; target hidden", A: "Yaad tha", B: "Confused", C: "Bhool gaya", D: "", correctKey: "A", questionType: "Reverse Recall Card" }
        : null,
    },
    structuralGate: (draft: Json) => { normalizeContextFillDraft(draft, assignment); return phrasalCodeGate(draft, assignment); },
    repairInput: (original, current, quality) => ({
      originalAssignment: original,
      currentItem: current,
      critic: { decision: quality.decision, issues: quality.issues, repairInstruction: quality.repairInstruction },
    }),
    });
  } catch (e) {
    throw new Error(`PHRASAL_ITEM_FAILED ${conceptId}/${requested}: ${errorText(e)}`);
  }

  const outputSenseKey = String(reviewed.item?.senseKey || "").trim();
  const outputSenseGloss = String(reviewed.item?.senseGloss || "").trim();
  if (!/^[a-z0-9_]{2,80}$/.test(outputSenseKey) || !outputSenseGloss) throw new Error(`PHRASAL_SENSE_INVALID: ${conceptId}`);
  if (preferredSenseKey !== "legacy_default" && outputSenseKey !== preferredSenseKey) throw new Error(`PHRASAL_SENSE_DRIFT: expected ${preferredSenseKey}, got ${outputSenseKey}`);

  const fp = await sha256(`${conceptId}|${outputSenseKey}|${requested}|${reviewed.item.question}`);
  return {
    ...reviewed.item,
    word: targetWord,
    conceptId,
    senseKey: outputSenseKey,
    senseGloss: outputSenseGloss,
    requestedQuestionFamily: requested,
    questionFamily: requested,
    legacyFamily: legacy,
    family: requested === "context_fill" ? "recognition" : requested,
    baseQuestionId: String(reference?.id || reference?.questionId || item?.id || item?.questionId || ""),
    contentGap: Boolean(item?.contentGap),
    generatorProvider: reviewed.generatorProvider,
    generatorModel: reviewed.generatorModel,
    criticProvider: reviewed.criticProvider,
    criticModel: reviewed.criticModel,
    quality: reviewed.quality,
    repairCount: reviewed.repairCount,
    codeRepairCount: reviewed.codeRepairCount,
    rareRescue: reviewed.rareRescue,
    writerRequests: reviewed.writerRequests,
    criticRequests: reviewed.criticRequests,
    variantFingerprint: fp,
    variantKey: `ai_${fp.slice(0, 16)}`,
  };
}

export async function runPhrasalGeneration(db: Db) {
  if (
    !await featureEnabled(db, "antigravity_writer_v1") ||
    !await featureEnabled(db, "luna_critic_v1") ||
    !await featureEnabled(db, "phrasal_sense_v1") ||
    !await featureEnabled(db, "phrasal_context_fill_v1")
  ) throw new Error("AI_PIPELINE_DISABLED: Phrasal Antigravity/Luna/context flags are not enabled");

  const { data: claim, error: claimError } = await db.rpc("english_phrasal_task_claim");
  if (claimError) throw new Error(`PHRASAL_CLAIM_FAILED: ${claimError.message}`);
  if (claim?.busy) throw new Error(`PHRASAL_BUSY: ${String(claim?.runId || "active run")}`);
  if (Number(claim?.count || 0) === 0) return claim || { ok: true, count: 0 };
  const runId = String(claim?.runId || "");

  try {
    const items = Array.isArray(claim?.items) ? claim.items : [];
    if (items.length !== 20) throw new Error(`PHRASAL_CLAIM_INVALID: expected 20 slots, got ${items.length}`);

    const expectedContextCount = items.filter((item: Json) =>
      String(item?.requestedQuestionFamily || item?.missingFamily || item?.phrasalQuestionFamily || "recognition").toLowerCase() === "context_fill"
    ).length;
    if (expectedContextCount > 6) throw new Error(`PHRASAL_CONTEXT_SELECTION_INVALID: maximum 6 contextual slots, got ${expectedContextCount}`);

    // Central Intelligence owns the 20-slot batch. Reuse structurally valid serviceable cards;
    // AI only fills actual family/content gaps and context-fill slots.
    const finalized = await mapLimit(items, 4, async (item: Json) => legacyPhrasal(item) || await generatePhrasal(item));
    const contextCount = finalized.filter((x) => x.requestedQuestionFamily === "context_fill").length;
    if (contextCount !== expectedContextCount || contextCount > 6) throw new Error(`PHRASAL_CONTEXT_MIX_REJECTED: Central requested ${expectedContextCount}, finalized ${contextCount}`);
    if (new Set(finalized.map(x => x.conceptId)).size !== 20) throw new Error("PHRASAL_CONCEPT_DUPLICATION: finalized batch does not contain 20 distinct concepts");

    const { data: applied, error: applyError } = await db.rpc("english_phrasal_task_apply", { p_run_id: runId, p_items: finalized });
    if (applyError) throw new Error(`PHRASAL_APPLY_FAILED: ${applyError.message}`);

    const generated = finalized.filter((x) => x.generatorProvider !== "legacy_bank");
    const reused = finalized.length - generated.length;
    await audit(db, generated.map((x) => ({
      lane: "phrasal",
      entityKey: x.conceptId,
      generatorProvider: String(x.generatorProvider || "antigravity"),
      generatorModel: String(x.generatorModel || ANTIGRAVITY_MODEL),
      criticProvider: String(x.criticProvider || "openai"),
      criticModel: String(x.criticModel || LUNA_MODEL),
      qualityScore: x.quality?.score,
      criticDecision: x.quality?.decision,
      repairCount: x.repairCount,
      questionFamily: x.requestedQuestionFamily,
      senseKey: x.senseKey,
      variantKey: x.variantKey,
      variantFingerprint: x.variantFingerprint,
      publicationResult: "applied",
      metadata: {
        requestMode: "one_item_per_generation_request",
        writer: "antigravity",
        writerReasoning: "high",
        antigravityAgent: ANTIGRAVITY_AGENT,
        antigravityModel: ANTIGRAVITY_MODEL,
        critic: "luna",
        criticReasoning: "low",
        lunaModel: LUNA_MODEL,
        rareRescueModel: GEMINI_RARE_RESCUE_MODEL,
        rareRescue: x.rareRescue === true,
        writerRequests: Number(x.writerRequests || 1),
        criticRequests: Number(x.criticRequests || 1),
        codeRepairCount: Number(x.codeRepairCount || 0),
      },
    })));

    return {
      ok: true,
      lane: "phrasal",
      runId,
      contextCount,
      expectedContextCount,
      generated: generated.length,
      reused,
      writer: "antigravity",
      antigravityAgent: ANTIGRAVITY_AGENT,
      antigravityModel: ANTIGRAVITY_MODEL,
      writerReasoning: "high",
      critic: "luna",
      criticModel: LUNA_MODEL,
      criticReasoning: "low",
      rareRescueModel: GEMINI_RARE_RESCUE_MODEL,
      rareRescues: generated.filter(x => x.rareRescue === true).length,
      writerRequests: generated.reduce((n, x) => n + Number(x.writerRequests || 0), 0),
      criticRequests: generated.reduce((n, x) => n + Number(x.criticRequests || 0), 0),
      codeRepairs: generated.reduce((n, x) => n + Number(x.codeRepairCount || 0), 0),
      applied,
    };
  } catch (e) {
    await releaseClaim(db, runId, e);
    throw e;
  }
}

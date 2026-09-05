import {
  ANTIGRAVITY_AGENT, ANTIGRAVITY_MODEL, LUNA_MODEL, GEMINI_RARE_RESCUE_MODEL,
  fourOptionCodeGate, runAntigravityLunaPipeline,
} from "../_shared/english-antigravity-luna.ts";

type Db = any;
type Json = Record<string, any>;

const normText = (v: string) => v.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
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
function phrasalSchema(family: string) {
  const schema = structuredClone(baseItemSchema) as any;
  if (family === "recall") {
    schema.properties.questionType = { type: "string", enum: ["Reverse Recall Card"] };
    schema.properties.optionA = { type: "string", enum: ["Yaad tha"] };
    schema.properties.optionB = { type: "string", enum: ["Confused"] };
    schema.properties.optionC = { type: "string", enum: ["Bhool gaya"] };
    schema.properties.optionD = { type: "string", enum: [""] };
    schema.properties.correctKey = { type: "string", enum: ["A"] };
  } else if (family === "context_fill") {
    schema.properties.questionType = { type: "string", enum: ["Context Fill"] };
  }
  return schema;
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

async function generatePhrasal(item: Json) {
  const conceptId = String(item?.phrasalConceptId || item?.conceptId || "");
  const requested = String(item?.requestedQuestionFamily || item?.missingFamily || item?.phrasalQuestionFamily || "recognition").toLowerCase();
  const legacy = String(item?.legacyFamily || item?.missingFamily || item?.phrasalQuestionFamily || requested || "recognition").toLowerCase();
  const reference = Object.keys(item?.referenceVariant || {}).length ? item.referenceVariant : item;
  const knownSenses = Array.isArray(item?.knownSenses) ? item.knownSenses : [];
  const preferredSenseKey = String(item?.senseKey || "legacy_default");
  const targetWord = String(reference?.word || item?.word || "").trim();
  if (!conceptId || !targetWord || !String(reference?.question || reference?.explanation || reference?.word || "").trim()) {
    throw new Error(`PHRASAL_REFERENCE_MISSING: ${conceptId || "unknown"}`);
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

  const reviewed = await runAntigravityLunaPipeline<any>({
    instructions,
    input: assignment,
    schema: phrasalSchema(requested),
    criticContext: {
      lane: "phrasal",
      ...assignment,
      recallContract: requested === "recall"
        ? { front: "meaning/situation cue; target hidden", A: "Yaad tha", B: "Confused", C: "Bhool gaya", D: "", correctKey: "A", questionType: "Reverse Recall Card" }
        : null,
    },
    structuralGate: (draft: Json) => phrasalCodeGate(draft, assignment),
    repairInput: (original, current, quality) => ({
      originalAssignment: original,
      currentItem: current,
      critic: { decision: quality.decision, issues: quality.issues, repairInstruction: quality.repairInstruction },
    }),
  });

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
    if (expectedContextCount > 8) throw new Error(`PHRASAL_CONTEXT_SELECTION_INVALID: maximum 8 contextual slots, got ${expectedContextCount}`);

    // Quality-first Stage 1: every Central-selected slot gets its own writer + critic path.
    const finalized = await mapLimit(items, 4, async (item: Json) => await generatePhrasal(item));
    const contextCount = finalized.filter((x) => x.requestedQuestionFamily === "context_fill").length;
    if (contextCount !== expectedContextCount || contextCount > 8) throw new Error(`PHRASAL_CONTEXT_MIX_REJECTED: Central requested ${expectedContextCount}, finalized ${contextCount}`);
    if (new Set(finalized.map(x => x.conceptId)).size !== 20) throw new Error("PHRASAL_CONCEPT_DUPLICATION: finalized batch does not contain 20 distinct concepts");

    const { data: applied, error: applyError } = await db.rpc("english_phrasal_task_apply", { p_run_id: runId, p_items: finalized });
    if (applyError) throw new Error(`PHRASAL_APPLY_FAILED: ${applyError.message}`);

    await audit(db, finalized.map((x) => ({
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
      generated: finalized.length,
      writer: "antigravity",
      antigravityAgent: ANTIGRAVITY_AGENT,
      antigravityModel: ANTIGRAVITY_MODEL,
      writerReasoning: "high",
      critic: "luna",
      criticModel: LUNA_MODEL,
      criticReasoning: "low",
      rareRescueModel: GEMINI_RARE_RESCUE_MODEL,
      rareRescues: finalized.filter(x => x.rareRescue === true).length,
      writerRequests: finalized.reduce((n, x) => n + Number(x.writerRequests || 1), 0),
      criticRequests: finalized.reduce((n, x) => n + Number(x.criticRequests || 1), 0),
      codeRepairs: finalized.reduce((n, x) => n + Number(x.codeRepairCount || 0), 0),
      applied,
    };
  } catch (e) {
    await releaseClaim(db, runId, e);
    throw e;
  }
}

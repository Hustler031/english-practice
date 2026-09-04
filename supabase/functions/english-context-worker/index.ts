import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-english-context-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MODEL = "gpt-5.6-luna";
const OPENAI_URL = "https://api.openai.com/v1/responses";
const AI_TIMEOUT = 18000;

const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown context worker error");
async function rpcNoThrow(db: any, name: string, args: Record<string, unknown>) {
  try {
    await db.rpc(name, args);
  } catch {
    // Best-effort failure/telemetry writes must never turn completed worker work into HTTP 500.
  }
}
function responseText(payload: any) {
  if (typeof payload?.output_text === "string") return payload.output_text;
  for (const item of payload?.output || []) for (const content of item?.content || []) {
    if (content?.type === "output_text") return content.text || "";
  }
  return "";
}
function usage(payload: any) {
  const u = payload?.usage || {};
  return {
    input: Number(u.input_tokens) || 0,
    output: Number(u.output_tokens) || 0,
    reasoning: Number(u.output_tokens_details?.reasoning_tokens) || 0,
    total: Number(u.total_tokens) || 0,
    responseId: String(payload?.id || ""),
  };
}
async function structuredAI(name: string, schema: any, instructions: string, input: any, effort: "low" | "medium" = "low") {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("OPENAI_API_KEY is not configured for english-context-worker");
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), AI_TIMEOUT);
  try {
    const res = await fetch(OPENAI_URL, {
      method: "POST",
      signal: ctrl.signal,
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        reasoning: { effort },
        max_output_tokens: 2600,
        instructions,
        input: JSON.stringify(input),
        text: { format: { type: "json_schema", name, strict: true, schema } },
      }),
    });
    const payload = await res.json();
    if (!res.ok) throw new Error(payload?.error?.message || `OpenAI request failed (${res.status})`);
    const text = responseText(payload);
    if (!text) throw new Error("OpenAI returned no structured output");
    return { data: JSON.parse(text), usage: usage(payload), model: String(payload?.model || MODEL) };
  } catch (e: any) {
    if (e?.name === "AbortError") throw new Error("Background AI request timed out safely");
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

const diagnosisSchema = {
  type: "object",
  additionalProperties: false,
  required: ["diagnosis", "action", "relatedTerms", "requiresTransfer", "urgency", "confidence", "rationale"],
  properties: {
    diagnosis: { type: "string", enum: ["confusion_pair", "retention_problem", "lexical_interference", "rule_gap", "transfer_problem", "no_action"] },
    action: { type: "string", enum: ["targeted_mastery", "transfer_check", "no_action"] },
    relatedTerms: { type: "array", minItems: 0, maxItems: 3, items: { type: "string", minLength: 1, maxLength: 80 } },
    requiresTransfer: { type: "boolean" },
    urgency: { type: "string", enum: ["low", "medium", "high"] },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    rationale: { type: "string", minLength: 1, maxLength: 240 },
  },
};

const transferItemProperties = {
  question: { type: "string", minLength: 12, maxLength: 600 },
  optionA: { type: "string", minLength: 1, maxLength: 220 },
  optionB: { type: "string", minLength: 1, maxLength: 220 },
  optionC: { type: "string", minLength: 1, maxLength: 220 },
  optionD: { type: "string", minLength: 1, maxLength: 220 },
  correctKey: { type: "string", enum: ["A", "B", "C", "D"] },
  explanation: { type: "string", minLength: 20, maxLength: 700 },
  questionType: { type: "string", minLength: 1, maxLength: 80 },
  difficulty: { type: "string", enum: ["Moderate", "Hard"] },
  word: { type: "string", maxLength: 100 },
  relatedTerms: { type: "array", minItems: 0, maxItems: 8, items: { type: "string", minLength: 1, maxLength: 100 } },
};
const transferDraftSchema = {
  type: "object",
  additionalProperties: false,
  required: ["question", "optionA", "optionB", "optionC", "optionD", "correctKey", "explanation", "questionType", "difficulty", "word", "relatedTerms"],
  properties: transferItemProperties,
};
const transferCriticSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "question", "optionA", "optionB", "optionC", "optionD", "correctKey", "explanation", "questionType", "difficulty", "word", "relatedTerms",
    "ambiguous", "qualityScore", "exactlyOneCorrect", "closeDistractors", "notObviouslyEliminable", "sscDifficultyFit", "conceptFidelity",
    "freshContext", "obviousElimination", "distractorCloseness", "semanticNoveltyScore", "realisticTrapCount"
  ],
  properties: {
    ...transferItemProperties,
    ambiguous: { type: "boolean" },
    qualityScore: { type: "number", minimum: 0, maximum: 1 },
    exactlyOneCorrect: { type: "boolean" },
    closeDistractors: { type: "boolean" },
    notObviouslyEliminable: { type: "boolean" },
    sscDifficultyFit: { type: "boolean" },
    conceptFidelity: { type: "boolean" },
    freshContext: { type: "boolean" },
    obviousElimination: { type: "boolean" },
    distractorCloseness: { type: "number", minimum: 0, maximum: 1 },
    semanticNoveltyScore: { type: "number", minimum: 0, maximum: 1 },
    realisticTrapCount: { type: "integer", minimum: 0, maximum: 3 },
  },
};

const revisionItemProperties = {
  question: { type: "string", minLength: 8, maxLength: 600 },
  optionA: { type: "string", minLength: 1, maxLength: 220 },
  optionB: { type: "string", minLength: 1, maxLength: 220 },
  optionC: { type: "string", minLength: 1, maxLength: 220 },
  optionD: { type: "string", minLength: 1, maxLength: 220 },
  correctKey: { type: "string", enum: ["A", "B", "C", "D"] },
  explanation: { type: "string", minLength: 20, maxLength: 900 },
};
const revisionDraftSchema = {
  type: "object",
  additionalProperties: false,
  required: ["question", "optionA", "optionB", "optionC", "optionD", "correctKey", "explanation"],
  properties: revisionItemProperties,
};
const revisionCriticSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "item", "exactlyOneCorrect", "closeDistractors", "notObviouslyEliminable", "explanationMatches", "noStaleExplanation", "noAmbiguity",
    "faithfulConcept", "fairDifficulty", "sscDifficultyFit", "obviousElimination", "difficultyArtificial", "distractorCloseness", "realisticTrapCount",
    "qualityScore", "rationale"
  ],
  properties: {
    item: { type: "object", additionalProperties: false, required: ["question", "optionA", "optionB", "optionC", "optionD", "correctKey", "explanation"], properties: revisionItemProperties },
    exactlyOneCorrect: { type: "boolean" },
    closeDistractors: { type: "boolean" },
    notObviouslyEliminable: { type: "boolean" },
    explanationMatches: { type: "boolean" },
    noStaleExplanation: { type: "boolean" },
    noAmbiguity: { type: "boolean" },
    faithfulConcept: { type: "boolean" },
    fairDifficulty: { type: "boolean" },
    sscDifficultyFit: { type: "boolean" },
    obviousElimination: { type: "boolean" },
    difficultyArtificial: { type: "boolean" },
    distractorCloseness: { type: "number", minimum: 0, maximum: 1 },
    realisticTrapCount: { type: "integer", minimum: 0, maximum: 3 },
    qualityScore: { type: "number", minimum: 0, maximum: 1 },
    rationale: { type: "string", minLength: 1, maxLength: 280 },
  },
};

const qualityReviewSchema = {
  type: "object",
  additionalProperties: false,
  required: ["verdict", "exactlyOneCorrect", "recommendedCorrectKey", "ambiguous", "explanationConsistent", "confidence", "rationale"],
  properties: {
    verdict: { type: "string", enum: ["valid", "issue_suspected"] },
    exactlyOneCorrect: { type: "boolean" },
    recommendedCorrectKey: { type: "string", enum: ["A", "B", "C", "D", ""] },
    ambiguous: { type: "boolean" },
    explanationConsistent: { type: "boolean" },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    rationale: { type: "string", minLength: 1, maxLength: 500 },
  },
};

const diagnosisPrompt = `You are the background learning-diagnosis specialist for an SSC CGL English learner. Interpret ONLY the learner's short Add Context note using the supplied question/concept/evidence. Do not chat with the learner and do not produce teaching prose. Classify conservatively. confusion_pair means two explicitly or strongly implied items are being mixed; lexical_interference is a vocabulary/phrase neighbour collision; retention_problem means the learner understands but repeatedly forgets; rule_gap is a grammar/usage rule gap; transfer_problem means understanding exists but application to fresh examples is uncertain; no_action means the note does not justify a learning intervention. relatedTerms must contain only concrete confusable words/phrases/rules useful for bank lookup. Use requiresTransfer=true only when a fresh discrimination/application item is genuinely useful; the database will still search the existing bank first. Never downgrade correctness or invent a weakness merely because a note exists.`;

const transferGeneratePrompt = `Create ONE fresh SSC CGL Tier-1 English transfer/discrimination MCQ for the supplied atomic concept. This learner is already exam-prepared, so a technically valid but obvious question is a failure. Target upper-moderate to hard SSC difficulty, not CAT/GRE obscurity. The wrong options must be close, grammatically parallel where applicable, and genuinely tempting to a prepared SSC learner. At least two distractors should encode real confusions/traps, not random alternatives. Do not allow elimination by basic grammar, length, tone, or an obviously unrelated meaning. Test the SAME concept through a meaningfully different context, not a paraphrase of the source. If explicitRelatedPractice=true, deliberately use the supplied confusableTerms and/or infer a compact, exam-useful confusable cluster around the anchor word/concept; the final choices should discriminate among those related terms. Return relatedTerms containing the actual useful cluster used. Use exactly one defensible answer. explanation must explain why the answer works and why the close distractors fail. Do not claim PYQ provenance.`;

const transferCriticPrompt = `You are the independent final SSC CGL question critic. Edit the draft yourself before judging it. Reject easy-but-valid questions. The final item must require actual recall/discrimination rather than superficial elimination; have exactly one defensible answer; three close, realistic distractors; at least two real SSC-style traps; no grammar/length giveaway; no ambiguity; no artificial or obscure difficulty; and a fresh context that is not a light paraphrase of any supplied source/bank item. sscDifficultyFit is true only for upper-moderate/hard SSC CGL Tier-1 realism. distractorCloseness must reflect how competitive the wrong options really are, not mere topical similarity. semanticNoveltyScore must be low if the stem/context simply restates prior practice. Set obviousElimination=false only if no option is cheaply removable. For explicit related practice, preserve a coherent confusable-word cluster and include the actual cluster in relatedTerms. qualityScore >=0.85 is reserved for a serve-ready item.`;

const revisionGeneratePrompt = `Repair ONE existing SSC CGL English MCQ in response to the learner's explicit improvement reason. This is NOT permission to create a different question. Follow intentRules exactly. For options_too_obvious or distractors_unrelated: preserve the current stem exactly, preserve the existing correct option/key, replace weak distractors with close SSC-realistic alternatives, and rewrite the explanation for the final options. For explanation_weak: preserve the stem and all four options exactly and rewrite only the explanation. For custom feedback: make only the minimum necessary changes while preserving the same atomic concept and requiredCorrectKey. bankReferences are reference material for realistic distractor construction only; never copy another bank question as the replacement. Use them to learn the concept boundary and common traps. When SSC toughness is required, make the distractors competitive for an exam-prepared SSC CGL learner without introducing artificial CAT/GRE difficulty. Never change correctKey from requiredCorrectKey.`;

const revisionCriticPrompt = `You are the independent final quality gate for a user-requested SSC CGL question repair. Edit the draft yourself while obeying intentRules. This is a repair of the question on screen, not a new-question request. For options_too_obvious or distractors_unrelated, the stem and correct option must remain unchanged and at least two distractors must materially improve. For explanation_weak, the stem/options must remain unchanged. The final explanation must match the FINAL options and explain why the correct choice is correct and why the close distractors are wrong. When SSC toughness is required, reject easy-but-valid revisions: require upper-moderate/hard SSC realism, at least two genuine trap distractors, no obviously eliminable option, distractorCloseness >=0.70, no obscure/artificial difficulty, exactly one defensible answer, no ambiguity, and concept fidelity. Mark every boolean true only when genuinely satisfied. qualityScore >=0.85 is reserved for a proposal safe to preview and apply.`;

const qualityReviewPrompt = `Independently audit the supplied canonical SSC English question because the learner doubts the marked correct answer. This is a review only: do not rewrite the canonical question and do not force the existing key to remain correct. Decide whether the current item is valid or an issue is genuinely suspected. Check whether exactly one answer is defensible, whether the marked key matches that answer, whether the explanation supports the key, and whether ambiguity exists. recommendedCorrectKey may differ from the current key if evidence supports it; use an empty string if no single key is defensible. verdict=issue_suspected when the canonical item deserves human/content review. Be conservative and evidence-based.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const token = String(req.headers.get("x-english-context-token") || "").trim();
  if (!token) return reply({ error: "Unauthorized" }, 401);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply({ error: "Supabase service configuration missing" }, 503);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const contextLimit = Math.max(1, Math.min(8, Number(body?.contextLimit) || 6));
  const transferLimit = Math.max(1, Math.min(2, Number(body?.transferLimit) || 1));
  const revisionLimit = Math.max(1, Math.min(2, Number(body?.revisionLimit) || 1));
  const reviewLimit = Math.max(1, Math.min(2, Number(body?.reviewLimit) || 1));
  const started = Date.now();

  const { data: claimedContext, error: contextClaimError } = await db.rpc("english_context_claim", { p_token: token, p_limit: contextLimit });
  if (contextClaimError) return reply({ error: contextClaimError.message }, /unauthorized/i.test(contextClaimError.message) ? 401 : 500);
  const contextItems = Array.isArray(claimedContext?.items) ? claimedContext.items : [];

  let contextDone = 0;
  let contextFailed = 0;
  await Promise.allSettled(contextItems.map(async (item: any) => {
    try {
      const result = await structuredAI("english_context_diagnosis", diagnosisSchema, diagnosisPrompt, item, "low");
      const { error } = await db.rpc("english_apply_context_ai_diagnosis", {
        p_token: token,
        p_note_id: item.noteId,
        p_diagnosis: result.data,
        p_model: result.model,
        p_usage: result.usage,
      });
      if (error) throw new Error(error.message);
      contextDone++;
    } catch (e) {
      contextFailed++;
      await rpcNoThrow(db, "english_fail_context_ai", { p_token: token, p_note_id: item.noteId, p_error: errorText(e) });
    }
  }));

  let transferClaimed = 0;
  let transferDone = 0;
  let transferFailed = 0;
  let revisionClaimed = 0;
  let revisionDone = 0;
  let revisionFailed = 0;
  let reviewClaimed = 0;
  let reviewDone = 0;
  let reviewFailed = 0;
  let nonContextLane = "none";

  const processTransfers = async () => {
    const { data: claimedTransfer, error: transferClaimError } = await db.rpc("english_transfer_claim", { p_token: token, p_limit: transferLimit });
    if (transferClaimError) return;
    const transferItems = Array.isArray(claimedTransfer?.items) ? claimedTransfer.items : [];
    transferClaimed = transferItems.length;
    for (const item of transferItems) {
      try {
        const draft = await structuredAI("english_targeted_transfer_draft", transferDraftSchema, transferGeneratePrompt, item, "low");
        const final = await structuredAI("english_targeted_transfer_critic", transferCriticSchema, transferCriticPrompt, { ...item, draft: draft.data }, "medium");
        const combinedUsage = { generator: draft.usage, critic: final.usage };
        const { error } = await db.rpc("english_apply_generated_transfer", {
          p_token: token,
          p_job_id: item.jobId,
          p_item: final.data,
          p_model: final.model,
          p_usage: combinedUsage,
        });
        if (error) throw new Error(error.message);
        transferDone++;
      } catch (e) {
        transferFailed++;
        await rpcNoThrow(db, "english_fail_transfer_generation", { p_token: token, p_job_id: item.jobId, p_error: errorText(e) });
      }
    }
  };

  const processRevisions = async () => {
    const { data: claimedRevision, error: revisionClaimError } = await db.rpc("english_question_revision_claim", { p_token: token, p_limit: revisionLimit });
    if (revisionClaimError) return;
    const revisionItems = Array.isArray(claimedRevision?.items) ? claimedRevision.items : [];
    revisionClaimed = revisionItems.length;
    for (const item of revisionItems) {
      try {
        const bankReferences = Array.isArray(item?.bankReferences) ? item.bankReferences : [];
        const source: "bank_informed_ai" | "ai_last_resort" = bankReferences.length ? "bank_informed_ai" : "ai_last_resort";
        const draft = await structuredAI("english_question_revision_draft", revisionDraftSchema, revisionGeneratePrompt, item, "low");
        const final = await structuredAI("english_question_revision_critic", revisionCriticSchema, revisionCriticPrompt, {
          ...item,
          generationSource: source,
          draft: draft.data,
        }, "medium");
        const combinedUsage = { generator: draft.usage, critic: final.usage };
        const { error } = await db.rpc("english_apply_question_revision_result", {
          p_token: token,
          p_proposal_id: item.proposalId,
          p_item: final.data.item,
          p_critic: final.data,
          p_source: source,
          p_model: final.model,
          p_usage: combinedUsage,
        });
        if (error) throw new Error(error.message);
        revisionDone++;
      } catch (e) {
        revisionFailed++;
        await rpcNoThrow(db, "english_fail_question_revision", { p_token: token, p_proposal_id: item.proposalId, p_error: errorText(e) });
      }
    }
  };

  const processQualityReviews = async () => {
    const { data: claimedReview, error: reviewClaimError } = await db.rpc("english_question_quality_review_claim", { p_token: token, p_limit: reviewLimit });
    if (reviewClaimError) return;
    const reviewItems = Array.isArray(claimedReview?.items) ? claimedReview.items : [];
    reviewClaimed = reviewItems.length;
    for (const item of reviewItems) {
      try {
        const result = await structuredAI("english_question_quality_review", qualityReviewSchema, qualityReviewPrompt, item, "medium");
        const { error } = await db.rpc("english_apply_question_quality_review_result", {
          p_token: token,
          p_review_id: item.reviewId,
          p_critic: result.data,
          p_model: result.model,
          p_usage: result.usage,
        });
        if (error) throw new Error(error.message);
        reviewDone++;
      } catch (e) {
        reviewFailed++;
        await rpcNoThrow(db, "english_fail_question_quality_review", { p_token: token, p_review_id: item.reviewId, p_error: errorText(e) });
      }
    }
  };

  // Preserve the proven Context -> Transfer worker behavior. Only one non-context AI lane
  // is allowed per invocation, in priority order, so revisions cannot starve Targeted transfers.
  if (Date.now() - started < 25000) {
    await processTransfers();
    if (transferClaimed > 0) {
      nonContextLane = "transfer";
    } else if (Date.now() - started < 25000) {
      await processRevisions();
      if (revisionClaimed > 0) {
        nonContextLane = "revision";
      } else if (Date.now() - started < 25000) {
        await processQualityReviews();
        if (reviewClaimed > 0) nonContextLane = "quality_review";
      }
    }
  }

  const elapsedMs = Date.now() - started;
  const metrics = {
    lane: nonContextLane,
    context: { claimed: contextItems.length, processed: contextDone, failed: contextFailed },
    transfers: { claimed: transferClaimed, processed: transferDone, failed: transferFailed },
    revisions: { claimed: revisionClaimed, processed: revisionDone, failed: revisionFailed },
    qualityReviews: { claimed: reviewClaimed, processed: reviewDone, failed: reviewFailed },
  };
  await rpcNoThrow(db, "english_log_worker_metrics", { p_token: token, p_metrics: metrics, p_elapsed_ms: elapsedMs });

  return reply({ ok: true, model: MODEL, ...metrics, elapsedMs });
});

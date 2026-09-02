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
        max_output_tokens: 2400,
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
const transferSchema = {
  type: "object",
  additionalProperties: false,
  required: ["question", "optionA", "optionB", "optionC", "optionD", "correctKey", "explanation", "questionType", "difficulty", "word", "ambiguous", "qualityScore"],
  properties: {
    question: { type: "string", minLength: 12, maxLength: 600 },
    optionA: { type: "string", minLength: 1, maxLength: 220 },
    optionB: { type: "string", minLength: 1, maxLength: 220 },
    optionC: { type: "string", minLength: 1, maxLength: 220 },
    optionD: { type: "string", minLength: 1, maxLength: 220 },
    correctKey: { type: "string", enum: ["A", "B", "C", "D"] },
    explanation: { type: "string", minLength: 8, maxLength: 500 },
    questionType: { type: "string", minLength: 1, maxLength: 80 },
    difficulty: { type: "string", enum: ["Moderate", "Hard"] },
    word: { type: "string", maxLength: 100 },
    ambiguous: { type: "boolean" },
    qualityScore: { type: "number", minimum: 0, maximum: 1 },
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
  required: ["item", "exactlyOneCorrect", "closeDistractors", "notObviouslyEliminable", "explanationMatches", "noStaleExplanation", "noAmbiguity", "faithfulConcept", "fairDifficulty", "qualityScore", "rationale"],
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
    qualityScore: { type: "number", minimum: 0, maximum: 1 },
    rationale: { type: "string", minLength: 1, maxLength: 280 },
  },
};

const diagnosisPrompt = `You are the background learning-diagnosis specialist for an SSC CGL English learner. Interpret ONLY the learner's short Add Context note using the supplied question/concept/evidence. Do not chat with the learner and do not produce teaching prose. Classify conservatively. confusion_pair means two explicitly or strongly implied items are being mixed; lexical_interference is a vocabulary/phrase neighbour collision; retention_problem means the learner understands but repeatedly forgets; rule_gap is a grammar/usage rule gap; transfer_problem means understanding exists but application to fresh examples is uncertain; no_action means the note does not justify a learning intervention. relatedTerms must contain only concrete confusable words/phrases/rules useful for bank lookup. Use requiresTransfer=true only when a fresh discrimination/application item is genuinely useful; the database will still search the existing bank first. Never downgrade correctness or invent a weakness merely because a note exists.`;
const generatePrompt = `Create ONE fresh SSC CGL English transfer/discrimination MCQ for the supplied atomic concept because Central Intelligence found no alternate owner-visible item in the existing bank. Test the SAME concept through a meaningfully different context, not a paraphrase of the source question. Use four distinct plausible close options and exactly one defensible answer. Moderate/Hard SSC level only, no obscure GRE/CAT vocabulary, no passage-dependent question, no trick ambiguity. explanation must be concise and explain the tested distinction. Do not claim PYQ provenance. Return ambiguous=false only after self-checking.`;
const criticPrompt = `You are an independent final critic/editor for ONE generated SSC CGL English transfer question. Audit the draft against the supplied concept, source question, learner confusion/context and SSC realism. Fix the draft yourself if needed. The final item must test the same atomic concept via fresh transfer/discrimination, must not reproduce or lightly paraphrase the source, must have four unique plausible options, exactly one defensible answer, concise correct explanation, and no passage dependency or obscure vocabulary. Set ambiguous=false only if genuinely unambiguous. qualityScore must reflect your final confidence; use >=0.85 only for a serve-ready item.`;
const revisionGeneratePrompt = `Revise ONE SSC CGL English MCQ in response to the learner's explicit improvement reason. Return the complete atomic replacement bundle: question stem, all four options, the SAME required correct option key, and a newly written matching explanation. Preserve the underlying atomic concept and canonical answer identity. Make distractors close, exam-realistic, grammatically parallel, and plausible; do not make them obviously eliminable. Do not introduce obscure vocabulary, artificial traps, multiple defensible answers, or unfair difficulty. The explanation must explicitly justify the correct answer and distinguish the close distractors; it must not reuse a stale explanation from the base version. If the feedback concerns obvious/unrelated options, materially replace the distractors. If it concerns the explanation or doubtful answer, make the reasoning unambiguous. Never change correctKey from requiredCorrectKey.`;
const revisionCriticPrompt = `You are the independent final quality gate for a user-requested SSC CGL English question revision. Edit the draft yourself before judging it. The final item must preserve the supplied concept and requiredCorrectKey, have exactly one defensible correct answer, three close SSC-realistic distractors, no obviously eliminable option, no ambiguity, and fair exam difficulty. The explanation must be newly written for the FINAL stem/options, explain why the correct option is correct, and distinguish why each close distractor is wrong; it must not be stale text from the base question. For options_too_obvious or distractors_unrelated, at least two distractors must materially change. Mark every boolean true only when the final item genuinely satisfies it. qualityScore >=0.85 is reserved for a proposal safe to preview and apply.`;

function bankRevisionDraft(item: any) {
  const candidate = item?.bankCandidate;
  const required = String(item?.requiredCorrectKey || "").toUpperCase();
  const actual = String(candidate?.correctKey || "").toUpperCase();
  if (!candidate || !["A","B","C","D"].includes(required) || !["A","B","C","D"].includes(actual)) return null;
  const draft: any = {
    question: String(candidate.question || ""),
    optionA: String(candidate.optionA || ""), optionB: String(candidate.optionB || ""),
    optionC: String(candidate.optionC || ""), optionD: String(candidate.optionD || ""),
    correctKey: actual,
    explanation: String(candidate.explanation || ""),
  };
  if (!draft.question || !draft.explanation || !draft.optionA || !draft.optionB || !draft.optionC || !draft.optionD) return null;
  if (actual !== required) {
    const actualField = `option${actual}`;
    const requiredField = `option${required}`;
    const temp = draft[actualField]; draft[actualField] = draft[requiredField]; draft[requiredField] = temp;
    draft.correctKey = required;
  }
  return draft;
}

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
      await db.rpc("english_fail_context_ai", { p_token: token, p_note_id: item.noteId, p_error: errorText(e) }).catch(() => undefined);
    }
  }));

  let transferClaimed = 0;
  let transferDone = 0;
  let transferFailed = 0;
  let revisionClaimed = 0;
  let revisionDone = 0;
  let revisionFailed = 0;

  const processTransfers = async () => {
    const { data: claimedTransfer, error: transferClaimError } = await db.rpc("english_transfer_claim", { p_token: token, p_limit: transferLimit });
    if (transferClaimError) return;
    const transferItems = Array.isArray(claimedTransfer?.items) ? claimedTransfer.items : [];
    transferClaimed = transferItems.length;
    for (const item of transferItems) {
      try {
        const draft = await structuredAI("english_targeted_transfer_draft", transferSchema, generatePrompt, item, "low");
        const final = await structuredAI("english_targeted_transfer_critic", transferSchema, criticPrompt, { ...item, draft: draft.data }, "medium");
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
        await db.rpc("english_fail_transfer_generation", { p_token: token, p_job_id: item.jobId, p_error: errorText(e) }).catch(() => undefined);
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
        let draftData = bankRevisionDraft(item);
        let source: "bank_first" | "ai_last_resort" = "bank_first";
        let generatorUsage: any = null;
        if (!draftData) {
          source = "ai_last_resort";
          const draft = await structuredAI("english_question_revision_draft", revisionDraftSchema, revisionGeneratePrompt, item, "low");
          draftData = draft.data;
          generatorUsage = draft.usage;
        }
        const final = await structuredAI("english_question_revision_critic", revisionCriticSchema, revisionCriticPrompt, {
          ...item,
          generationSource: source,
          draft: draftData,
        }, "medium");
        const combinedUsage = { generator: generatorUsage, critic: final.usage };
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
        await db.rpc("english_fail_question_revision", { p_token: token, p_proposal_id: item.proposalId, p_error: errorText(e) }).catch(() => undefined);
      }
    }
  };

  await Promise.allSettled([processTransfers(), processRevisions()]);

  return reply({
    ok: true,
    model: MODEL,
    context: { claimed: contextItems.length, processed: contextDone, failed: contextFailed },
    transfers: { claimed: transferClaimed, processed: transferDone, failed: transferFailed },
    revisions: { claimed: revisionClaimed, processed: revisionDone, failed: revisionFailed },
    elapsedMs: Date.now() - started,
  });
});

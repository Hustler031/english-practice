import { createClient } from "npm:@supabase/supabase-js@2";

// Scheduler-only worker. Browser JWTs are not used; the private runtime token is
// re-authorized by every claim/apply/fail RPC before service-role work is accepted.
const cors = {
  "Access-Control-Allow-Origin": "null",
  "Access-Control-Allow-Headers": "content-type, x-english-context-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MODEL = "gpt-5.6-luna";
const OPENAI_URL = "https://api.openai.com/v1/responses";
const DRAFT_TIMEOUT_MS = 24_000;
const CRITIC_TIMEOUT_MS = 24_000;
const REVIEW_TIMEOUT_MS = 24_000;

const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown revision worker error");
async function rpcNoThrow(db: any, name: string, args: Record<string, unknown>) {
  try { await db.rpc(name, args); } catch { /* telemetry/failure recording is best effort */ }
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
async function structuredAI(
  name: string,
  schema: any,
  instructions: string,
  input: any,
  effort: "low" | "medium",
  timeoutMs: number,
) {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("AUTH_CONFIG: OPENAI_API_KEY is not configured for english-revision-worker");
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    let res: Response;
    try {
      res = await fetch(OPENAI_URL, {
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
    } catch (e: any) {
      if (e?.name === "AbortError") throw e;
      throw new Error(`NETWORK_TRANSIENT: ${errorText(e)}`);
    }
    let payload: any;
    try { payload = await res.json(); }
    catch { throw new Error(`MALFORMED_OUTPUT: provider returned non-JSON response (${res.status})`); }
    if (!res.ok) {
      const detail = payload?.error?.message || `OpenAI request failed (${res.status})`;
      if (res.status === 429) throw new Error(`RATE_LIMIT: ${detail}`);
      if (res.status >= 500) throw new Error(`PROVIDER_5XX: ${detail}`);
      throw new Error(`NETWORK_TRANSIENT: ${detail}`);
    }
    const text = responseText(payload);
    if (!text) throw new Error("MALFORMED_OUTPUT: OpenAI returned no structured output");
    try {
      return { data: JSON.parse(text), usage: usage(payload), model: String(payload?.model || MODEL) };
    } catch (e) {
      throw new Error(`MALFORMED_OUTPUT: ${errorText(e)}`);
    }
  } catch (e: any) {
    if (e?.name === "AbortError") throw new Error(`AI_TIMEOUT: background AI request timed out safely after ${Math.round(timeoutMs / 1000)}s`);
    throw e;
  } finally { clearTimeout(timer); }
}

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
    "qualityScore", "rationale",
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
  const revisionLimit = Math.max(1, Math.min(1, Number(body?.revisionLimit) || 1));
  const reviewLimit = Math.max(1, Math.min(1, Number(body?.reviewLimit) || 1));
  const started = Date.now();

  const [{ data: claimedRevision, error: revisionClaimError }, { data: claimedReview, error: reviewClaimError }] = await Promise.all([
    db.rpc("english_question_revision_claim_dedicated", { p_token: token, p_limit: revisionLimit }),
    db.rpc("english_question_quality_review_claim", { p_token: token, p_limit: reviewLimit }),
  ]);
  if (revisionClaimError) return reply({ error: revisionClaimError.message }, /unauthorized/i.test(revisionClaimError.message) ? 401 : 500);
  if (reviewClaimError) return reply({ error: reviewClaimError.message }, /unauthorized/i.test(reviewClaimError.message) ? 401 : 500);

  const revisionItems = Array.isArray(claimedRevision?.items) ? claimedRevision.items : [];
  const reviewItems = Array.isArray(claimedReview?.items) ? claimedReview.items : [];
  let revisionDone = 0, revisionFailed = 0, reviewDone = 0, reviewFailed = 0;

  const revisionTask = async () => {
    for (const item of revisionItems) {
      try {
        const bankReferences = Array.isArray(item?.bankReferences) ? item.bankReferences : [];
        const source: "bank_informed_ai" | "ai_last_resort" = bankReferences.length ? "bank_informed_ai" : "ai_last_resort";
        const draft = await structuredAI("english_question_revision_draft", revisionDraftSchema, revisionGeneratePrompt, item, "low", DRAFT_TIMEOUT_MS);
        const final = await structuredAI("english_question_revision_critic", revisionCriticSchema, revisionCriticPrompt, {
          ...item,
          generationSource: source,
          draft: draft.data,
        }, "medium", CRITIC_TIMEOUT_MS);
        const { error } = await db.rpc("english_apply_question_revision_result", {
          p_token: token,
          p_proposal_id: item.proposalId,
          p_item: final.data.item,
          p_critic: final.data,
          p_source: source,
          p_model: final.model,
          p_usage: { generator: draft.usage, critic: final.usage },
        });
        if (error) throw new Error(error.message);
        revisionDone++;
      } catch (e) {
        revisionFailed++;
        await rpcNoThrow(db, "english_fail_question_revision", {
          p_token: token,
          p_proposal_id: item.proposalId,
          p_error: errorText(e),
        });
      }
    }
  };

  const reviewTask = async () => {
    for (const item of reviewItems) {
      try {
        const result = await structuredAI("english_question_quality_review", qualityReviewSchema, qualityReviewPrompt, item, "medium", REVIEW_TIMEOUT_MS);
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
        await rpcNoThrow(db, "english_fail_question_quality_review", {
          p_token: token,
          p_review_id: item.reviewId,
          p_error: errorText(e),
        });
      }
    }
  };

  // Both dedicated Quality lanes may proceed together; revision's draft->critic remains serial.
  // This keeps the invocation bounded by the revision lane (~48s) rather than ~72s sequentially.
  await Promise.allSettled([revisionTask(), reviewTask()]);

  const elapsedMs = Date.now() - started;
  const metrics = {
    lane: "revision_quality_dedicated",
    context: { claimed: 0, processed: 0, failed: 0 },
    transfers: { claimed: 0, processed: 0, failed: 0 },
    revisions: { claimed: revisionItems.length, processed: revisionDone, failed: revisionFailed },
    qualityReviews: { claimed: reviewItems.length, processed: reviewDone, failed: reviewFailed },
  };
  await rpcNoThrow(db, "english_log_worker_metrics", { p_token: token, p_metrics: metrics, p_elapsed_ms: elapsedMs });
  return reply({ ok: true, model: MODEL, ...metrics, elapsedMs });
});

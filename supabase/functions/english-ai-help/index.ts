import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown AI Help error");
function responseText(payload: any) {
  if (typeof payload?.output_text === "string") return payload.output_text;
  for (const item of payload?.output || []) {
    for (const content of item?.content || []) {
      if (content?.type === "output_text") return content.text || "";
    }
  }
  return "";
}

const schema = {
  type: "object",
  additionalProperties: false,
  required: ["help", "diagnosis", "confidence", "action_code", "reason"],
  properties: {
    help: { type: "string", minLength: 1, maxLength: 900 },
    diagnosis: {
      type: "string",
      enum: [
        "rule_gap", "knowledge_gap", "confusion_pair", "retention_issue",
        "explanation_issue", "questionable_key", "ambiguous_wording",
        "transfer_needed", "no_action"
      ]
    },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    action_code: {
      type: "string",
      enum: ["targeted_mastery", "retention_check", "quality_review", "no_action"]
    },
    reason: { type: "string", minLength: 1, maxLength: 500 }
  }
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  try {
    const auth = req.headers.get("Authorization") || "";
    const token = auth.replace(/^Bearer\s+/i, "").trim();
    if (!token) return reply({ error: "Authentication required" }, 401);

    const url = Deno.env.get("SUPABASE_URL");
    const anon = Deno.env.get("SUPABASE_ANON_KEY");
    const openaiKey = Deno.env.get("OPENAI_API_KEY");
    if (!url || !anon) return reply({ error: "Supabase configuration unavailable" }, 503);
    if (!openaiKey) return reply({ error: "AI Help is temporarily unavailable" }, 503);

    const supabase = createClient(url, anon, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await supabase.auth.getUser(token);
    if (userError || !userData.user) return reply({ error: "Authentication required" }, 401);

    const body = await req.json().catch(() => ({}));
    const problem = String(body?.problem || "").trim().slice(0, 600);
    const questionId = String(body?.question_id || body?.context?.question_id || "").trim();
    if (!problem) return reply({ error: "A short problem is required." }, 400);
    if (!questionId) return reply({ error: "Question context is required." }, 400);

    const { data: context, error: contextError } = await supabase.rpc("english_get_ai_help_context", {
      p_question_id: questionId,
    });
    if (contextError) throw new Error(`Could not load learning context: ${contextError.message}`);

    const latestUi = {
      selected_answer: body?.context?.selected_answer ?? null,
      correct_answer: body?.context?.correct_answer ?? null,
      module: body?.context?.module ?? null,
    };
    const model = Deno.env.get("OPENAI_AI_HELP_MODEL") || "gpt-5.6-luna";
    const instructions = [
      "You are the English V2 SSC CGL manual AI Help specialist.",
      "The learner explicitly reported a problem on the current question. Diagnose it using the trusted server-side learning context, not only the learner's wording.",
      "Keep visible help concise, practical and exam-oriented. Explain only what resolves the reported problem.",
      "Do not create extra work by default. Choose targeted_mastery only for a durable rule/knowledge/confusion gap with strong evidence; retention_check for uncertain recall/guessing/forgetting; quality_review only when the question/key/explanation itself is plausibly defective; otherwise no_action.",
      "Never silently rewrite a question. Quality concerns are review flags only.",
      "Return only the required structured JSON."
    ].join("\n");

    const aiResponse = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { Authorization: `Bearer ${openaiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        reasoning: { effort: "low" },
        max_output_tokens: 500,
        instructions,
        input: JSON.stringify({ learner_problem: problem, current_ui: latestUi, learning_context: context }),
        text: { format: { type: "json_schema", name: "english_ai_help", strict: true, schema } },
      }),
    });
    const payload = await aiResponse.json();
    if (!aiResponse.ok) throw new Error(payload?.error?.message || `OpenAI request failed (${aiResponse.status})`);
    const text = responseText(payload);
    if (!text) throw new Error("OpenAI returned no structured AI Help response");
    const parsed = JSON.parse(text);
    const usage = payload?.usage || {};

    const { data: applied, error: applyError } = await supabase.rpc("english_apply_ai_help_result", {
      p_question_id: questionId,
      p_model: String(payload?.model || model),
      p_diagnosis: parsed.diagnosis,
      p_confidence: parsed.confidence,
      p_action_code: parsed.action_code,
      p_help: parsed.help,
      p_input_tokens: Number(usage.input_tokens) || 0,
      p_output_tokens: Number(usage.output_tokens) || 0,
      p_reasoning_tokens: Number(usage.output_tokens_details?.reasoning_tokens) || 0,
      p_metadata: {
        reason: parsed.reason,
        user_problem: problem,
        response_id: payload?.id || null,
      },
    });
    if (applyError) throw new Error(`Could not save AI Help learning action: ${applyError.message}`);

    return reply({
      help: parsed.help,
      diagnosis: parsed.diagnosis,
      confidence: parsed.confidence,
      action: applied?.action_taken || "none",
    });
  } catch (error) {
    console.error("english-ai-help", errorText(error));
    return reply({ error: "AI Help is temporarily unavailable. The normal explanation remains available." }, 503);
  }
});

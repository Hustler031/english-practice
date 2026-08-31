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

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
function outputText(payload: any) {
  if (typeof payload?.output_text === "string") return payload.output_text;
  for (const item of payload?.output || []) for (const content of item?.content || []) if (content?.type === "output_text" && typeof content.text === "string") return content.text;
  return "";
}
async function openaiJson(name: string, schema: Record<string, unknown>, instructions: string, input: unknown) {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("OPENAI_API_KEY is not configured for english-ssc-sprint");
  const model = "gpt-5.6-luna";
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
  return JSON.parse(text);
}
function sprintSchema(count: number) {
  const option = {
    type: "object", additionalProperties: false, required: ["key", "text"],
    properties: { key: { type: "string", enum: ["A", "B", "C", "D"] }, text: { type: "string", minLength: 1 } },
  };
  return {
    type: "object", additionalProperties: false, required: ["items"], properties: {
      items: { type: "array", minItems: count, maxItems: count, items: {
        type: "object", additionalProperties: false,
        required: ["itemKey", "category", "questionType", "question", "options", "correctKey", "explanation", "sourceType", "canonicalQuestionId", "ambiguous", "qualityScore", "metadata"],
        properties: {
          itemKey: { type: "string", minLength: 1 }, category: { type: "string", minLength: 1 }, questionType: { type: "string", minLength: 1 }, question: { type: "string", minLength: 1 },
          options: { type: "array", minItems: 4, maxItems: 4, items: option }, correctKey: { type: "string", enum: ["A", "B", "C", "D"] }, explanation: { type: "string", minLength: 1 },
          sourceType: { type: "string", enum: ["GPT Generated", "GPT Variant of Known Concept"] }, canonicalQuestionId: { type: ["string", "null"] },
          ambiguous: { type: "boolean", enum: [false] }, qualityScore: { type: "number", minimum: 0.8, maximum: 1 },
          metadata: { type: "object", additionalProperties: false, required: ["conceptKey", "trapTested"], properties: { conceptKey: { type: "string" }, trapTested: { type: "string" } } },
        },
      } },
    },
  };
}
function analysisSchema(count: number) {
  return {
    type: "object", additionalProperties: false, required: ["items"], properties: {
      items: { type: "array", minItems: count, maxItems: count, items: {
        type: "object", additionalProperties: false, required: ["position", "diagnosis", "action", "confusedWith", "rationale"],
        properties: {
          position: { type: "integer", minimum: 1, maximum: 25 }, diagnosis: { type: "string", enum: diagnosisLabels }, action: { type: "string", enum: actions },
          confusedWith: { type: "string" }, rationale: { type: "string", minLength: 1 },
        },
      } },
    },
  };
}
const generationInstructions = `You are the English V2 SSC CGL Sprint generator. Generate exam-condition objective English questions only.
Hard rules:
- Never generate Reading Comprehension, passages, or passage-dependent items.
- Follow the supplied blueprint rather than making a random set.
- Standard mode must remain a balanced SSC mix: roughly 56% balanced coverage, 28% current weakness transfer, 16% fresh challenge.
- Weakness/trap/mistake modes must use fresh transfer contexts; do not replay seed text verbatim.
- Use plausible adversarial SSC-style distractors: close meanings, confusable phrasal verbs, spelling near-neighbours, fixed-preposition traps, and natural-sounding grammar traps.
- Every item must have exactly one defensible answer. If an item is semantically or grammatically ambiguous, replace it before returning.
- Do not claim any generated question is an SSC PYQ. Use GPT Generated, or GPT Variant of Known Concept when it is deliberately derived from a supplied canonical seed.
- canonicalQuestionId may be copied only from a supplied targeted/previous seed that genuinely underlies the new variant; otherwise return null.
- qualityScore must reflect your own final quality review and must be >= 0.80. ambiguous must be false.
- Options must contain unique A/B/C/D keys and four distinct texts.
- Explanation should be useful after the Sprint, but must not leak into question/options.`;
const analysisInstructions = `You are the English V2 SSC Sprint mistake analyst. Diagnose each wrong answer using only the supplied completed-Sprint evidence.
Distinguish genuine learning problems from execution errors. Use Targeted Mastery only for a real Knowledge Gap, Rule Gap, durable Confusion, or a recurring Distractor Trap. Careless, Time Pressure, and Misread should normally remain execution evidence and must not pollute the Targeted queue. Weakness Drill or Trap Practice can be recommended without routing the item to Targeted. Keep confusedWith concise and specific (for example "put off vs put out"). Return one diagnosis for every supplied wrong position, no more and no less.`;

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
      let generated = await openaiJson("english_ssc_sprint", sprintSchema(count), generationInstructions, context);
      let created = await supabase.rpc("english_create_sprint_session", { p_mode: mode, p_items: generated.items, p_blueprint: context?.blueprint || {} });
      if (created.error) {
        generated = await openaiJson("english_ssc_sprint_repair", sprintSchema(count), generationInstructions + `\nThe previous set failed deterministic validation. Repair the full set. Validation error: ${created.error.message}`, context);
        created = await supabase.rpc("english_create_sprint_session", { p_mode: mode, p_items: generated.items, p_blueprint: context?.blueprint || {} });
      }
      if (created.error) throw created.error;
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
      const analyzed = await openaiJson("english_ssc_sprint_analysis", analysisSchema(wrong.length), analysisInstructions, context);
      const positions = new Set(wrong.map((x: any) => Number(x.position)));
      if (!Array.isArray(analyzed.items) || analyzed.items.some((x: any) => !positions.has(Number(x.position)))) throw new Error("Sprint analysis positions do not match wrong items");
      const saved = await supabase.rpc("english_save_sprint_analysis", { p_session_id: sessionId, p_analysis: analyzed.items });
      if (saved.error) throw saved.error;
      return reply({ ok: true, analysis: analyzed.items, targetedAdded: saved.data?.targetedAdded || 0 });
    }

    return reply({ ok: false, error: "Unknown action" }, 400);
  } catch (error) {
    console.error("english-ssc-sprint", error);
    return reply({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});

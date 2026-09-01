import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get("Authorization") || "";
    const token = auth.replace(/^Bearer\s+/i, "");
    if (!token) return new Response(JSON.stringify({ error: "Authentication required" }), { status: 401 });
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: userData, error: userError } = await supabase.auth.getUser(token);
    if (userError || !userData.user) return new Response(JSON.stringify({ error: "Authentication required" }), { status: 401 });
    const body = await req.json();
    const context = body?.context || {};
    const problem = String(body?.problem || "").trim().slice(0, 600);
    if (!problem) return new Response(JSON.stringify({ error: "A short problem is required." }), { status: 400 });
    const model = Deno.env.get("OPENAI_MODEL") || "gpt-5.6-luna";
    const prompt = [
      "You are Luna, a concise SSC English learning specialist.",
      "Answer the learner's short question using the supplied question context.",
      "Return JSON only with keys: help (string, <= 120 words), diagnosis (one of rule_gap, knowledge_gap, confusion_pair, retention_issue, explanation_issue, questionable_key, ambiguous_wording, transfer_needed, no_action), confidence (0 to 1), recommended_action (short string).",
      JSON.stringify({ problem, context })
    ].join("\n");
    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + Deno.env.get("OPENAI_API_KEY") },
      body: JSON.stringify({ model, input: prompt, text: { format: { type: "json_object" } }, max_output_tokens: 400 })
    });
    if (!response.ok) throw new Error("OpenAI request failed");
    const raw = await response.json();
    const text = raw.output?.flatMap((x: any) => x.content || []).find((x: any) => x.type === "output_text")?.text || "{}";
    const parsed = JSON.parse(text);
    const usage = raw.usage || {};
    await supabase.from("ai_interventions").insert({
      user_id: userData.user.id, trigger: "learner_ai_help", request_type: "quiz_ai_help",
      question_id: context.question_id || null, concept_id: context.concept_id || null,
      model, diagnosis: parsed, confidence: parsed.confidence ?? null,
      recommended_action: parsed.recommended_action || null,
      input_tokens: usage.input_tokens ?? null, output_tokens: usage.output_tokens ?? null,
      reasoning_tokens: usage.reasoning_tokens ?? null, status: "completed"
    });
    return new Response(JSON.stringify(parsed), { headers: { "Content-Type": "application/json" } });
  } catch (error) {
    return new Response(JSON.stringify({ error: "AI Help is temporarily unavailable." }), { status: 503, headers: { "Content-Type": "application/json" } });
  }
});
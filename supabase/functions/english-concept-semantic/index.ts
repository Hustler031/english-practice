import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-english-semantic-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown semantic worker error");

function semanticText(type: string, row: any) {
  const parts: string[] = [];
  if (type === "concept") {
    parts.push(`Domain: ${row.domain || "English"}`);
    parts.push(`Skill family: ${row.skill_family || "Unclassified"}`);
    parts.push(`Concept: ${row.name || row.concept_id}`);
    if (row.description) parts.push(`Description: ${row.description}`);
  } else if (type === "question") {
    if (row.topic) parts.push(`Topic: ${row.topic}`);
    if (row.subtopic) parts.push(`Subtopic: ${row.subtopic}`);
    if (row.word) parts.push(`Word or item: ${row.word}`);
    if (row.question_type) parts.push(`Question type: ${row.question_type}`);
    parts.push(`Question: ${row.question || ""}`);
    if (row.explanation) parts.push(`Explanation: ${row.explanation}`);
  } else {
    if (row.word) parts.push(`Saved item: ${row.word}`);
    if (row.part_of_speech) parts.push(`Part of speech: ${row.part_of_speech}`);
    if (row.meaning) parts.push(`Meaning: ${row.meaning}`);
    if (row.context) parts.push(`Context: ${row.context}`);
    if (row.synonyms) parts.push(`Synonyms: ${row.synonyms}`);
    if (row.antonyms) parts.push(`Antonyms: ${row.antonyms}`);
    if (row.example) parts.push(`Example: ${row.example}`);
    if (row.explanation) parts.push(`Explanation: ${row.explanation}`);
    if (row.question) parts.push(`Practice question: ${row.question}`);
  }
  return parts.join("\n").slice(0, 12000);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const token = String(req.headers.get("x-english-semantic-token") || "").trim();
  if (!token) return reply({ error: "Unauthorized" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!url || !serviceKey) return reply({ error: "Supabase service configuration missing" }, 503);
  if (!openaiKey) return reply({ error: "OPENAI_API_KEY is not configured" }, 503);

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const limit = Math.max(1, Math.min(500, Number(body?.limit) || 200));
  const model = String(Deno.env.get("OPENAI_EMBEDDING_MODEL") || "text-embedding-3-small");
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data: claimed, error: claimError } = await db.rpc("english_semantic_claim", { p_token: token, p_limit: limit });
  if (claimError) return reply({ error: claimError.message }, /unauthorized/i.test(claimError.message) ? 401 : 500);
  const work = Array.isArray(claimed) ? claimed : [];
  if (!work.length) return reply({ ok: true, claimed: 0, processed: 0, model });

  try {
    const { data: payloadRows, error: payloadError } = await db.rpc("english_semantic_payload_batch", {
      p_token: token,
      p_items: work.map((x: any) => ({ entity_type: x.entity_type, entity_id: x.entity_id })),
    });
    if (payloadError) throw new Error(payloadError.message);
    const payloads = Array.isArray(payloadRows) ? payloadRows : [];
    const byKey = new Map(payloads.map((x: any) => [`${x.entity_type}:${x.entity_id}`, x.payload]));

    const prepared = work.map((item: any) => {
      const type = String(item.entity_type);
      const id = String(item.entity_id);
      const row = byKey.get(`${type}:${id}`);
      return row ? { type, id, row, text: semanticText(type, row) } : null;
    }).filter(Boolean) as Array<{type:string,id:string,row:any,text:string}>;

    const missing = work.filter((item: any) => !prepared.some((x) => x.type === String(item.entity_type) && x.id === String(item.entity_id)));
    if (missing.length) {
      await db.rpc("english_semantic_fail_batch", {
        p_token: token,
        p_items: missing.map((x: any) => ({ entity_type: x.entity_type, entity_id: x.entity_id, error: "Semantic source row not found" })),
      });
    }
    if (!prepared.length) return reply({ ok: true, claimed: work.length, processed: 0, missing: missing.length, model });

    const embResponse = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: { Authorization: `Bearer ${openaiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model, input: prepared.map((x) => x.text), dimensions: 1536, encoding_format: "float" }),
    });
    const embPayload = await embResponse.json();
    if (!embResponse.ok) throw new Error(embPayload?.error?.message || `OpenAI embeddings failed (${embResponse.status})`);
    const vectors = Array.isArray(embPayload?.data) ? embPayload.data : [];
    if (vectors.length !== prepared.length) throw new Error("Embedding count did not match claimed semantic items");

    const vectorRows = prepared.map((x, index) => {
      const vector = vectors[index]?.embedding;
      if (!Array.isArray(vector) || vector.length !== 1536) throw new Error(`Invalid embedding for ${x.type}:${x.id}`);
      const embedding = `[${vector.join(",")}]`;
      const exclude = x.type === "concept" ? x.id : x.type === "saved" ? String(x.row?.current_concept || "") : "";
      return { entity_type: x.type, entity_id: x.id, embedding, exclude_concept: exclude };
    });

    const { data: candidateMap, error: candidateError } = await db.rpc("english_semantic_candidates_batch", {
      p_token: token,
      p_items: vectorRows.map((x) => ({ entity_id: x.entity_id, embedding: x.embedding, exclude_concept: x.exclude_concept })),
      p_limit: 5,
    });
    if (candidateError) throw new Error(candidateError.message);

    const finished = vectorRows.map((x) => {
      const candidates = Array.isArray(candidateMap?.[x.entity_id]) ? candidateMap[x.entity_id] : [];
      const nearest = candidates[0] || null;
      return {
        entity_type: x.entity_type,
        entity_id: x.entity_id,
        embedding: x.embedding,
        model,
        nearest_concept_id: nearest?.concept_id || null,
        similarity: nearest?.similarity ?? null,
        candidates,
      };
    });

    const { data: processed, error: finishError } = await db.rpc("english_semantic_finish_batch", { p_token: token, p_items: finished });
    if (finishError) throw new Error(finishError.message);
    await db.rpc("english_semantic_log_usage", {
      p_token: token,
      p_model: model,
      p_item_count: finished.length,
      p_usage: embPayload?.usage || {},
      p_metadata: { entityTypes: [...new Set(finished.map((x) => x.entity_type))] },
    });

    return reply({
      ok: true,
      claimed: work.length,
      processed: Number(processed) || finished.length,
      missing: missing.length,
      model,
      usage: embPayload?.usage || null,
    });
  } catch (error) {
    const message = errorText(error);
    await db.rpc("english_semantic_fail_batch", {
      p_token: token,
      p_items: work.map((x: any) => ({ entity_type: x.entity_type, entity_id: x.entity_id, error: message })),
    }).catch(() => undefined);
    return reply({ error: message, claimed: work.length }, 502);
  }
});

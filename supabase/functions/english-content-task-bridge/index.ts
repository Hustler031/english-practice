import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";
import { runHinduGeneration } from "./generation.ts";
import { runPhrasalGeneration } from "./phrasal-generation.ts";

const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "english-content-automation";
const REPOSITORY = "Hustler031/telegram-media-bot";
const PHRASE_REF = "refs/heads/automation/english-phrasal";
const HINDU_REF = "refs/heads/automation/english-hindu";
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks`));

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown content automation error");

async function authorize(req: Request): Promise<"phrasal"|"hindu"> {
  const auth = String(req.headers.get("authorization") || "");
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!token) throw new Error("missing GitHub OIDC token");
  const { payload } = await jwtVerify(token, JWKS, { issuer: ISSUER, audience: AUDIENCE, algorithms: ["RS256"] });
  if (payload.repository !== REPOSITORY) throw new Error("repository claim rejected");
  if (payload.event_name !== "push") throw new Error("event claim rejected");
  if (payload.ref === PHRASE_REF) return "phrasal";
  if (payload.ref === HINDU_REF) return "hindu";
  throw new Error("ref claim rejected");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let lane: "phrasal"|"hindu";
  try { lane = await authorize(req); }
  catch (e) { return json({ error: e instanceof Error ? e.message : "OIDC authorization failed" }, 401); }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Supabase service configuration missing" }, 503);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  let body: any = {};
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const action = String(body?.action || "");

  if(action==="run"){
    try{
      const result=lane==="phrasal"?await runPhrasalGeneration(db):await runHinduGeneration(db);
      return json(result??{ok:true});
    }catch(e){return json({ok:false,lane,error:errorText(e)},500)}
  }

  if (lane === "phrasal") {
    if (action === "claim") {
      const { data, error } = await db.rpc("english_phrasal_task_claim");
      if (error) return json({ error: error.message }, 500);
      return json(data ?? { ok: true, count: 0 });
    }
    if (action === "apply") {
      const runId = String(body?.runId || "");
      const items = Array.isArray(body?.items) ? body.items : null;
      if (!runId || !items || items.length !== 20) return json({ error: "Phrasal runId and exactly 20 items are required" }, 400);
      const { data, error } = await db.rpc("english_phrasal_task_apply", { p_run_id: runId, p_items: items });
      if (error) return json({ error: error.message }, 500);
      return json(data ?? { ok: true });
    }
    return json({ error: "Unknown Phrasal action" }, 400);
  }

  if (action === "claim") {
    const { data, error } = await db.rpc("english_hindu_task_claim");
    if (error) return json({ error: error.message }, 500);
    return json(data ?? { ok: true, count: 0 });
  }
  if (action === "check") {
    const runId = String(body?.runId || "");
    const candidates = Array.isArray(body?.candidates) ? body.candidates : null;
    if (!runId || !candidates || candidates.length < 1 || candidates.length > 60) return json({ error: "Hindu runId and 1-60 candidates are required" }, 400);
    const { data, error } = await db.rpc("english_hindu_task_check_candidates", { p_run_id: runId, p_candidates: candidates });
    if (error) return json({ error: error.message }, 500);
    return json(data ?? { ok: true, items: [] });
  }
  if (action === "apply") {
    const runId = String(body?.runId || "");
    const items = Array.isArray(body?.items) ? body.items : null;
    if (!runId || !items || items.length > 20) return json({ error: "Hindu runId and up to 20 items are required" }, 400);
    const { data, error } = await db.rpc("english_hindu_task_apply", { p_run_id: runId, p_items: items });
    if (error) return json({ error: error.message }, 500);
    return json(data ?? { ok: true });
  }
  return json({ error: "Unknown Hindu action" }, 400);
});

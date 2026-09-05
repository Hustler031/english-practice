import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "english-saved-enrichment";
const REPOSITORY = "Hustler031/english-practice";
const QUEUE_REF = "refs/heads/automation/saved-enrichment";
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks`));

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  },
});

async function authorize(req: Request) {
  const auth = String(req.headers.get("authorization") || "");
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!token) throw new Error("missing GitHub OIDC token");

  const { payload } = await jwtVerify(token, JWKS, {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["RS256"],
  });

  if (payload.repository !== REPOSITORY) throw new Error("repository claim rejected");
  if (payload.ref !== QUEUE_REF) throw new Error("ref claim rejected");
  if (payload.event_name !== "push") throw new Error("event claim rejected");
  return payload;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    await authorize(req);
  } catch (e) {
    const message = e instanceof Error ? e.message : "OIDC authorization failed";
    return json({ error: message }, 401);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Supabase service configuration missing" }, 503);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  let body: any = {};
  try { body = await req.json(); }
  catch { return json({ error: "Invalid JSON body" }, 400); }

  const action = String(body?.action || "");
  if (action === "claim") {
    const limit = Math.max(1, Math.min(10, Number(body?.limit) || 10));
    const { data, error } = await db.rpc("english_saved_enrichment_task_claim", { p_limit: limit });
    if (error) return json({ error: error.message }, 500);
    return json(data ?? { ok: true, count: 0, items: [] });
  }

  if (action === "apply") {
    const runId = String(body?.runId || "");
    const items = Array.isArray(body?.items) ? body.items : null;
    if (!runId || !items) return json({ error: "runId and items are required" }, 400);
    if (items.length < 1 || items.length > 10) return json({ error: "items must contain 1-10 entries" }, 400);

    const { data, error } = await db.rpc("english_saved_enrichment_task_apply", {
      p_run_id: runId,
      p_items: items,
    });
    if (error) return json({ error: error.message }, 500);
    return json(data ?? { ok: true });
  }

  return json({ error: "Unknown action" }, 400);
});

import { createClient } from "npm:@supabase/supabase-js@2";
import { runPhrasalGeneration } from "../english-content-task-bridge/phrasal-generation.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-english-context-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
});
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown Phrasal worker error");

async function authorize(req: Request, db: any) {
  const privateToken = String(req.headers.get("x-english-context-token") || "").trim();
  if (privateToken) {
    const { data, error } = await db.rpc("english_phrasal_worker_token_authorized", { p_token: privateToken });
    if (error || data !== true) throw new Error("Unauthorized private worker token");
    return { mode: "scheduler" as const, userId: null };
  }

  const auth = String(req.headers.get("authorization") || "");
  const accessToken = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!accessToken) throw new Error("Authentication required");
  const { data, error } = await db.auth.getUser(accessToken);
  const userId = String(data?.user?.id || "");
  if (error || !userId) throw new Error("Authentication required");
  const { data: ownerOk, error: ownerError } = await db.rpc("english_phrasal_worker_user_authorized", { p_user_id: userId });
  if (ownerError || ownerOk !== true) throw new Error("Phrasal maintenance owner rejected");
  return { mode: "app" as const, userId };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Supabase service configuration missing" }, 503);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  let caller: { mode: "scheduler" | "app"; userId: string | null };
  try { caller = await authorize(req, db); }
  catch (e) { return json({ ok: false, error: errorText(e) }, 401); }

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const action = String(body?.action || "run");
  if (action !== "run") return json({ ok: false, error: "Unknown action" }, 400);

  try {
    const result = await runPhrasalGeneration(db);
    return json({ ...(result || { ok: true }), trigger: caller.mode });
  } catch (e) {
    return json({ ok: false, lane: "phrasal", trigger: caller.mode, error: errorText(e) }, 500);
  }
});

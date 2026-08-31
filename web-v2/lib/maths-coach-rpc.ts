"use client";

import { mathsLocalSafe, mathsRpc, rememberMathsSession, type MathsSession } from "@/lib/maths-rpc";
import { supabaseBrowser } from "@/lib/supabase";

type RpcArgs = Record<string, unknown>;

async function rawRpc<T>(name: string, args?: RpcArgs): Promise<T> {
  const { data, error } = await supabaseBrowser().rpc(name, args ?? {});
  if (error) throw error;
  return data as T;
}

// Only score-critical writes in timed modes bypass the legacy outbox.
// Ordinary Maths sessions continue through mathsRpc and retain offline/durable retry semantics.
const coachCriticalWrites = new Set(["maths_submit_answer", "maths_finish_session"]);
function isTimedSavedSession(sessionId: string) {
  if (typeof window === "undefined" || !sessionId) return false;
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (!key?.startsWith("maths:v2:session:") || !key.endsWith(`:${sessionId}`)) continue;
      const session = JSON.parse(localStorage.getItem(key) || "null") as MathsSession | null;
      const mode = String(session?.mode || "").toLowerCase();
      return mode === "section_sprint" || (mode === "calculation_speed" && Boolean(session?.params?.calculationTimed));
    }
  } catch {}
  return false;
}

export async function mathsCoachRpc<T = unknown>(name: string, args?: RpcArgs): Promise<T> {
  if (mathsLocalSafe() && /^maths_start_(daily|repair|mixed|sprint|calculation)$/.test(name)) {
    const out = await rawRpc<T>("maths_get_local_safe_start_v45", { p_start_rpc: name, p_args: args ?? {} });
    const session = out as MathsSession;
    if (session?.sessionId) rememberMathsSession(session);
    return out;
  }
  const sessionId = String(args?.p_session_id ?? "");
  if (!mathsLocalSafe() && coachCriticalWrites.has(name) && isTimedSavedSession(sessionId)) return rawRpc<T>(name, args);
  return mathsRpc<T>(name, args);
}

export async function startMathsCoachSession(name: string, args?: RpcArgs): Promise<MathsSession> {
  const session = await mathsCoachRpc<MathsSession>(name, args);
  if (!session?.ok) throw new Error(session?.message || "No eligible Maths questions found.");
  if (!session.sessionId) throw new Error("Maths session did not return an ID.");
  rememberMathsSession(session);
  return session;
}

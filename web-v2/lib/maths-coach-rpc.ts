"use client";

import { mathsLocalSafe, mathsRpc, rememberMathsSession, type MathsSession } from "@/lib/maths-rpc";
import { supabaseBrowser } from "@/lib/supabase";

type RpcArgs = Record<string, unknown>;

async function rawRpc<T>(name: string, args?: RpcArgs): Promise<T> {
  const { data, error } = await supabaseBrowser().rpc(name, args ?? {});
  if (error) throw error;
  return data as T;
}

const coachCriticalWrites = new Set([
  "maths_submit_answer",
  "maths_finish_session",
  "maths_save_session_position",
  "maths_confirm_diagnosis",
  "maths_record_confidence",
  "maths_record_selection",
  "maths_record_approach_recall",
  "maths_refill_calculation_session",
]);

export async function mathsCoachRpc<T = unknown>(name: string, args?: RpcArgs): Promise<T> {
  if (mathsLocalSafe() && /^maths_start_(daily|repair|mixed|sprint|calculation)$/.test(name)) {
    const out = await rawRpc<T>("maths_get_local_safe_start_v45", { p_start_rpc: name, p_args: args ?? {} });
    const session = out as MathsSession;
    if (session?.sessionId) rememberMathsSession(session);
    return out;
  }
  if (!mathsLocalSafe() && coachCriticalWrites.has(name)) return rawRpc<T>(name, args);
  return mathsRpc<T>(name, args);
}

export async function startMathsCoachSession(name: string, args?: RpcArgs): Promise<MathsSession> {
  const session = await mathsCoachRpc<MathsSession>(name, args);
  if (!session?.ok) throw new Error(session?.message || "No eligible Maths questions found.");
  if (!session.sessionId) throw new Error("Maths session did not return an ID.");
  rememberMathsSession(session);
  return session;
}

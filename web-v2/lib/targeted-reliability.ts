"use client";

import { flushPendingAnswers, pendingAnswerSaves, rpc, supabaseBrowser } from "@/lib/supabase";

const OUTBOX_KEY = "ep:v2:answer-outbox:v1";
type RpcArgs = Record<string, unknown>;

type PendingRow = {
  questionId?: string;
  args?: { p_question_id?: unknown; p_hindu_id?: unknown };
};

function browserReady() {
  return typeof window !== "undefined";
}

function pendingQuestionIds() {
  if (!browserReady()) return [] as string[];
  try {
    const rows = JSON.parse(window.localStorage.getItem(OUTBOX_KEY) || "[]") as PendingRow[];
    if (!Array.isArray(rows)) return [];
    return [...new Set(rows.map(row => String(
      row?.questionId ?? row?.args?.p_question_id ?? row?.args?.p_hindu_id ?? ""
    ).trim()).filter(Boolean))].slice(0, 200);
  } catch {
    return [];
  }
}

async function waitForAnswerDurability(maxMs = 1800) {
  let pending = pendingAnswerSaves();
  if (!pending || !browserReady() || navigator.onLine === false) return pending;
  flushPendingAnswers();
  const deadline = Date.now() + Math.max(0, maxMs);
  while ((pending = pendingAnswerSaves()) > 0 && Date.now() < deadline) {
    await new Promise(resolve => window.setTimeout(resolve, 75));
  }
  return pendingAnswerSaves();
}

async function directRpc<T>(name: string, args?: RpcArgs): Promise<T> {
  const { data, error } = await supabaseBrowser().rpc(name, args ?? {});
  if (error) throw error;
  return data as T;
}

export async function targetedLiveRpc<T>(name: "english_get_targeted_summary" | "english_get_targeted_mastery"): Promise<T> {
  await waitForAnswerDurability(900);
  return directRpc<T>(name);
}

export async function targetedSessionRpc<T>(name: string, args?: RpcArgs): Promise<T> {
  const pending = await waitForAnswerDurability();
  const exclude = pendingQuestionIds();

  if (name === "english_get_targeted_due_session" || name === "english_get_targeted_session") {
    // Normal path keeps the existing RPC wrapper so question keys are indexed locally.
    // If a durable write is still pending, bypass the stale selector and pass the
    // pending exact question IDs to the server-side Targeted fresh-session gateway.
    if (!pending && exclude.length === 0) return rpc<T>(name, args);

    const input = args ?? {};
    const dueOnly = name === "english_get_targeted_due_session";
    return directRpc<T>("english_start_targeted_fresh_session", {
      p_count: Number(input.p_count ?? 15),
      p_kind: dueOnly ? null : (input.p_kind ?? null),
      p_confusion_id: dueOnly ? null : (input.p_confusion_id ?? null),
      p_session_nonce: input.p_session_nonce ?? null,
      p_client_exclude: exclude,
      p_due_only: dueOnly,
    });
  }

  if (name === "english_get_targeted_question") {
    const qid = String(args?.p_question_id ?? "").trim();
    if (qid && exclude.includes(qid)) return [] as T;
    // Exact-item reads must never come from the 12-hour generic RPC cache.
    return directRpc<T>(name, args);
  }

  return directRpc<T>(name, args);
}

export function subscribeTargetedDurability(onDurable: () => void) {
  if (!browserReady()) return () => {};
  const handler = () => onDurable();
  window.addEventListener("ep:answer-durable", handler);
  return () => window.removeEventListener("ep:answer-durable", handler);
}

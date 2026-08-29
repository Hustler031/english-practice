"use client";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let client: SupabaseClient | null = null;
let reliabilityWired = false;
let outboxRunning = false;
let wakeTimer: ReturnType<typeof setTimeout> | null = null;
let refreshTimer: ReturnType<typeof setTimeout> | null = null;

const CACHE_PREFIX = "ep:v2:rpc-cache:";
const OUTBOX_KEY = "ep:v2:answer-outbox:v1";
const QUESTION_KEY_STORE = "ep:v2:question-correct-keys:v1";
const CACHE_MAX_AGE = 12 * 60 * 60 * 1000;
const BACKOFF = [1000, 2500, 5000, 15000, 30000, 60000];
const PRODUCTION_SUPABASE_HOST = "hytehindbmjdwcfptsic.supabase.co";

type RpcArgs = Record<string, unknown>;
type CacheEntry<T = unknown> = { at: number; name: string; args: RpcArgs; data: T };
type OutboxItem = { id: string; name: "english_submit_answer" | "english_submit_hindu_answer"; args: RpcArgs; tries: number; nextAt: number; queuedAt: number };
type FreshDetail<T = unknown> = { name: string; args: RpcArgs; data: T };

const answerLocks = new Map<string, { at: number; result: unknown }>();
let questionKeys: Record<string, string> | null = null;

function browserReady() { return typeof window !== "undefined"; }
function isLoopbackHost(hostname: string) {
  const host = String(hostname || "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
}
function isReadOnlyRpc(name: string) {
  return name === "english_dashboard_summary" || name.startsWith("english_get_") || name === "english_hindu_progress";
}
export function localProductionSafetyMode() {
  if (!browserReady() || !isLoopbackHost(window.location.hostname)) return false;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!url) return false;
  try { return new URL(url).hostname.toLowerCase() === PRODUCTION_SUPABASE_HOST; }
  catch { return false; }
}
function localSafeReadRpc(name: string) {
  return localProductionSafetyMode() && name === "english_resume_daily" ? "english_get_daily_current" : name;
}
function localMutationResult<T = unknown>(name: string, args?: RpcArgs): T {
  const input = args ?? {};
  if (name === "english_submit_answer" || name === "english_submit_hindu_answer") {
    const selected = String(input.p_selected_key ?? "").toUpperCase();
    const correctKey = correctKeyFor(name, input);
    const correct = !!correctKey && selected === correctKey;
    const attemptId = String(input.p_attempt_id ?? "").trim() || makeAttemptId(String(input.p_question_id ?? input.p_hindu_id ?? "Q"));
    return (name === "english_submit_hindu_answer"
      ? { ok: true, dry_run: true, queued: false, durable: false, correct, correctKey, correct_key: correctKey, attemptId }
      : { ok: true, dry_run: true, queued: false, durable: false, is_correct: correct, correct_key: correctKey, attempt_id: attemptId }) as T;
  }
  return { ok: true, dry_run: true, local_only: true } as T;
}
function stableArgs(args?: RpcArgs) {
  const src = args ?? {};
  return Object.keys(src).sort().reduce<Record<string, unknown>>((out, key) => { out[key] = src[key]; return out; }, {});
}
function stableArgsText(args?: RpcArgs) { return JSON.stringify(stableArgs(args)); }
function rpcCacheKey(name: string, args?: RpcArgs) { return `${CACHE_PREFIX}${name}:${stableArgsText(args)}`; }
function isCacheableRead(name: string) {
  return name === "english_dashboard_summary" || name === "english_resume_daily" || name.startsWith("english_get_") || name === "english_hindu_progress";
}
function shouldRefreshAfterMutation(name: string) {
  return name === "english_dashboard_summary" || name === "english_resume_daily" || name === "english_get_home_snapshot" || name === "english_hindu_progress" ||
    /^english_get_.*_(hub|progress|summary|intelligence|today|guidance)$/.test(name);
}
function publishFresh<T>(name: string, args: RpcArgs | undefined, data: T) {
  if (!browserReady()) return;
  try { window.dispatchEvent(new CustomEvent<FreshDetail<T>>("ep:v2-rpc-fresh", { detail: { name, args: stableArgs(args), data } })); } catch { /* best effort */ }
}
function readCache<T>(name: string, args?: RpcArgs): T | undefined {
  if (!browserReady()) return undefined;
  try {
    const raw = window.localStorage.getItem(rpcCacheKey(name, args));
    if (!raw) return undefined;
    const entry = JSON.parse(raw) as CacheEntry<T>;
    if (!entry || Date.now() - Number(entry.at || 0) > CACHE_MAX_AGE) return undefined;
    indexQuestionKeys(entry.data);
    return entry.data;
  } catch { return undefined; }
}
function writeCache<T>(name: string, args: RpcArgs | undefined, data: T) {
  if (!browserReady()) return;
  try {
    const entry: CacheEntry<T> = { at: Date.now(), name, args: stableArgs(args), data };
    window.localStorage.setItem(rpcCacheKey(name, args), JSON.stringify(entry));
  } catch { /* cache is best effort */ }
}
function readQuestionKeys() {
  if (questionKeys) return questionKeys;
  if (!browserReady()) return (questionKeys = {});
  try { questionKeys = JSON.parse(window.localStorage.getItem(QUESTION_KEY_STORE) || "{}") || {}; }
  catch { questionKeys = {}; }
  return questionKeys!;
}
function saveQuestionKeys() {
  if (!browserReady() || !questionKeys) return;
  try { window.localStorage.setItem(QUESTION_KEY_STORE, JSON.stringify(questionKeys)); } catch { /* best effort */ }
}
function indexQuestionKeys(data: unknown) {
  if (!data || typeof data !== "object") return;
  const map = readQuestionKeys();
  let changed = false;
  const visit = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) { value.forEach(visit); return; }
    const row = value as Record<string, unknown>;
    const correct = String(row.correctKey ?? row.correct_key ?? "").toUpperCase();
    if (["A", "B", "C", "D"].includes(correct)) {
      const ids = [row.id, row.question_id, row.questionId, row.centralQuestionId, row.central_question_id]
        .map(v => String(v ?? "").trim()).filter(Boolean);
      const hindu = String(row.hinduId ?? row.hindu_id ?? "").trim();
      if (hindu) ids.push(hindu, `HINDU_${hindu}`);
      ids.forEach(id => { if (map[id] !== correct) { map[id] = correct; changed = true; } });
    }
    Object.values(row).forEach(visit);
  };
  visit(data);
  if (changed) saveQuestionKeys();
}
function correctKeyFor(name: string, args: RpcArgs) {
  const map = readQuestionKeys();
  if (name === "english_submit_hindu_answer") {
    const raw = String(args.p_hindu_id ?? "").replace(/^HINDU_/i, "").trim();
    return map[`HINDU_${raw}`] || map[raw] || "";
  }
  return map[String(args.p_question_id ?? "").trim()] || "";
}
function readOutbox(): OutboxItem[] {
  if (!browserReady()) return [];
  try { const rows = JSON.parse(window.localStorage.getItem(OUTBOX_KEY) || "[]"); return Array.isArray(rows) ? rows : []; }
  catch { return []; }
}
function writeOutbox(rows: OutboxItem[]) {
  if (!browserReady()) return;
  try { window.localStorage.setItem(OUTBOX_KEY, JSON.stringify(rows)); } catch { /* best effort */ }
}
function makeAttemptId(questionId: string) { return `v2-${questionId || "Q"}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`; }
function scheduleFlush(ms = 0) {
  if (!browserReady()) return;
  if (wakeTimer) clearTimeout(wakeTimer);
  wakeTimer = setTimeout(() => { void flushAnswerOutbox(); }, Math.max(0, ms));
}
async function networkRpc<T = unknown>(name: string, args?: RpcArgs): Promise<T> {
  if (localProductionSafetyMode() && !isReadOnlyRpc(name)) return localMutationResult<T>(name, args);
  const { data, error } = await supabaseBrowser().rpc(name, args ?? {});
  if (error) throw error;
  indexQuestionKeys(data);
  return data as T;
}
async function revalidateCachedReads() {
  if (!browserReady()) return;
  const entries: CacheEntry[] = [];
  for (let i = 0; i < window.localStorage.length; i++) {
    const key = window.localStorage.key(i);
    if (!key?.startsWith(CACHE_PREFIX)) continue;
    try {
      const entry = JSON.parse(window.localStorage.getItem(key) || "null") as CacheEntry;
      if (entry?.name && shouldRefreshAfterMutation(entry.name)) entries.push(entry);
    } catch { /* ignore */ }
  }
  await Promise.allSettled(entries.slice(0, 16).map(async entry => {
    const fresh = await networkRpc(entry.name, entry.args);
    writeCache(entry.name, entry.args, fresh);
    publishFresh(entry.name, entry.args, fresh);
  }));
}
function scheduleCacheRefresh(ms = 1200) {
  if (!browserReady()) return;
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => { void revalidateCachedReads(); }, Math.max(0, ms));
}
async function flushAnswerOutbox() {
  if (!browserReady() || outboxRunning || !navigator.onLine) return;
  const rows = readOutbox();
  if (!rows.length) return;
  const now = Date.now();
  const item = rows.find(x => Number(x.nextAt || 0) <= now);
  if (!item) {
    const next = Math.min(...rows.map(x => Number(x.nextAt || now + 60000)));
    scheduleFlush(Math.min(60000, Math.max(500, next - now)));
    return;
  }
  outboxRunning = true;
  try {
    try {
      const result = await networkRpc(item.name, item.args);
      writeOutbox(readOutbox().filter(x => x.id !== item.id));
      try { window.dispatchEvent(new CustomEvent("ep:answer-durable", { detail: { id: item.id, name: item.name, result } })); } catch { /* ignore */ }
      if (!localProductionSafetyMode()) scheduleCacheRefresh();
    } catch {
      const latest = readOutbox();
      const hit = latest.find(x => x.id === item.id);
      if (hit) {
        hit.tries = Number(hit.tries || 0) + 1;
        hit.nextAt = Date.now() + BACKOFF[Math.min(BACKOFF.length - 1, hit.tries - 1)];
        writeOutbox(latest);
      }
    }
  } finally {
    outboxRunning = false;
    if (readOutbox().length) scheduleFlush(250);
  }
}
async function queueAnswer<T>(name: "english_submit_answer" | "english_submit_hindu_answer", input?: RpcArgs): Promise<T> {
  const args: RpcArgs = { ...(input ?? {}) };
  const questionId = name === "english_submit_hindu_answer"
    ? String(args.p_hindu_id ?? "").replace(/^HINDU_/i, "").trim()
    : String(args.p_question_id ?? "").trim();
  const selected = String(args.p_selected_key ?? "").toUpperCase();
  const correctKey = correctKeyFor(name, args);
  if (!questionId || !["A", "B", "C", "D"].includes(selected) || !correctKey) return networkRpc<T>(name, args);

  const lockKey = `${name}:${questionId}`;
  const recent = answerLocks.get(lockKey);
  if (recent && Date.now() - recent.at < 700) return recent.result as T;

  const attemptId = String(args.p_attempt_id ?? "").trim() || makeAttemptId(questionId);
  args.p_attempt_id = attemptId;
  const rows = readOutbox();
  if (!rows.some(x => x.id === attemptId)) rows.push({ id: attemptId, name, args, tries: 0, nextAt: 0, queuedAt: Date.now() });
  writeOutbox(rows);
  scheduleFlush(0);

  const correct = selected === correctKey;
  const result = name === "english_submit_hindu_answer"
    ? { ok: true, queued: true, durable: false, correct, correctKey, correct_key: correctKey, attemptId }
    : { ok: true, queued: true, durable: false, is_correct: correct, correct_key: correctKey, attempt_id: attemptId };
  answerLocks.set(lockKey, { at: Date.now(), result });
  setTimeout(() => answerLocks.delete(lockKey), 900);
  return result as T;
}
function wireReliability() {
  if (!browserReady() || reliabilityWired) return;
  reliabilityWired = true;
  window.addEventListener("online", () => scheduleFlush(0));
  document.addEventListener("visibilitychange", () => { if (!document.hidden) scheduleFlush(0); });
  window.setInterval(() => { if (readOutbox().length) scheduleFlush(0); }, 60000);
  scheduleFlush(0);
}

export function supabaseBrowser(): SupabaseClient {
  if (client) return client;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) throw new Error("Supabase environment variables are not configured.");
  client = createClient(url, key, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storage: typeof window === "undefined" ? undefined : window.localStorage },
  });
  wireReliability();
  return client;
}

export async function rpc<T = unknown>(name: string, args?: RpcArgs): Promise<T> {
  wireReliability();
  const effectiveName = localSafeReadRpc(name);
  if (localProductionSafetyMode() && !isReadOnlyRpc(effectiveName)) return localMutationResult<T>(name, args);
  if (name === "english_submit_answer" || name === "english_submit_hindu_answer") return queueAnswer<T>(name, args);

  if (isCacheableRead(effectiveName)) {
    const cached = readCache<T>(effectiveName, args);
    if (cached !== undefined) {
      void networkRpc<T>(effectiveName, args).then(fresh => { writeCache(effectiveName, args, fresh); publishFresh(effectiveName, args, fresh); }).catch(() => {});
      return cached;
    }
    const fresh = await networkRpc<T>(effectiveName, args);
    writeCache(effectiveName, args, fresh);
    return fresh;
  }

  const result = await networkRpc<T>(effectiveName, args);
  if (/^english_(set_|save_|add_|promote_|update_|start_|reconcile_)/.test(name)) scheduleCacheRefresh();
  return result;
}

export function subscribeRpcFresh<T>(name: string, args: RpcArgs | undefined, onFresh: (data: T) => void) {
  if (!browserReady()) return () => {};
  const wanted = stableArgsText(args);
  const handler = (event: Event) => {
    const detail = (event as CustomEvent<FreshDetail<T>>).detail;
    if (!detail || detail.name !== name || stableArgsText(detail.args) !== wanted) return;
    onFresh(detail.data);
  };
  window.addEventListener("ep:v2-rpc-fresh", handler as EventListener);
  return () => window.removeEventListener("ep:v2-rpc-fresh", handler as EventListener);
}

export async function prefetchEnglishCore() {
  if (!browserReady()) return;
  const { data } = await supabaseBrowser().auth.getSession();
  if (!data.session) return;
  const dailyRead = localSafeReadRpc("english_resume_daily");
  const reads: Array<[string, RpcArgs | undefined]> = [
    ["english_get_home_snapshot", undefined],
    [dailyRead, undefined],
    ["english_get_revision_hub", undefined],
    ["english_get_new_practice_hub", undefined],
    ["english_get_topic_hub", undefined],
    ["english_get_source_hub", undefined],
    ["english_get_demand_sets", undefined],
    ["english_get_bank_coverage_hub", undefined],
    ["english_get_saved_revision_hub", undefined],
    ["english_get_phrasal_hub", undefined],
    ["english_get_starred_hub", { p_from_day: null, p_to_day: null }],
    ["english_get_starred_guidance", { p_from_day: null, p_to_day: null }],
    ["english_get_hindu_today", undefined],
    ["english_get_hindu_quiz", undefined],
    ["english_hindu_progress", undefined],
    ["english_get_learning_progress", undefined],
  ];
  await Promise.allSettled(reads.map(async ([name, args]) => {
    const fresh = await networkRpc(name, args);
    writeCache(name, args, fresh);
    publishFresh(name, args, fresh);
  }));
}

export function pendingAnswerSaves() { return localProductionSafetyMode() ? 0 : readOutbox().length; }
export function flushPendingAnswers() { if (!localProductionSafetyMode()) scheduleFlush(0); }

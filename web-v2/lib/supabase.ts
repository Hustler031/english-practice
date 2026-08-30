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
const LOCAL_SESSION_STORE = "ep:v2:fresh-session-history:v1";
const CACHE_MAX_AGE = 12 * 60 * 60 * 1000;
const LOCAL_SESSION_MAX_AGE = 7 * 24 * 60 * 60 * 1000;
const BACKOFF = [1000, 2500, 5000, 15000, 30000, 60000];
const PRODUCTION_SUPABASE_HOST = "hytehindbmjdwcfptsic.supabase.co";
const MUTATION_REFRESH_RPCS = new Set([
  "english_dashboard_summary",
  "english_resume_daily",
  "english_get_daily_current",
  "english_get_home_snapshot",
  "english_get_revision_hub",
  "english_get_saved_revision_hub",
  "english_get_phrasal_hub",
  "english_get_starred_hub",
  "english_get_starred_guidance",
  "english_get_bank_coverage_hub",
  "english_get_new_practice_hub",
  "english_get_learning_progress",
  "english_hindu_progress",
]);

type RpcArgs = Record<string, unknown>;
type CacheEntry<T = unknown> = { at: number; name: string; args: RpcArgs; data: T };
type OutboxItem = { id: string; name: "english_submit_answer" | "english_submit_hindu_answer"; args: RpcArgs; tries: number; nextAt: number; queuedAt: number; questionId?: string };
type FreshDetail<T = unknown> = { name: string; args: RpcArgs; data: T };
type LocalSession = { lane: string; ids: string[]; at: number };
type SessionReadPolicy = { kind: "rotating"; lane: string; strict: boolean } | { kind: "live" };

const answerLocks = new Map<string, { at: number; result: unknown }>();
const freshInflight = new Map<string, Promise<unknown>>();
let questionKeys: Record<string, string> | null = null;

function browserReady() { return typeof window !== "undefined"; }
function isLoopbackHost(hostname: string) {
  const host = String(hostname || "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
}
function cleanLanePart(value: unknown, fallback = "all") {
  return String(value ?? fallback).trim().toLowerCase().replace(/[^a-z0-9_.:-]+/g, "-").slice(0, 120) || fallback;
}
function cleanLaneList(value: unknown) {
  if (!Array.isArray(value)) return cleanLanePart(value);
  const rows = [...new Set(value.map(v => cleanLanePart(v, "")).filter(Boolean))].sort();
  return rows.join("|").slice(0, 600) || "all";
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
function sessionReadPolicy(name: string, args?: RpcArgs): SessionReadPolicy | null {
  const input = args ?? {};
  const mode = cleanLanePart(input.p_mode, "all");
  switch (name) {
    case "english_get_revision_batch":
      return { kind: "rotating", lane: `revision:${mode}`, strict: false };
    case "english_get_difficult_items":
      return { kind: "rotating", lane: "difficult", strict: false };
    case "english_get_saved_revision_batch":
      return { kind: "rotating", lane: `saved:${mode}`, strict: mode === "new" };
    case "english_get_new_practice_batch":
      return { kind: "rotating", lane: `new:${cleanLanePart(input.p_category)}:${mode}:${cleanLanePart(input.p_source)}`, strict: mode === "new" || mode === "newwords" };
    case "english_get_topic_batch":
      return { kind: "rotating", lane: `topic:${cleanLanePart(input.p_category)}:${mode}`, strict: mode === "new" };
    case "english_get_source_batch":
      return { kind: "rotating", lane: `source:${cleanLanePart(input.p_source_key)}:${mode}`, strict: mode === "new" };
    case "english_get_source_group_batch":
      return { kind: "rotating", lane: `source-group:${cleanLaneList(input.p_source_keys)}:${mode}`, strict: mode === "new" };
    case "english_get_starred_batch":
      return { kind: "rotating", lane: `starred:${mode}:${cleanLanePart(input.p_from_day, "any")}:${cleanLanePart(input.p_to_day, "any")}`, strict: false };
    case "english_get_phrasal_batch":
      return { kind: "rotating", lane: `phrasal:${mode}`, strict: false };
    case "english_get_today_extra_batch":
      return { kind: "rotating", lane: "extra", strict: false };
    case "english_get_bank_coverage_batch":
      return { kind: "rotating", lane: `bank-unseen:${cleanLanePart(input.p_category)}`, strict: true };
    case "english_get_demand_batch":
      return mode === "all" ? null : { kind: "rotating", lane: `demand:${cleanLanePart(input.p_set_id)}:${mode}`, strict: false };
    case "english_get_bank_coverage_seen_batch":
    case "english_get_bank_coverage_review_batch":
      return { kind: "live" };
    default:
      return null;
  }
}
function isCacheableRead(name: string, args?: RpcArgs) {
  if (sessionReadPolicy(name, args)) return false;
  return name === "english_dashboard_summary" || name === "english_resume_daily" || name.startsWith("english_get_") || name === "english_hindu_progress";
}
function shouldRefreshAfterMutation(name: string) { return MUTATION_REFRESH_RPCS.has(name); }
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
  if (!browserReady()) return false;
  try { window.localStorage.setItem(OUTBOX_KEY, JSON.stringify(rows)); return true; }
  catch { return false; }
}
function readLocalSessions(): LocalSession[] {
  if (!browserReady()) return [];
  try {
    const parsed = JSON.parse(window.localStorage.getItem(LOCAL_SESSION_STORE) || "[]");
    if (!Array.isArray(parsed)) return [];
    const cutoff = Date.now() - LOCAL_SESSION_MAX_AGE;
    return parsed.filter((row: LocalSession) => row && Number(row.at || 0) >= cutoff && Array.isArray(row.ids)).slice(0, 40);
  } catch { return []; }
}
function writeLocalSessions(rows: LocalSession[]) {
  if (!browserReady()) return;
  try { window.localStorage.setItem(LOCAL_SESSION_STORE, JSON.stringify(rows.slice(0, 40))); } catch { /* best effort fallback only */ }
}
function questionIdsFromBatch(data: unknown) {
  if (!Array.isArray(data)) return [];
  const ids = data.map(row => {
    if (!row || typeof row !== "object") return "";
    const item = row as Record<string, unknown>;
    return String(item.id ?? item.question_id ?? item.questionId ?? "").trim();
  }).filter(Boolean);
  return [...new Set(ids)];
}
function recordLocalSession(lane: string, data: unknown) {
  const ids = questionIdsFromBatch(data);
  if (!ids.length) return;
  const rows = readLocalSessions();
  rows.unshift({ lane, ids, at: Date.now() });
  writeLocalSessions(rows);
}
function pendingQuestionIds() {
  return readOutbox().map(row => String(row.questionId ?? row.args?.p_question_id ?? row.args?.p_hindu_id ?? "").trim()).filter(Boolean);
}
function localExcludeIds(lane: string, pending: number, strict: boolean) {
  const rows = readLocalSessions();
  const chosen: LocalSession[] = [];
  const global = rows[0];
  const sameLane = rows.find(row => row.lane === lane);
  if (global) chosen.push(global);
  if (sameLane && sameLane !== global) chosen.push(sameLane);
  if (pending > 0 || strict || localProductionSafetyMode()) {
    const recentCutoff = Date.now() - (strict || localProductionSafetyMode() ? LOCAL_SESSION_MAX_AGE : 2 * 60 * 60 * 1000);
    rows.filter(row => row.at >= recentCutoff).forEach(row => chosen.push(row));
  }
  const ids = chosen.flatMap(row => row.ids);
  if (pending > 0) ids.push(...pendingQuestionIds());
  return [...new Set(ids)].slice(0, 500);
}
function makeAttemptId(questionId: string) { return `v2-${questionId || "Q"}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`; }
function scheduleFlush(ms = 0) {
  if (!browserReady()) return;
  if (wakeTimer) clearTimeout(wakeTimer);
  wakeTimer = setTimeout(() => { wakeTimer = null; void flushAnswerOutbox(); }, Math.max(0, ms));
}
async function networkRpc<T = unknown>(name: string, args?: RpcArgs): Promise<T> {
  const localSafeGateway = name === "english_start_fresh_session";
  if (localProductionSafetyMode() && !isReadOnlyRpc(name) && !localSafeGateway) return localMutationResult<T>(name, args);
  const { data, error } = await supabaseBrowser().rpc(name, args ?? {});
  if (error) throw error;
  indexQuestionKeys(data);
  return data as T;
}
async function revalidateCachedReads() {
  if (!browserReady()) return;
  if (readOutbox().length) { scheduleCacheRefresh(2500); return; }
  const entries: CacheEntry[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < window.localStorage.length; i++) {
    const key = window.localStorage.key(i);
    if (!key?.startsWith(CACHE_PREFIX)) continue;
    try {
      const entry = JSON.parse(window.localStorage.getItem(key) || "null") as CacheEntry;
      const fingerprint = entry?.name ? `${entry.name}:${stableArgsText(entry.args)}` : "";
      if (entry?.name && isCacheableRead(entry.name, entry.args) && shouldRefreshAfterMutation(entry.name) && !seen.has(fingerprint)) {
        seen.add(fingerprint);entries.push(entry);
      }
    } catch { /* ignore */ }
  }
  const priority = (name: string) => ["english_get_home_snapshot", "english_dashboard_summary", "english_get_revision_hub", "english_get_saved_revision_hub", "english_get_phrasal_hub", "english_get_starred_hub", "english_get_bank_coverage_hub", "english_get_learning_progress"].indexOf(name);
  entries.sort((a, b) => {
    const pa = priority(a.name), pb = priority(b.name);
    return (pa < 0 ? 99 : pa) - (pb < 0 ? 99 : pb);
  });
  const chosen = entries.slice(0, 8);
  for (let i = 0; i < chosen.length; i += 2) {
    await Promise.allSettled(chosen.slice(i, i + 2).map(async entry => {
      const fresh = await networkRpc(entry.name, entry.args);
      writeCache(entry.name, entry.args, fresh);
      publishFresh(entry.name, entry.args, fresh);
    }));
  }
}
function scheduleCacheRefresh(ms = 1800) {
  if (!browserReady()) return;
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => { refreshTimer = null; void revalidateCachedReads(); }, Math.max(0, ms));
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
      const remaining = readOutbox().filter(x => x.id !== item.id);
      writeOutbox(remaining);
      try { window.dispatchEvent(new CustomEvent("ep:answer-durable", { detail: { id: item.id, name: item.name, result } })); } catch { /* ignore */ }
      if (!localProductionSafetyMode() && !remaining.length) scheduleCacheRefresh(4000);
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
  const clientQuestionId = String(args.p_client_question_id ?? "").trim();
  delete args.p_client_question_id;
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
  if (!rows.some(x => x.id === attemptId)) rows.push({ id: attemptId, name, args, tries: 0, nextAt: 0, queuedAt: Date.now(), questionId: clientQuestionId || (name === "english_submit_answer" ? questionId : "") });
  if (!writeOutbox(rows)) throw new Error("Local answer storage is unavailable. Please free browser storage and retry.");
  scheduleFlush(0);

  const correct = selected === correctKey;
  const result = name === "english_submit_hindu_answer"
    ? { ok: true, queued: true, durable: false, correct, correctKey, correct_key: correctKey, attemptId }
    : { ok: true, queued: true, durable: false, is_correct: correct, correct_key: correctKey, attempt_id: attemptId };
  answerLocks.set(lockKey, { at: Date.now(), result });
  setTimeout(() => answerLocks.delete(lockKey), 900);
  return result as T;
}
async function prepareFreshSession(maxMs = 1400) {
  if (localProductionSafetyMode()) return 0;
  let pending = readOutbox().length;
  if (!pending || !browserReady() || navigator.onLine === false) return pending;
  scheduleFlush(0);
  const deadline = Date.now() + Math.max(0, maxMs);
  while ((pending = readOutbox().length) > 0 && Date.now() < deadline) {
    await new Promise(resolve => window.setTimeout(resolve, 75));
  }
  return readOutbox().length;
}
async function runSessionRead<T>(name: string, args: RpcArgs | undefined, policy: SessionReadPolicy): Promise<T> {
  if (policy.kind === "live") {
    await prepareFreshSession();
    return networkRpc<T>(name, args);
  }
  const fingerprint = `${name}:${stableArgsText(args)}`;
  const existing = freshInflight.get(fingerprint);
  if (existing) return existing as Promise<T>;
  const task = (async () => {
    const pending = await prepareFreshSession();
    const exclude = localExcludeIds(policy.lane, pending, policy.strict);
    const fresh = await networkRpc<T>("english_start_fresh_session", {
      p_rpc: name,
      p_args: stableArgs(args),
      p_client_exclude: exclude,
    });
    recordLocalSession(policy.lane, fresh);
    return fresh;
  })();
  freshInflight.set(fingerprint, task);
  try { return await task; }
  finally {
    window.setTimeout(() => { if (freshInflight.get(fingerprint) === task) freshInflight.delete(fingerprint); }, 300);
  }
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
  const localSafe = localProductionSafetyMode();
  client = createClient(url, key, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storage: typeof window === "undefined" ? undefined : window.localStorage },
    global: localSafe ? { headers: { "x-english-local-safe": "1" } } : undefined,
  });
  wireReliability();
  return client;
}

export async function rpc<T = unknown>(name: string, args?: RpcArgs): Promise<T> {
  wireReliability();
  const effectiveName = localSafeReadRpc(name);
  if (localProductionSafetyMode() && !isReadOnlyRpc(effectiveName)) return localMutationResult<T>(name, args);
  if (name === "english_submit_answer" || name === "english_submit_hindu_answer") return queueAnswer<T>(name, args);

  const policy = sessionReadPolicy(effectiveName, args);
  if (policy) return runSessionRead<T>(effectiveName, args, policy);

  if (isCacheableRead(effectiveName, args)) {
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

export function learnerErrorMessage(error: unknown, fallback = "Something went wrong. Please try again.") {
  const message = String((error as { message?: unknown } | null)?.message ?? error ?? "").trim();
  if (!message) return fallback;
  if (/authentication required|jwt|not authenticated|session.*expired/i.test(message)) return "Your session needs to be refreshed. Please sign in again.";
  if (/canceling statement|statement timeout|postgres|postgrest|sqlstate|deadlock|connection reset|failed to fetch|network request|database error/i.test(message)) return fallback;
  return message;
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

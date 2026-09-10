"use client";

export type PausedQuizAnswer = { selectedCanonicalKey:string; correct:boolean; correctCanonicalKey:string };
export type PausedQuizSession = {
  title: string;
  backHref: string;
  module: string;
  index: number;
  questions: unknown[];
  answers?: Record<string, PausedQuizAnswer>;
  revealedRecall?: string[];
  savedAt: number;
  version?: number;
  ownerId?: string;
};

const key = "english-v2:paused-quiz";
const SESSION_VERSION = 2;
const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const IST_TIME_ZONE = "Asia/Kolkata";

function currentOwnerId() {
  try {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    if (!url) return "";
    const projectRef = new URL(url).hostname.split(".")[0];
    if (!projectRef) return "";
    const raw = window.localStorage.getItem(`sb-${projectRef}-auth-token`);
    if (!raw) return "";
    const auth = JSON.parse(raw);
    const direct = String(auth?.user?.id ?? "").trim();
    if (direct) return direct;
    const token = String(auth?.access_token ?? "");
    const payload = token.split(".")[1];
    if (!payload) return "";
    const base64 = payload.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(payload.length / 4) * 4, "=");
    return String(JSON.parse(window.atob(base64))?.sub ?? "").trim();
  } catch { return ""; }
}

function istDateKey(timestamp:number) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: IST_TIME_ZONE,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(new Date(timestamp));
    const part = (type:string) => parts.find(x => x.type === type)?.value || "";
    const year = part("year"), month = part("month"), day = part("day");
    return year && month && day ? `${year}-${month}-${day}` : "";
  } catch { return ""; }
}

function isCurrentDayScopedSession(value:PausedQuizSession) {
  // Grammar Today is a date-scoped fixed batch. It must never resume yesterday's
  // questions after the Asia/Kolkata day rolls over, even though generic paused
  // quizzes are allowed to live for up to 24 hours.
  if (String(value.module || "").toLowerCase() !== "grammardaily") return true;
  const savedDay = istDateKey(Number(value.savedAt || 0));
  const today = istDateKey(Date.now());
  return !!savedDay && savedDay === today;
}

function validSession(value: PausedQuizSession, ownerId: string) {
  const age = Date.now() - Number(value.savedAt || 0);
  return value.version === SESSION_VERSION
    && !!ownerId
    && value.ownerId === ownerId
    && typeof value.title === "string"
    && typeof value.backHref === "string"
    && value.backHref.startsWith("/english")
    && typeof value.module === "string"
    && Array.isArray(value.questions)
    && value.questions.length > 0
    && Number.isInteger(value.index)
    && value.index >= 0
    && value.index < value.questions.length
    && Number.isFinite(age)
    && age >= -MAX_CLOCK_SKEW_MS
    && age <= SESSION_TTL_MS
    && isCurrentDayScopedSession(value);
}

export function readPausedQuiz(): PausedQuizSession | null {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return null;
    const value = JSON.parse(raw) as PausedQuizSession;
    if (!validSession(value, currentOwnerId())) {
      clearPausedQuiz();
      return null;
    }
    return value;
  } catch {
    clearPausedQuiz();
    return null;
  }
}

export function savePausedQuiz(value: PausedQuizSession) {
  try {
    const ownerId = currentOwnerId();
    if (!ownerId || !Array.isArray(value.questions) || !value.questions.length) {
      clearPausedQuiz();
      return;
    }
    window.localStorage.setItem(key, JSON.stringify({ ...value, version: SESSION_VERSION, ownerId, savedAt: Date.now() }));
  } catch {}
}

export function clearPausedQuiz() {
  try { window.localStorage.removeItem(key); } catch {}
}

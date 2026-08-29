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
    && age <= SESSION_TTL_MS;
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

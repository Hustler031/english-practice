"use client";

export type PausedQuizAnswer = { selected:string; correct:boolean; correctCanonicalKey:string };
export type PausedQuizSession = {
  title: string;
  backHref: string;
  module: string;
  index: number;
  questions: unknown[];
  answers?: Record<string, PausedQuizAnswer>;
  revealedRecall?: string[];
  savedAt: number;
};

const key = "english-v2:paused-quiz";

export function readPausedQuiz(): PausedQuizSession | null {
  try {
    const raw = window.localStorage.getItem(key);
    const value = raw ? JSON.parse(raw) : null;
    return value && Array.isArray(value.questions) && value.questions.length ? value : null;
  } catch { return null; }
}

export function savePausedQuiz(value: PausedQuizSession) {
  try { window.localStorage.setItem(key, JSON.stringify(value)); } catch {}
}

export function clearPausedQuiz() {
  try { window.localStorage.removeItem(key); } catch {}
}

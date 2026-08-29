"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { readPausedQuiz, type PausedQuizSession } from "@/lib/quiz-session";
import { useAuthGuard } from "@/lib/use-auth";

export default function ResumeQuizPage() {
  const ready = useAuthGuard();
  const [session, setSession] = useState<PausedQuizSession | null | undefined>(undefined);
  useEffect(() => { if (ready) setSession(readPausedQuiz()); }, [ready]);
  if (!ready || session === undefined) return <main className="center"><div className="muted">Checking paused practice…</div></main>;
  if (!session) return <main className="shell"><div className="empty-state"><h2>No paused practice</h2><p className="muted">Start any focused practice set and it will be ready to resume here.</p><Link className="btn primary" href="/english">English Home</Link></div></main>;
  return <QuizRunner title={session.title} backHref={session.backHref} module={session.module} load={async () => session.questions as never[]} resumeSession={session}/>;
}

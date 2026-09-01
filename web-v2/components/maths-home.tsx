"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { MathsLoading } from "@/components/maths-frame";
import { useAuthGuard } from "@/lib/use-auth";
import {
  mathsRpc,
  rememberMathsSession,
  subscribeMathsFresh,
  type MathsMetric,
  type MathsSession,
} from "@/lib/maths-rpc";

type HomeSnapshot = {
  ok: boolean;
  studyDay: number;
  config: {
    dailyTarget: number;
    newQuota: number;
    difficultRotationDays: number;
    practiceMoreSize: number;
    timezone: string;
  };
  daily: {
    target: number;
    done: number;
    remaining: number;
    completed: boolean;
    sessionId: string;
  };
  resume?: {
    sessionId: string;
    title: string;
    mode: string;
    currentIndex: number;
    target: number;
    completed?: boolean;
  } | null;
  overall: MathsMetric;
  counts: {
    new: number;
    starred: number;
    concepts: number;
    mocks: number;
    formulas: number;
    calculation: number;
  };
};

function pretty(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase());
}

function QuickCard({ icon, title, sub, href }: { icon: string; title: string; sub: string; href: string }) {
  return <Link className="m-quick-card" href={href}>
    <span className="m-quick-icon">{icon}</span>
    <span className="m-quick-copy"><b>{title}</b><small>{sub}</small></span>
    <i>›</i>
  </Link>;
}

export default function MathsHome() {
  const ready = useAuthGuard();
  const router = useRouter();
  const [data, setData] = useState<HomeSnapshot | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!ready) return;
    let alive = true;
    let request = 0;
    const accept = (next: HomeSnapshot) => {
      if (!alive) return;
      setData(next);
      setError("");
    };
    const load = () => {
      const current = ++request;
      void mathsRpc<HomeSnapshot>("maths_get_home_snapshot")
        .then(next => { if (alive && current === request) accept(next); })
        .catch((e: unknown) => { if (alive && current === request) setError(e instanceof Error ? e.message : String(e)); });
    };
    const unsubscribe = subscribeMathsFresh<HomeSnapshot>("maths_get_home_snapshot", undefined, accept);
    const ownerChanged = () => { if (alive) { setData(null); setError(""); load(); } };
    window.addEventListener("maths:v2-owner-change", ownerChanged);
    load();
    return () => {
      alive = false;
      unsubscribe();
      window.removeEventListener("maths:v2-owner-change", ownerChanged);
    };
  }, [ready]);

  const start = useCallback(async (name: string, args?: Record<string, unknown>) => {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      const session = await mathsRpc<MathsSession>(name, args);
      if (!session?.ok) {
        if (session?.dailyComplete && session.sessionId) {
          rememberMathsSession(session);
          router.push(`/maths/session?id=${encodeURIComponent(session.sessionId)}`);
          return;
        }
        throw new Error(session?.message || "No eligible Maths questions found.");
      }
      if (!session.sessionId) throw new Error("Maths session did not return an ID.");
      rememberMathsSession(session);
      router.push(`/maths/session?id=${encodeURIComponent(session.sessionId)}`);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [busy, router]);

  if (!ready) return <MathsLoading text="Checking Maths session…" />;
  if (!data && !error) return <MathsLoading text="Loading Maths home…" />;
  if (!data) return <div className="maths-error">{error}</div>;

  const daily = data.daily;
  const percent = daily.target ? Math.min(100, Math.round((daily.done * 100) / daily.target)) : 0;
  const pendingParts = (data.resume?.title ?? "Practice").split("·").map(x => x.trim()).filter(Boolean);
  const pendingTitle = pendingParts[0] || "Practice";
  const pendingSub = pendingParts.slice(1).join(" · ") || pretty(data.resume?.mode ?? "Practice");
  const daysLeft = Math.max(0, 30 - Math.max(1, data.studyDay) + 1);

  return <div className="m-home">
    {error && <div className="maths-error">{error}</div>}

    <section className={`m-hero ${daily.completed ? "complete" : ""}`}>
      <h1>{daily.completed ? `Day ${data.studyDay} · Complete` : `Day ${data.studyDay} · Mixed Revision`}</h1>
      <p className="m-hero-desc">{daily.completed ? "Today’s mixed Maths revision is complete." : "Mixed adaptive revision · whole question bank, Calculation excluded."}</p>
      <div className="m-goal"><span>Today’s Goal</span><b>{daily.done} / {daily.target}</b></div>
      <div className="m-daily-track"><i style={{ width: `${percent}%` }} /></div>
      <div className="m-hero-note">{data.config.newQuota} New guaranteed · Difficult every {data.config.difficultRotationDays} days · Weak, Hard and due revision</div>
      {daily.completed
        ? <button className="m-hero-cta" type="button" disabled={busy} onClick={() => void start("maths_start_practice_more", { p_count: data.config.practiceMoreSize })}>{busy ? "Starting…" : "Practice More"}</button>
        : <button className="m-hero-cta" type="button" disabled={busy} onClick={() => void start("maths_start_daily")}>{busy ? "Starting…" : daily.done > 0 || daily.sessionId ? `Continue Day ${data.studyDay} · ${daily.remaining} left` : `Start Day ${data.studyDay} · ${daily.remaining} left`}</button>}
    </section>

    {data.resume && !data.resume.completed && <Link className="m-pending" href={`/maths/session?id=${encodeURIComponent(data.resume.sessionId)}`}>
      <span><b>Pending · {pendingTitle}</b><small>{pendingSub}</small></span><i>›</i>
    </Link>}

    <section className="mex-home-row" aria-label="Maths Exam Preparation">
      <Link href="/maths/exam">
        <span><b>EXAM PREPARATION</b><small>{daysLeft} Days Left · 25Q Sprint · 45+ Goal</small></span>
        <i>›</i>
      </Link>
    </section>

    <h2 className="m-section-title">Quick Start</h2>
    <div className="m-quick-list">
      <QuickCard icon="✦" title="New Practice" sub={`${data.counts.new} unseen · recent additions by chapter`} href="/maths/new" />
      <QuickCard icon="☆" title="Starred Revision" sub={`${data.counts.starred} starred · ${data.overall.difficult} difficult`} href="/maths/starred" />
      <QuickCard icon="◇" title="Concepts" sub={`${data.counts.concepts} saved questions · concept review`} href="/maths/concepts" />
    </div>
  </div>;
}

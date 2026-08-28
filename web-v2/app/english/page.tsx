"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import AddWordSheet from "@/components/add-word-sheet";
import { EnglishLoading } from "@/components/english-frame";

type Summary = { total_active:number; attempted:number; mastered:number; starred:number; difficult:number; daily_total:number; daily_completed:number };
const quick = [["📰", "The Hindu – Today", "Today's vocabulary", "/english/hindu", "hindu"], ["🔖", "My Saved Words", "Words, doubts and usage points", "/english/saved", "saved"], ["↗", "Phrasal Verb", "Smart revision + Today's batch", "/english/phrasal", "phrasal"], ["★", "Starred Revision", "Questions you marked for focus", "/english/starred", "starred"], ["◫", "Bank Coverage", "Explore new and existing content", "/english/new", "bank"]] as const;

export default function EnglishHome() {
  const ready = useAuthGuard(); const [data, setData] = useState<Summary | null>(null); const [error, setError] = useState("");
  useEffect(() => { if (ready) rpc<Summary>("english_dashboard_summary").then(setData).catch((e: any) => setError(e.message)); }, [ready]);
  if (!ready) return <EnglishLoading text="Checking session…" />;
  const total = data?.daily_total ?? 0, completed = data?.daily_completed ?? 0, percent = total ? Math.min(100, Math.round((completed / total) * 100)) : 0;
  return <>{error && <div className="error-box">{error}</div>}<section className="daily-hero"><div className="daily-hero-top"><div><span className="eyebrow">Today · English Practice</span><h1>Today&apos;s English Practice</h1></div><span className="today-badge">{data ? `${completed} done` : "Loading"}</span></div><p>Finish your daily revision first, then use focused practice.</p><div className="goal-line"><span>Today&apos;s Goal</span><strong>{data ? `${completed} / ${total}` : "—"}</strong></div><div className="progress-track"><i style={{ width: `${percent}%` }} /></div><div className="daily-status">{data ? (completed >= total && total ? "Daily target complete." : `${Math.max(0, total - completed)} questions remain.`) : "Preparing your daily plan…"}</div><Link className="btn daily-button" href="/english/daily">{completed ? "Continue Daily Practice" : "Start Daily Practice"}</Link></section><section className="section-block"><div className="section-title-line"><h2>Quick Start</h2><AddWordSheet label="＋ Add Word" /></div><div className="study-list">{quick.map(([icon, title, sub, href, accent]) => <Link className={`study-row accent-${accent}`} href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">Open</span><i>›</i></Link>)}</div></section></>;
}

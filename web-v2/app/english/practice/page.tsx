"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Progress = { bankExposed:number; firstAttemptAccuracy:number; retentionAccuracy:number; weakConcepts:number };
const explore = [["✨", "New Practice", "Recently added content by category", "/english/new"], ["◫", "Bank Coverage", "Optional unseen core-bank exposure", "/english/bank"]];
const focused = [["⌘", "Topic Practice", "Choose a focused English category", "/english/topics"], ["📚", "Source / PDF Practice", "Notes, sources and PDFs stay separate", "/english/sources"], ["🎯", "Demanded Practice", "Saved custom batches created for exactly what you want to practise", "/english/demand"]];

export default function PracticeHome() {
  const ready = useAuthGuard(); const [progress, setProgress] = useState<Progress | null>(null);
  useEffect(() => { if (ready) rpc<Progress>("english_get_learning_progress").then(setProgress).catch(() => {}); }, [ready]);
  if (!ready) return <EnglishLoading text="Checking session…" />;
  return <><section className="page-intro"><h1>Practice</h1><p>Choose a focused practice area.</p></section><div className="compact-metrics"><div><b>{progress ? `${progress.bankExposed.toFixed(1)}%` : "—"}</b><span>Coverage</span></div><div><b>{progress ? `${progress.firstAttemptAccuracy.toFixed(1)}%` : "—"}</b><span>First Attempt</span></div><div><b>{progress ? `${progress.retentionAccuracy.toFixed(1)}%` : "—"}</b><span>Retention</span></div><div><b>{progress?.weakConcepts ?? "—"}</b><span>Weak</span></div></div><RouteSection label="Explore" rows={explore} /><RouteSection label="Focused Practice" rows={focused} /></>;
}

function RouteSection({ label, rows }: { label:string; rows:string[][] }) { return <section className="section-block"><h2 className="section-cap">{label}</h2><div className="study-list">{rows.map(([icon, title, sub, href]) => <Link className="study-row" href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><i>›</i></Link>)}</div></section>; }

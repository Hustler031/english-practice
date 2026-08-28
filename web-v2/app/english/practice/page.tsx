"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary = { total_active:number; attempted:number; starred:number; difficult:number };
const explore = [["✨", "New Practice", "Recently added learning content", "/english/new"], ["◫", "Bank Coverage", "Explore active content by category", "/english/new"]];
const focused = [["⌘", "Topic Practice", "Choose a focused English category", "/english/topics"], ["📚", "Source / PDF Practice", "Notes, sources and PDFs stay separate", "/english/sources"], ["🎯", "Demand / Demanded Practice", "Custom study batches for exactly what you need", "/english/demand"]];

export default function PracticeHome() {
  const ready = useAuthGuard(); const [summary, setSummary] = useState<Summary | null>(null);
  useEffect(() => { if (ready) rpc<Summary>("english_dashboard_summary").then(setSummary).catch(() => {}); }, [ready]);
  if (!ready) return <EnglishLoading text="Checking session…" />;
  const coverage = summary?.total_active ? Math.round((summary.attempted / summary.total_active) * 100) : 0;
  return <><section className="page-intro"><h1>Practice</h1><p>Choose a focused practice area.</p></section><div className="compact-metrics"><div><b>{summary ? `${coverage}%` : "—"}</b><span>Coverage</span></div><div><b>{summary?.attempted ?? "—"}</b><span>Attempted</span></div><div><b>{summary?.starred ?? "—"}</b><span>Starred</span></div><div><b>{summary?.difficult ?? "—"}</b><span>Difficult</span></div></div><RouteSection label="Explore" rows={explore} /><RouteSection label="Focused Practice" rows={focused} /></>;
}

function RouteSection({ label, rows }: { label:string; rows:string[][] }) { return <section className="section-block"><h2 className="section-cap">{label}</h2><div className="study-list">{rows.map(([icon, title, sub, href]) => <Link className="study-row" href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><i>›</i></Link>)}</div></section>; }

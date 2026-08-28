"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary = { starred:number; difficult:number; mastered:number; attempted:number; total_active:number };
const actions = [["★", "Starred", "/english/starred"], ["!", "Difficult", "/english/difficult"], ["🔖", "My Saved", "/english/saved"], ["↗", "Phrasal", "/english/phrasal"], ["⌂", "Daily", "/english/daily"], ["◫", "Practice All", "/english/new"]];

export default function RevisionHome() {
  const ready = useAuthGuard(); const [data, setData] = useState<Summary | null>(null);
  useEffect(() => { if (ready) rpc<Summary>("english_dashboard_summary").then(setData).catch(() => {}); }, [ready]);
  if (!ready) return <EnglishLoading text="Checking session…" />;
  return <><section className="page-intro"><h1>Revision</h1><p>Review only what needs attention.</p></section><section className="revision-panel"><div className="revision-panel-head"><div><h2>Smart Revision</h2><p>Use your history to choose the next useful revision lane.</p></div></div><div className="revision-metrics"><span><b>{data?.attempted ?? "—"}</b>Saved progress</span><span><b>{data?.starred ?? "—"}</b>Starred</span><span><b>{data?.difficult ?? "—"}</b>Difficult</span><span><b>{data?.mastered ?? "—"}</b>Mastered</span></div><div className="action-matrix">{actions.map(([icon, label, href]) => <Link href={href} key={href}><b>{icon}</b><span>{label}</span></Link>)}</div></section><section className="section-block"><h2 className="section-cap">Phrasal Verb</h2><div className="study-list"><Link className="study-row accent-phrasal" href="/english/phrasal"><span className="row-icon">↗</span><span className="row-copy"><b>Smart Revision</b><small>Concept-level revision, Today&apos;s batch and history</small></span><i>›</i></Link></div></section></>;
}

"use client";

import { useEffect, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary = { total_active:number; attempted:number; mastered:number; starred:number; difficult:number };
type Group = { id:string; name:string; total:number; weak:number; started:number; newCount:number };
export default function ProgressHome() {
  const ready = useAuthGuard(); const [summary, setSummary] = useState<Summary | null>(null); const [groups, setGroups] = useState<Group[]>([]);
  useEffect(() => { if (ready) Promise.all([rpc<Summary>("english_dashboard_summary"), rpc<Group[]>("english_get_topic_hub")]).then(([s, g]) => { setSummary(s); setGroups(g); }).catch(() => {}); }, [ready]);
  if (!ready) return <EnglishLoading text="Checking session…" />;
  const coverage = summary?.total_active ? Math.round(summary.attempted * 100 / summary.total_active) : 0;
  return <><section className="page-intro"><h1>Progress</h1><p>Your English coverage and category status.</p></section><div className="progress-summary"><Metric label="Bank Exposed" value={summary ? `${summary.attempted} / ${summary.total_active}` : "—"} /><Metric label="Coverage" value={summary ? `${coverage}%` : "—"} /><Metric label="Weak" value={summary?.difficult ?? "—"} /><Metric label="Mastered" value={summary?.mastered ?? "—"} /></div><section className="section-block"><h2 className="section-cap">Category Progress</h2><div className="category-list">{groups.length ? groups.map((group) => { const percent = group.total ? Math.min(100, Math.round(group.started * 100 / group.total)) : 0; return <article className="category-row" key={group.id}><div className="category-title"><b>{group.name}</b><span>{group.started} / {group.total}</span></div><div className="progress-track"><i style={{ width: `${percent}%` }} /></div><small>Coverage {percent}% · Weak {group.weak} · New {group.newCount}</small></article>; }) : <div className="empty-copy">Loading categories…</div>}</div></section></>;
}
function Metric({ label, value }: { label:string; value:string | number }) { return <div><span>{label}</span><b>{value}</b></div>; }

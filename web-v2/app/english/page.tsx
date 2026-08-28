"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { rpc, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary = {ok:boolean; total_active:number; attempted:number; mastered:number; starred:number; difficult:number; daily_total:number; daily_completed:number};

export default function EnglishHome() {
  const ready = useAuthGuard(); const router = useRouter();
  const [data,setData]=useState<Summary|null>(null); const [error,setError]=useState("");
  useEffect(()=>{if(!ready)return;rpc<Summary>("english_dashboard_summary").then(setData).catch(e=>setError(e.message));},[ready]);
  async function signOut(){await supabaseBrowser().auth.signOut();router.replace("/login");}
  if(!ready)return <main className="center"><div className="muted">Checking session…</div></main>;
  return <main className="shell"><div className="topbar"><div><div className="brand">English Mastery V2</div><div className="muted">Supabase-backed revision runtime</div></div><div className="row"><Link className="btn ghost" href="/">All modules</Link><button className="btn" onClick={signOut}>Sign out</button></div></div>{error&&<div className="card error">{error}</div>}<div className="grid"><Link href="/english/daily" className="card"><h3>Daily</h3><div className="metric">{data?`${data.daily_completed}/${data.daily_total}`:"—"}</div><div className="muted">Persisted, due-clock reconciled</div></Link><Link href="/english/starred" className="card"><h3>Starred</h3><div className="metric">{data?.starred??"—"}</div><div className="muted">Latest event state</div></Link><Link href="/english/difficult" className="card"><h3>Difficult</h3><div className="metric">{data?.difficult??"—"}</div><div className="muted">Independent difficult state</div></Link><Link href="/english/saved" className="card"><h3>My Saved</h3><div className="metric">→</div><div className="muted">Auto / V / SM / OWS / PV / I/P</div></Link><Link href="/english/hindu" className="card"><h3>The Hindu</h3><div className="metric">→</div><div className="muted">Repeatable rounds + Add to Vocab</div></Link><Link href="/english/phrasal" className="card"><h3>Phrasal Mastery</h3><div className="metric">→</div><div className="muted">Concept-first recognition / recall / confusion revision</div></Link><Link href="/english/new" className="card"><h3>New Practice</h3><div className="metric">→</div><div className="muted">Recent + saved content</div></Link><Link href="/english/topics" className="card"><h3>Topic Practice</h3><div className="metric">→</div><div className="muted">Weak / started / new / random / all</div></Link><Link href="/english/sources" className="card"><h3>Source Practice</h3><div className="metric">→</div><div className="muted">Recent/source-based revision</div></Link><Link href="/english/demand" className="card"><h3>Demand Sets</h3><div className="metric">→</div><div className="muted">Normalized set membership</div></Link></div></main>;
}

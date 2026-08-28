"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { rpc, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary = {
  ok:boolean;
  total_active:number;
  attempted:number;
  mastered:number;
  starred:number;
  difficult:number;
  daily_total:number;
  daily_completed:number;
};

const modules = [
  { href:"/english/starred", icon:"★", title:"Starred", desc:"High-priority revision you chose yourself." },
  { href:"/english/difficult", icon:"!", title:"Difficult", desc:"Questions that still need deliberate practice." },
  { href:"/english/saved", icon:"＋", title:"My Saved", desc:"Your own words, doubts and concept notes." },
  { href:"/english/phrasal", icon:"↔", title:"Phrasal Mastery", desc:"Recognition, reverse recall and confusion practice." },
  { href:"/english/hindu", icon:"H", title:"The Hindu", desc:"Daily vocabulary rounds and Add to Vocab." },
  { href:"/english/new", icon:"N", title:"New Practice", desc:"Fresh and recently-added learning material." },
  { href:"/english/topics", icon:"T", title:"Topic Practice", desc:"Jump into weak, started, new or random topics." },
  { href:"/english/sources", icon:"S", title:"Source Practice", desc:"Revise by lecture, PDF or source collection." },
  { href:"/english/demand", icon:"D", title:"Demand Sets", desc:"Purpose-built practice sets when you need them." },
];

export default function EnglishHome() {
  const ready = useAuthGuard();
  const router = useRouter();
  const [data,setData] = useState<Summary|null>(null);
  const [error,setError] = useState("");

  useEffect(()=>{
    if(!ready) return;
    rpc<Summary>("english_dashboard_summary").then(setData).catch(e=>setError(e.message));
  },[ready]);

  async function signOut(){
    await supabaseBrowser().auth.signOut();
    router.replace("/login");
  }

  if(!ready) return <main className="center"><div className="muted">Checking session…</div></main>;

  const dailyTotal = data?.daily_total || 0;
  const dailyDone = data?.daily_completed || 0;
  const dailyPct = dailyTotal ? Math.min(100, Math.round((dailyDone/dailyTotal)*100)) : 0;

  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <div className="brand-sub">Revision</div>
          <div className="brand">English Mastery</div>
        </div>
        <div className="row">
          <Link className="btn ghost" href="/">All modules</Link>
          <button className="btn" onClick={signOut}>Sign out</button>
        </div>
      </header>

      {error && <div className="error-box">{error}</div>}

      <section className="hero">
        <div className="hero-main">
          <div className="eyebrow">English · V2</div>
          <h1 className="hero-title">Your revision, without the friction.</h1>
          <p className="hero-copy">Continue what matters today, then move directly into weak areas, saved doubts and focused practice. Everything stays synced to your learning history.</p>
          <div className="row" style={{marginTop:22}}>
            <Link className="btn primary" href="/english/daily">Continue Daily →</Link>
            <Link className="btn ghost" href="/english/saved">Open My Saved</Link>
          </div>
        </div>

        <Link href="/english/daily" className="hero-side">
          <div>
            <div className="daily-kicker">TODAY&apos;S DAILY</div>
            <div className="daily-number">{data ? dailyDone : "—"}<span> / {data ? dailyTotal : "—"}</span></div>
            <div className="mini-progress"><span style={{width:`${dailyPct}%`}} /></div>
          </div>
          <div className="row" style={{justifyContent:"space-between",marginTop:20}}>
            <span className="muted">{data ? `${dailyPct}% complete` : "Loading progress…"}</span>
            <span style={{color:"var(--accent-2)",fontWeight:800}}>Resume →</span>
          </div>
        </Link>
      </section>

      <section className="stats-strip">
        <div className="stat"><div className="stat-value">{data?.attempted ?? "—"}</div><div className="stat-label">Attempted</div></div>
        <div className="stat"><div className="stat-value">{data?.mastered ?? "—"}</div><div className="stat-label">Mastered</div></div>
        <div className="stat"><div className="stat-value">{data?.starred ?? "—"}</div><div className="stat-label">Starred</div></div>
        <div className="stat"><div className="stat-value">{data?.difficult ?? "—"}</div><div className="stat-label">Difficult</div></div>
      </section>

      <div className="section-head">
        <div><div className="section-title">Practice spaces</div><div className="section-sub">Choose the kind of revision you need right now.</div></div>
        <div className="pill">{data ? `${data.total_active.toLocaleString()} active questions` : "Loading library…"}</div>
      </div>

      <section className="module-grid">
        {modules.map(m=>(
          <Link href={m.href} className="module-card" key={m.href}>
            <div className="module-icon">{m.icon}</div>
            <div className="module-body">
              <div className="module-title">{m.title}</div>
              <div className="module-desc">{m.desc}</div>
            </div>
            <div className="module-arrow">›</div>
          </Link>
        ))}
      </section>
    </main>
  );
}

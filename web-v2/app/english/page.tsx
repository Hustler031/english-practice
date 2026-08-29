"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import AddWordSheet from "@/components/add-word-sheet";
import { EnglishLoading } from "@/components/english-frame";
import { readPausedQuiz, type PausedQuizSession } from "@/lib/quiz-session";

type Summary = { total_active:number; attempted:number; mastered:number; starred:number; difficult:number; daily_total:number; daily_completed:number };
type PhrasalHub={today:{ready:boolean;count:number};stats:{due:number}};
type BankHub={coverage:number;exposed:number;total:number};
type SavedHub={stats:{saved:number;eligible:number;due:number}};
type StarredHub={stats:{focus:number;manualDifficult?:number;difficult?:number}};
type HinduWord={id:string};
type Recommendation={route:string;mode?:string;count?:number;reason?:string};
type Intelligence={recommended?:Recommendation;queues?:Record<string,number>;daily?:{actionableRemaining:number};coreCoverage?:{percent:number}};
type HomeSnapshot={ok:boolean;studyDay:number;summary:Summary;intelligence:Intelligence;phrasal:PhrasalHub;bank:BankHub;saved:SavedHub;starred:StarredHub;hindu:HinduWord[]};

const quick = [["📰", "The Hindu – Today", "Today's vocabulary", "/english/hindu?return=/english", "hindu"], ["🔖", "My Saved Words", "Personal Smart Revision", "/english/saved", "saved"], ["↗", "Phrasal Verb", "Smart revision + Today's batch", "/english/phrasal", "phrasal"], ["★", "Starred Revision", "Central Starred Intelligence", "/english/starred", "starred"], ["◫", "Bank Coverage", "Optional unseen-bank exposure", "/english/bank", "bank"]] as const;

function recommendationHref(rec?:Recommendation){
  if(!rec)return "/english/revision";
  if(rec.route==="daily")return "/english/daily";
  if(rec.route==="bankCoverage")return "/english/bank";
  if(rec.route==="revision")return "/english/revision";
  return "/english/revision";
}
function recommendationTitle(rec?:Recommendation){
  if(!rec)return "Smart Revision";
  if(rec.route==="daily")return "Resume Daily";
  if(rec.route==="bankCoverage")return "Expand Bank Coverage";
  if(rec.mode==="due")return "Due Revision";
  if(rec.mode==="difficult")return "Difficult Recall";
  if(rec.mode==="recall")return "Recall Rotation";
  return "Smart Revision";
}

export default function EnglishHome() {
  const ready=useAuthGuard();
  const [snapshot,setSnapshot]=useState<HomeSnapshot|null>(null);
  const [error,setError]=useState("");
  const [paused,setPaused]=useState<PausedQuizSession|null>(null);

  useEffect(()=>{
    if(!ready)return;
    let alive=true;
    const unsubscribe=subscribeRpcFresh<HomeSnapshot>("english_get_home_snapshot",undefined,x=>{if(alive)setSnapshot(x)});
    rpc<HomeSnapshot>("english_get_home_snapshot").then(x=>{if(alive)setSnapshot(x)}).catch((e:any)=>{if(alive)setError(e.message)});
    setPaused(readPausedQuiz());
    return()=>{alive=false;unsubscribe();};
  },[ready]);

  if(!ready)return <EnglishLoading text="Checking session…"/>;
  const data=snapshot?.summary,phrasal=snapshot?.phrasal,bank=snapshot?.bank,saved=snapshot?.saved,starred=snapshot?.starred,hinduCount=snapshot?.hindu?.length??null;
  const total=data?.daily_total??0,completed=data?.daily_completed??0,percent=total?Math.min(100,Math.round((completed/total)*100)):0,dayNo=snapshot?.studyDay??1;
  const rec=snapshot?.intelligence?.recommended;
  const status=(accent:string)=>{
    if(accent==="hindu")return hinduCount===null?"…":`${hinduCount} today`;
    if(accent==="saved")return saved?`${saved.stats.eligible} active`:"…";
    if(accent==="phrasal")return phrasal?`Smart + Today’s ${phrasal.today.count||20}`:"…";
    if(accent==="starred"){
      if(!starred)return "…";
      const diff=Number(starred.stats.manualDifficult??starred.stats.difficult??0);
      return `${Number(starred.stats.focus||0)} focus${diff?` · ${diff} ⚡`:""}`;
    }
    if(accent==="bank")return bank?`${bank.coverage.toFixed(0)}% exposed`:"…";
    return "Open";
  };

  return <>
    {error&&<div className="error-box">{error}</div>}
    <section className="daily-hero"><div className="daily-hero-top"><div><span className="eyebrow">Day {dayNo} · Today</span><h1>Day {dayNo} · Today&apos;s English Practice</h1></div><span className="today-badge">{data?`${completed} done`:"Syncing"}</span></div><p>Finish your daily revision first, then use focused practice.</p><div className="goal-line"><span>Today&apos;s Goal</span><strong>{data?`${completed} / ${total}`:"—"}</strong></div><div className="progress-track"><i style={{width:`${percent}%`}}/></div><div className="daily-status">{data?(completed>=total&&total?"Daily target complete.":`${Math.max(0,total-completed)} questions remain.`):"Using your last cached plan while fresh data syncs…"}</div><Link className="btn daily-button" href="/english/daily">{completed?"Continue Daily Practice":"Start Daily Practice"}</Link></section>
    {rec&&<section className="home-recommended"><div className="home-recommended-copy"><span className="eyebrow">🧠 Central Intelligence</span><h2>{recommendationTitle(rec)}{rec.count?` · ${rec.count}`:""}</h2><p>{rec.reason||"Continue with the highest-value revision queue right now."}</p></div><Link className="btn primary" href={recommendationHref(rec)}>Start</Link></section>}
    {paused&&<section className="section-block"><Link className="resume-card" href="/english/resume"><span>Ⅱ</span><span><b>Resume paused practice</b><small>{paused.title} · {paused.index+1} / {paused.questions.length}</small></span><i>›</i></Link></section>}
    <section className="section-block"><div className="section-title-line"><h2>Quick Start</h2><AddWordSheet label="＋ Add Word"/></div><div className="study-list">{quick.map(([icon,title,sub,href,accent])=><Link className={`study-row home-quick-row accent-${accent}`} href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">{status(accent)}</span><i>›</i></Link>)}</div></section>
  </>;
}

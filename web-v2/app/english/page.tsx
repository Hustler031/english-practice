"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import AddWordSheet from "@/components/add-word-sheet";
import { EnglishLoading } from "@/components/english-frame";
import { readPausedQuiz, type PausedQuizSession } from "@/lib/quiz-session";

type Summary = { total_active:number; attempted:number; mastered:number; starred:number; difficult:number; daily_total:number; daily_completed:number };
type PhrasalHub={today:{ready:boolean;count:number};stats:{due:number}};type BankHub={coverage:number;exposed:number;total:number};type SavedHub={stats:{saved:number;eligible:number;due:number}};type StarredHub={stats:{focus:number;manualDifficult?:number;difficult?:number}};type HinduWord={id:string};
type Intelligence={queues?:Record<string,number>;daily?:{actionableRemaining:number;suppressed?:number};coreCoverage?:{percent:number}};
type HomeSnapshot={ok:boolean;studyDay:number;summary:Summary;intelligence:Intelligence;phrasal:PhrasalHub;bank:BankHub;saved:SavedHub;starred:StarredHub;hindu:HinduWord[]};
const quick = [["📰", "The Hindu – Today", "Today's vocabulary", "/english/hindu?return=/english", "hindu"], ["🔖", "My Saved Words", "Personal Smart Revision", "/english/saved", "saved"], ["↗", "Phrasal Verb", "Smart revision + Today's batch", "/english/phrasal", "phrasal"], ["★", "Starred Revision", "Central Starred Intelligence", "/english/starred", "starred"], ["◫", "Bank Coverage", "Optional unseen-bank exposure", "/english/bank", "bank"]] as const;
function fallbackStudyDay(){try{const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(new Date());const get=(type:string)=>Number(parts.find(p=>p.type===type)?.value||0);const today=Date.UTC(get("year"),get("month")-1,get("day"));return Math.max(1,Math.floor((today-Date.UTC(2026,7,14))/86400000)+1);}catch{return 1;}}

export default function EnglishHome() {
 const ready=useAuthGuard();const[snapshot,setSnapshot]=useState<HomeSnapshot|null>(null);const[error,setError]=useState("");const[paused,setPaused]=useState<PausedQuizSession|null>(null);
 useEffect(()=>{if(!ready)return;let alive=true;const accept=(x:HomeSnapshot)=>{if(alive){setSnapshot(x);setError("");}};const unsubscribe=subscribeRpcFresh<HomeSnapshot>("english_get_home_snapshot",undefined,accept);rpc<HomeSnapshot>("english_get_home_snapshot").then(accept).catch((e:any)=>{if(alive)setError(e.message)});setPaused(readPausedQuiz());return()=>{alive=false;unsubscribe();};},[ready]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 const data=snapshot?.summary,phrasal=snapshot?.phrasal,bank=snapshot?.bank,saved=snapshot?.saved,starred=snapshot?.starred,hinduCount=snapshot?.hindu?.length??null;const total=data?.daily_total??0,completed=data?.daily_completed??0,percent=total?Math.min(100,Math.round((completed/total)*100)):0,dayNo=snapshot?.studyDay??fallbackStudyDay();const fallbackRemaining=Math.max(0,total-completed);const actionableRemaining=snapshot?.intelligence?.daily?.actionableRemaining??fallbackRemaining;const suppressedToday=Math.max(0,Number(snapshot?.intelligence?.daily?.suppressed??Math.max(0,fallbackRemaining-actionableRemaining)));const dailyComplete=!!data&&total>0&&actionableRemaining===0;
 const status=(accent:string)=>{if(accent==="hindu")return hinduCount===null?"…":`${hinduCount} today`;if(accent==="saved")return saved?`${saved.stats.eligible} active`:"…";if(accent==="phrasal")return phrasal?`Smart + Today’s ${phrasal.today.count||20}`:"…";if(accent==="starred"){if(!starred)return "…";const diff=Number(starred.stats.manualDifficult??starred.stats.difficult??0);return `${Number(starred.stats.focus||0)} focus${diff?` · ${diff} ⚡`:""}`;}if(accent==="bank")return bank?`${bank.coverage.toFixed(0)}% exposed`:"…";return "Open";};
 const dailyStatus=!data?"Using your last cached plan while fresh data syncs…":dailyComplete?(suppressedToday?`Daily queue complete · ${suppressedToday} no longer due today.`:"Daily practice complete for the current due clock."):`${actionableRemaining} questions remain now${suppressedToday?` · ${suppressedToday} no longer due today.`:"."}`;
 return <>
  {error&&<div className="error-box">{error}</div>}
  <section className="daily-hero"><div className="daily-hero-top"><div><span className="eyebrow">Day {dayNo} · Today</span><h1>Day {dayNo} · Today&apos;s English Practice</h1></div><span className="today-badge">{data?`${completed} done`:"Syncing"}</span></div><p>Finish your daily revision first, then use focused practice.</p><div className="goal-line"><span>Daily target (max)</span><strong>{data?`${completed} / ${total}`:"—"}</strong></div><div className="progress-track"><i style={{width:`${percent}%`}}/></div><div className="daily-status">{dailyStatus}</div><Link className="btn daily-button" href="/english/daily">{dailyComplete?"Daily Complete ✓":completed?"Continue Daily Practice":"Start Daily Practice"}</Link></section>
  {dailyComplete&&<section className="practice-more-card"><div className="practice-more-copy"><span className="eyebrow">Optional · after Daily</span><h2>Want to practice more?</h2><p>Today&apos;s wrong answers, items you marked Difficult or Starred, then your highest-value Weak/PW recall.</p><div className="practice-more-chips"><span>Today&apos;s wrong</span><span>Difficult</span><span>Marked</span><span>Weak / PW</span></div></div><Link className="btn primary" href="/english/extra?count=20">Start 20</Link></section>}
  {paused&&<section className="section-block"><Link className="resume-card" href="/english/resume"><span>Ⅱ</span><span><b>Resume paused practice</b><small>{paused.title} · {paused.index+1} / {paused.questions.length}</small></span><i>›</i></Link></section>}
  <section className="section-block"><div className="section-title-line"><h2>Quick Start</h2><AddWordSheet label="＋ Add Word"/></div><div className="study-list">{quick.map(([icon,title,sub,href,accent])=><Link className={`study-row home-quick-row accent-${accent}`} href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">{status(accent)}</span><i>›</i></Link>)}</div></section>
 </>;
}

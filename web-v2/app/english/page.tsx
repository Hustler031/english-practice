"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { rpc, subscribeRpcFresh } from "@/lib/supabase";
import { subscribeTargetedDurability, targetedLiveRpc } from "@/lib/targeted-reliability";
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
type Intelligence={queues?:Record<string,number>;daily?:{actionableRemaining:number;suppressed?:number};coreCoverage?:{percent:number}};
type HomeSnapshot={ok:boolean;studyDay:number;summary:Summary;intelligence:Intelligence;phrasal:PhrasalHub;bank:BankHub;saved:SavedHub;starred:StarredHub;hindu:HinduWord[]};
type ExamSummary={daysLeft:number;goalMarks:number};
type TargetedSummary={ok:boolean;active:number;dueNow:number;confusions:number;needLearning:number;transferChecks:number;retentionChecks:number};

const quick = [
 ["📰", "The Hindu – Today", "Fresh vocabulary batch", "/english/hindu?return=/english", "hindu"],
 ["🔖", "My Saved Words", "Personal recall queue", "/english/saved", "saved"],
 ["◎", "Targeted Mastery", "Focused concept repair + transfer proof", "/english/targeted", "targeted"],
 ["↗", "Phrasal Verb", "Today’s batch + smart revision", "/english/phrasal", "phrasal"],
 ["★", "Starred Revision", "Marked and difficult focus", "/english/starred", "starred"],
] as const;

function fallbackStudyDay(){
 try{
  const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(new Date());
  const get=(type:string)=>Number(parts.find(p=>p.type===type)?.value||0);
  const today=Date.UTC(get("year"),get("month")-1,get("day"));
  return Math.max(1,Math.floor((today-Date.UTC(2026,7,14))/86400000)+1);
 }catch{return 1;}
}

export default function EnglishHome() {
 const ready=useAuthGuard();
 const[snapshot,setSnapshot]=useState<HomeSnapshot|null>(null);
 const[exam,setExam]=useState<ExamSummary|null>(null);
 const[targeted,setTargeted]=useState<TargetedSummary|null>(null);
 const[error,setError]=useState("");
 const[paused,setPaused]=useState<PausedQuizSession|null>(null);

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  const accept=(x:HomeSnapshot)=>{if(alive){setSnapshot(x);setError("");}};
  const refreshTargeted=()=>targetedLiveRpc<TargetedSummary>("english_get_targeted_summary").then(x=>{if(alive)setTargeted(x)}).catch(()=>{});
  const unsubscribe=subscribeRpcFresh<HomeSnapshot>("english_get_home_snapshot",undefined,accept);
  const unsubscribeTargeted=subscribeTargetedDurability(()=>void refreshTargeted());
  rpc<HomeSnapshot>("english_get_home_snapshot").then(accept).catch((e:any)=>{if(alive)setError(e.message)});
  rpc<ExamSummary>("english_get_exam_preparation").then(x=>{if(alive)setExam(x)}).catch(()=>{});
  void refreshTargeted();
  setPaused(readPausedQuiz());
  return()=>{alive=false;unsubscribe();unsubscribeTargeted();};
 },[ready]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;

 const data=snapshot?.summary,phrasal=snapshot?.phrasal,saved=snapshot?.saved,starred=snapshot?.starred,hinduCount=snapshot?.hindu?.length??null;
 const total=data?.daily_total??0,completed=data?.daily_completed??0,percent=total?Math.min(100,Math.round((completed/total)*100)):0,dayNo=snapshot?.studyDay??fallbackStudyDay();
 const fallbackRemaining=Math.max(0,total-completed);
 const actionableRemaining=snapshot?.intelligence?.daily?.actionableRemaining??fallbackRemaining;
 const suppressedToday=Math.max(0,Number(snapshot?.intelligence?.daily?.suppressed??Math.max(0,fallbackRemaining-actionableRemaining)));
 const dailyComplete=!!data&&total>0&&actionableRemaining===0;
 const status=(accent:string)=>{
  if(accent==="hindu")return hinduCount===null?"…":`${hinduCount} today`;
  if(accent==="saved")return saved?`${saved.stats.eligible} active`:"…";
  if(accent==="phrasal")return phrasal?`Smart + Today’s ${phrasal.today.count||20}`:"…";
  if(accent==="starred"){
   if(!starred)return "…";
   const diff=Number(starred.stats.manualDifficult??starred.stats.difficult??0);
   return `${Number(starred.stats.focus||0)} focus${diff?` · ${diff} ⚡`:""}`;
  }
  if(accent==="targeted")return targeted?`${targeted.dueNow} due${targeted.confusions?` · ${targeted.confusions} confusion`:""}`:"…";
  return "Open";
 };

 return <>
  {error&&<div className="error-box">{error}</div>}

  {dailyComplete?
   <section className="daily-complete-card">
    <div className="daily-complete-main"><span className="daily-complete-icon">✓</span><div className="daily-complete-copy"><span className="eyebrow">Day {dayNo} · Daily complete</span><h1>Today’s due work is done</h1><p>{completed} completed{suppressedToday?` · ${suppressedToday} no longer due now`:""}. Daily target is a maximum, not a fill requirement.</p></div></div>
    <span className="today-badge">{completed} done</span>
   </section>
   :
   <section className="daily-active-card">
    <div className="daily-active-top">
     <div className="daily-active-copy"><span className="eyebrow">Day {dayNo} · Daily Practice</span><h1>Today’s due practice</h1><p>{data?`${actionableRemaining} due now`:"Syncing today’s queue…"}</p></div>
     <div className="daily-active-side"><strong>{data?`${completed} / ${total}`:"—"}</strong><Link className="btn primary" href="/english/daily">{completed?"Continue":"Start Daily"}</Link></div>
    </div>
    <div className="progress-track daily-active-progress"><i style={{width:`${percent}%`}}/></div>
   </section>
  }

  {dailyComplete&&<section className="practice-more-card compact-extra-card"><div className="practice-more-copy"><span className="eyebrow">Optional · after Daily</span><h2>Focused extra practice</h2><p>Wrong, Difficult, Marked · Weak/PW</p></div><Link className="btn primary" href="/english/extra?count=20">Start 20</Link></section>}

  {paused&&<section className="section-block"><Link className="resume-card" href="/english/resume"><span>Ⅱ</span><span><b>Resume paused practice</b><small>{paused.title} · {paused.index+1} / {paused.questions.length}</small></span><i>›</i></Link></section>}

  <section className="exam-home-row"><Link href="/english/exam"><span><b>EXAM PREPARATION</b><small>{exam?`${exam.daysLeft} Days Left · Sprint · ${exam.goalMarks}+ Goal`:"SSC Sprint · 45+ Goal"}</small></span><i>›</i></Link></section>

  <section className="section-block"><div className="section-title-line"><h2>Quick Start</h2><AddWordSheet label="＋ Add Word"/></div><div className="study-list">{quick.map(([icon,title,sub,href,accent])=><Link className={`study-row home-quick-row accent-${accent}`} href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">{status(accent)}</span><i>›</i></Link>)}</div></section>
 </>;
}

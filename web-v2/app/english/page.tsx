"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { learnerErrorMessage, rpc, subscribeRpcFresh } from "@/lib/supabase";
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
type TargetedSummary={ok:boolean;active:number;dueNow:number;confusions:number;needLearning:number;transferChecks:number;retentionChecks:number};
type DailyFocusSummary={ok:boolean;batchDate:string;carryover:boolean;status:"active"|"completed";total:number;completed:number;remaining:number;nominalTarget:number;buildVersion?:string};
type DailyCurrent={ok:boolean;batch_date:string|null;today:string;pending_previous_day:boolean;total:number;completed:number;remaining:number};
type ReviewDueSummary={ok:boolean;date:string;phase:string;snapshotReady:boolean;snapshotAt:string|null;dueQuestionCount:number;dueAtStart:number;carryoverConcepts?:number;satisfied:number;satisfiedElsewhere:number;needsRepair:number;lowConfidence:number;remaining:number;actionable?:number;duplicateTouches:number;overdueConcepts:number|null;routingChanged:boolean;countsTowardDailyFocus:boolean;practiceEnabled?:boolean;crossCreditEnabled?:boolean};

const quick = [
 ["📰", "The Hindu – Today", "Fresh vocabulary batch", "/english/hindu?return=/english", "hindu"],
 ["🔖", "My Saved Words", "Personal recall queue", "/english/saved", "saved"],
 ["◎", "Targeted Mastery", "Focused concept repair + transfer proof", "/english/targeted", "targeted"],
 ["↗", "Phrasal Verb", "Today’s batch + smart revision", "/english/phrasal", "phrasal"],
 ["★", "Starred Revision", "Marked and difficult focus", "/english/starred", "starred"],
] as const;

const months=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
function shortDate(value?:string|null){
 const [y,m,d]=String(value||"").split("-").map(Number);
 return y&&m&&d?`${d} ${months[m-1]||""}`:String(value||"");
}
function isYesterday(batchDate?:string|null,today?:string|null){
 const [by,bm,bd]=String(batchDate||"").split("-").map(Number),[ty,tm,td]=String(today||"").split("-").map(Number);
 if(!by||!bm||!bd||!ty||!tm||!td)return false;
 return Date.UTC(ty,tm-1,td)-Date.UTC(by,bm-1,bd)===86400000;
}
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
 const[targeted,setTargeted]=useState<TargetedSummary|null>(null);
 const[focus,setFocus]=useState<DailyFocusSummary|null>(null);
 const[dailyCurrent,setDailyCurrent]=useState<DailyCurrent|null>(null);
 const[reviewDue,setReviewDue]=useState<ReviewDueSummary|null>(null);
 const[error,setError]=useState("");
 const[paused,setPaused]=useState<PausedQuizSession|null>(null);

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  const accept=(x:HomeSnapshot)=>{if(alive){setSnapshot(x);setError("");}};
  const acceptReviewDue=(x:ReviewDueSummary)=>{if(alive)setReviewDue(x)};
  const refreshTargeted=()=>targetedLiveRpc<TargetedSummary>("english_get_targeted_summary").then(x=>{if(alive)setTargeted(x)}).catch(()=>{});
  const refreshFocus=()=>rpc<DailyFocusSummary>("english_get_daily_focus_summary").then(x=>{if(alive)setFocus(x)}).catch(()=>{});
  const refreshDailyCurrent=()=>rpc<DailyCurrent>("english_get_daily_current").then(x=>{if(alive)setDailyCurrent(x)}).catch(()=>{});
  const refreshReviewDue=()=>rpc<ReviewDueSummary>("english_get_review_due_today").then(acceptReviewDue).catch(()=>{});
  const unsubscribe=subscribeRpcFresh<HomeSnapshot>("english_get_home_snapshot",undefined,accept);
  const unsubscribeReviewDue=subscribeRpcFresh<ReviewDueSummary>("english_get_review_due_today",undefined,acceptReviewDue);
  const unsubscribeTargeted=subscribeTargetedDurability(()=>void refreshTargeted());
  rpc<HomeSnapshot>("english_get_home_snapshot").then(accept).catch((e:any)=>{if(alive)setError(learnerErrorMessage(e,"Home data is taking longer than usual. Please retry."))});
  void refreshTargeted();
  void refreshFocus();
  void refreshDailyCurrent();
  void refreshReviewDue();
  setPaused(readPausedQuiz());
  return()=>{alive=false;unsubscribe();unsubscribeReviewDue();unsubscribeTargeted();};
 },[ready]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;

 const data=snapshot?.summary,phrasal=snapshot?.phrasal,saved=snapshot?.saved,starred=snapshot?.starred,hinduCount=snapshot?.hindu?.length??null;
 const total=data?.daily_total??0,completed=data?.daily_completed??0,percent=total?Math.min(100,Math.round((completed/total)*100)):0,dayNo=snapshot?.studyDay??fallbackStudyDay();
 const fallbackRemaining=Math.max(0,total-completed);
 const actionableRemaining=snapshot?.intelligence?.daily?.actionableRemaining??fallbackRemaining;
 const suppressedToday=Math.max(0,Number(snapshot?.intelligence?.daily?.suppressed??Math.max(0,fallbackRemaining-actionableRemaining)));
 const dailyComplete=!!data&&total>0&&actionableRemaining===0;
 const dailyCarryover=!!dailyCurrent?.pending_previous_day&&!!dailyCurrent?.batch_date;
 const carryoverTitle=isYesterday(dailyCurrent?.batch_date,dailyCurrent?.today)?"Pending yesterday’s Daily Mix":`Pending ${shortDate(dailyCurrent?.batch_date)} Daily Mix`;
 const reviewActionable=reviewDue?.actionable??((reviewDue?.needsRepair||0)+(reviewDue?.lowConfidence||0)+(reviewDue?.remaining||0));
 const reviewCarryover=Math.max(0,reviewDue?.carryoverConcepts||0);
 const reviewFocusCopy=!reviewDue?.snapshotReady
   ?"Review Due syncing"
   :reviewActionable===0
     ?`Review Due ✓ ${reviewDue.dueAtStart} covered${reviewCarryover?` · ${reviewCarryover} carried in`:""}`
     :`Review Due ${reviewActionable} left${reviewCarryover?` · ${reviewCarryover} carryover`:""}`;
 const dailyStatusCopy=data
   ?dailyCarryover
     ?`${actionableRemaining} left · Finish pending batch first.`
     :`${actionableRemaining} left · Review Due is separate.`
   :"Syncing today’s queue…";
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
    <div className="daily-complete-main"><span className="daily-complete-icon">✓</span><div className="daily-complete-copy"><span className="eyebrow">Day {dayNo} · Daily complete</span><h1>Daily Mix complete</h1><p>{completed} done{suppressedToday?` · ${suppressedToday} satisfied elsewhere`:""}</p></div></div>
    <span className="today-badge">Done</span>
   </section>
   :
   <section className="daily-active-card home-daily-primary">
    <div className="daily-active-top">
     <div className="daily-active-copy"><span className="eyebrow">Day {dayNo} · Daily Mix{dailyCarryover?" · CATCH-UP":""}</span><h1>{dailyCarryover?carryoverTitle:"Today’s performance mix"}</h1><p>{dailyStatusCopy}</p></div>
     <div className="daily-active-side"><strong>{data?`${completed} / ${total}`:"—"}</strong><Link className="btn primary" href="/english/daily">{dailyCarryover?"Continue pending":completed?"Continue":"Start Daily"}</Link></div>
    </div>
    <div className="progress-track daily-active-progress"><i style={{width:`${percent}%`}}/></div>
   </section>
  }

  <section className="section-block">
   <Link className="resume-card" href="/english/focus">
    <span>◎</span>
    <span><b>Daily Focus · {focus?`${focus.completed} / ${focus.total||focus.nominalTarget}`:"Syncing"}</b><small>{focus?.carryover?`Carry-over ${focus.batchDate} · finish active batch · ${reviewFocusCopy}`:focus?.status==="completed"?`Mandatory focus complete ✓ · ${reviewFocusCopy}`:`Repair · Bank Coverage · Fast Track · ${reviewFocusCopy}`}</small></span>
    <i>›</i>
   </Link>
  </section>

  {dailyComplete&&<section className="practice-more-card compact-extra-card"><div className="practice-more-copy"><span className="eyebrow">Optional · after Daily</span><h2>Focused extra practice</h2><p>Wrong, Difficult, Marked · Weak/PW</p></div><Link className="btn primary" href="/english/extra?count=20">Start 20</Link></section>}

  {paused&&<section className="home-resume-section"><Link className="paused-resume-strip" href="/english/resume"><span className="paused-resume-icon">Ⅱ</span><span className="paused-resume-copy"><b>Continue paused session</b><small>{paused.title} · {paused.index+1} / {paused.questions.length}</small></span><span className="paused-resume-action">Resume ›</span></Link></section>}

  <section className="exam-home-row"><Link href="/english/grammar"><span><b>GRAMMAR</b><small>Daily 20 · Adaptive Grammar Intelligence</small></span><i>›</i></Link></section>

  <section className="section-block"><div className="section-title-line"><h2>Quick Start</h2><AddWordSheet label="＋ Add Word"/></div><div className="study-list">{quick.map(([icon,title,sub,href,accent])=><Link className={`study-row home-quick-row accent-${accent}`} href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">{status(accent)}</span><i>›</i></Link>)}</div></section>
 </>;
}

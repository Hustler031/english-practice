"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { readPausedQuiz, type PausedQuizSession } from "@/lib/quiz-session";

type Chapter={chapter:string;totalRules:number;coveredRules:number;coveragePercent:number;weakRules:number;dueRules:number;questionCount:number};
type TodayState={date:string;count:number;target:number;ready:boolean;newCount?:number;reviewCount?:number;practiced?:number;remaining?:number;correct?:number;wrong?:number;round2Focus?:number;complete?:boolean};
type DailyState={activeDate?:string|null;activeTotal?:number;activePracticed?:number;activeRemaining?:number;activeCorrect?:number;activeWrong?:number;activeRound2Focus?:number;isBacklog?:boolean;todayLocked?:boolean};
type Hub={
 ok:boolean;
 dailyTarget:number;
 stats:{totalRules:number;covered:number;coveragePercent:number;weak:number;due:number;mastered:number};
 today:TodayState;
 daily?:DailyState;
 available:{smart:number;weak:number;due:number;all:number};
 sizes:number[];
 chapters:Chapter[];
 readOnlyBrowsing:boolean;
};
type HistoryRow={type:"day"|"block"|"month";label:string;fromDay:number;toDay:number;generated:number;practised:number;correct:number;wrong:number;round2Focus:number;complete:boolean;date?:string;isToday?:boolean};
type HistoryResponse={ok:boolean;currentDay:number;history:HistoryRow[]};
type Pick={kind:"daily"|"round2"|"history";label:string;batchDate?:string;fromDay?:number;toDay?:number;resumeSession?:PausedQuizSession|null};
const months=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

function shortDate(value?:string|null){
 const [y,m,d]=String(value||"").split("-").map(Number);
 return y&&m&&d?`${d} ${months[m-1]||""}`:String(value||"");
}
function firstUnanswered(session:PausedQuizSession|null){
 if(!session)return null;
 const answers=session.answers||{};
 const rows=session.questions as Array<{id?:string}>;
 const next=rows.findIndex(row=>{const id=String(row?.id||"");return !!id&&!answers[id];});
 return {...session,index:next>=0?next:Math.max(0,Math.min(session.index||0,rows.length-1))};
}
function matchingSession(session:PausedQuizSession|null,module:string,title:string,count?:number){
 if(!session||session.module!==module||session.backHref!=="/english/grammar"||session.title!==title)return null;
 if(count&&session.questions.length!==count)return null;
 return firstUnanswered(session);
}

export default function GrammarWorld(){
 const ready=useAuthGuard(),router=useRouter();
 const [hub,setHub]=useState<Hub|null>(null);
 const [history,setHistory]=useState<HistoryRow[]>([]);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pausedGrammar,setPausedGrammar]=useState<PausedQuizSession|null>(null);
 const [error,setError]=useState("");

 const refreshHub=useCallback(async()=>{
  if(!ready)return;
  try{const x=await rpc<Hub>("english_get_grammar_hub");setHub(x);setError("");}
  catch(e:any){setError(learnerErrorMessage(e,"Grammar Intelligence is taking longer than usual. Please retry."));}
 },[ready]);
 const refreshHistory=useCallback(async()=>{
  if(!ready)return;
  try{const x=await rpc<HistoryResponse>("english_get_grammar_history");setHistory(Array.isArray(x?.history)?x.history:[]);}catch{}
 },[ready]);

 useEffect(()=>{
  if(!ready)return;
  let live=true;
  const accept=(x:Hub)=>{if(live){setHub(x);setError("");}};
  const off=subscribeRpcFresh<Hub>("english_get_grammar_hub",undefined,accept);
  refreshHub().catch(()=>{});
  refreshHistory().catch(()=>{});
  setPausedGrammar(firstUnanswered(readPausedQuiz()));
  return()=>{live=false;off();};
 },[ready,refreshHub,refreshHistory]);

 const load=useCallback(()=>{
  if(!pick)return Promise.resolve([]);
  if(pick.kind==="daily")return rpc<any>("english_get_grammar_today").then(x=>Array.isArray(x?.items)?x.items:[]);
  if(pick.kind==="round2")return rpc<any>("english_get_grammar_round2",{p_batch_date:pick.batchDate||null}).then(x=>Array.isArray(x?.items)?x.items:[]);
  return rpc<any[]>("english_get_grammar_history_batch",{p_from_day:pick.fromDay,p_to_day:pick.toDay});
 },[pick]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick){
  const module=pick.kind==="history"?"grammarrevision":`grammardaily:${pick.batchDate||hub?.today?.date||""}`;
  return <QuizRunner title={pick.label} backHref="/english/grammar" load={load} module={module} resumeSession={pick.resumeSession||null} onExit={()=>{
   setPick(null);
   window.setTimeout(()=>{
    setPausedGrammar(firstUnanswered(readPausedQuiz()));
    refreshHub().catch(()=>{});
    refreshHistory().catch(()=>{});
   },0);
  }}/>;
 }

 const s=hub?.stats,t=hub?.today,d=hub?.daily;
 const activeDate=d?.activeDate||t?.date||"";
 const activeTotal=Number(d?.activeTotal??t?.count??hub?.dailyTarget??20);
 const activePracticed=Number(d?.activePracticed??t?.practiced??0);
 const activeRemaining=Number(d?.activeRemaining??t?.remaining??Math.max(0,activeTotal-activePracticed));
 const isBacklog=!!d?.isBacklog;
 const todayComplete=!isBacklog&&!!t?.complete;
 const round2Focus=Number(t?.round2Focus||0);
 const dailyModule=activeDate?`grammardaily:${activeDate}`:"grammardaily";
 const dailyTitle=isBacklog?`Grammar · Catch-up ${shortDate(activeDate)}`:"Grammar · Today";
 const dailyResume=matchingSession(pausedGrammar,dailyModule,dailyTitle,activeTotal||20);
 const round2Title="Grammar · Round 2";
 const round2Module=t?.date?`grammardaily:${t.date}`:"grammardaily";
 const round2Resume=matchingSession(pausedGrammar,round2Module,round2Title,round2Focus||undefined);
 const newCount=Number(t?.newCount??0),reviewCount=Number(t?.reviewCount??Math.max(0,(t?.count||0)-newCount));

 let dailyHeading=`Today’s ${t?.count||hub?.dailyTarget||20}`;
 let dailySummary=t?.ready?`${newCount||t.count} new${reviewCount?` · ${reviewCount} review`:""} · ${Number(t.practiced||0)}/${t.count} practiced`:`Today’s exact-20 Grammar batch has not been published yet.`;
 let dailyBadge=t?.ready?"READY":"PENDING";
 let dailyButton=`Practice Today’s ${t?.count||hub?.dailyTarget||20}`;
 let dailyDisabled=!t?.ready;
 let dailyAction=()=>{
  if(!activeDate)return;
  setPick({kind:"daily",label:dailyTitle,batchDate:activeDate,resumeSession:dailyResume});
 };

 if(isBacklog){
  dailyHeading=`Pending ${shortDate(activeDate)} · Grammar`;
  dailySummary=`${activePracticed}/${activeTotal} practiced · ${activeRemaining} left · finish this before today’s batch.`;
  dailyBadge="CATCH-UP";
  dailyButton=`Continue ${shortDate(activeDate)} · ${activeRemaining} left`;
  dailyDisabled=!activeDate||activeTotal===0;
 }else if(todayComplete){
  dailyHeading="Today’s Practice ✓ Complete";
  dailySummary=`${t?.practiced||20}/20 practiced · ${t?.correct||0} correct${round2Focus?` · ${round2Focus} focus for Round 2`:""} · ${newCount} new · ${reviewCount} review`;
  dailyBadge="COMPLETE";
  if(round2Focus>0){
   dailyButton=`Round 2 · ${round2Focus} focus`;
   dailyDisabled=false;
   dailyAction=()=>setPick({kind:"round2",label:round2Title,batchDate:t?.date,resumeSession:round2Resume});
  }else{
   dailyButton="✓ Done for today";
   dailyDisabled=true;
  }
 }else if(t?.ready&&Number(t.practiced||0)>0){
  dailyButton=`Resume Today’s 20 · ${t.practiced} done`;
 }

 return <main className="phrasal-parity-page">
  <section className="pv-page-subhead"><button className="btn ghost" onClick={()=>window.history.length>1?router.back():router.push("/english")}>← Back</button><div><h1>Grammar</h1><p>Daily rules + adaptive SSC practice.</p></div></section>
  {error&&<div className="error-box">{error}</div>}

  <section className="pv-legacy-card" style={{order:1}}>
   <div className="pv-legacy-head"><div><h2>🧠 Grammar Intelligence</h2><p>Rule evidence · weak/due signals · progressive question variants.</p></div><span className="pv-concept-pill">{s?.totalRules??"—"} rules</span></div>
   <div className="pv-legacy-metrics">
    <div><b>{s?`${s.covered} / ${s.totalRules}`:"—"}</b><small>Covered</small></div>
    <div><b>{s?.due??"—"}</b><small>Due</small></div>
    <div><b>{s?.weak??"—"}</b><small>Weak</small></div>
    <div><b>{s?.mastered??"—"}</b><small>Mastered</small></div>
   </div>
   <div className="pv-cache-note">Grammar Intelligence updates from real practice evidence</div>
  </section>

  <section className="pv-today-legacy" style={{order:2}}>
   <div className="pv-today-head"><div><h2>{dailyHeading}</h2><p>{dailySummary}</p></div><span className={`pv-ready-pill ${dailyBadge==="PENDING"?"pending":"ready"}`}>{dailyBadge}</span></div>
   <button className="btn primary pv-today-button" disabled={dailyDisabled} onClick={dailyAction}>{dailyButton}</button>
  </section>

  <section className="section-block" style={{order:3}}>
   <div className="legacy-list">
    <Link className="legacy-row" href="/english/grammar/practice"><span className="legacy-row-copy"><b>Practice</b><small>Smart · Weak · Due · Practice All</small></span><span className="legacy-chevron">›</span></Link>
   </div>
   <details className="practice-more-details">
    <summary><span><b>Chapters</b><small>Focused chapter practice + read-only rule review</small></span></summary>
    <div className="practice-more-list">{hub?.chapters?.length?hub.chapters.map(ch=><Link href={`/english/grammar/chapter/${encodeURIComponent(ch.chapter)}`} key={ch.chapter}><span><b>{ch.chapter}</b><small>{ch.coveredRules}/{ch.totalRules} covered · {ch.weakRules} weak · {ch.dueRules} due · {ch.questionCount} questions</small></span></Link>):<div className="empty-copy">Grammar chapters are syncing…</div>}</div>
   </details>
  </section>

  <section className="pv-history-section" style={{order:4}}><h2>Grammar Daily History</h2><div className="pv-history-list">{history.length?history.map((h,i)=>{
   const pending=Math.max(0,h.generated-h.practised);
   const sub=h.complete?`${h.practised}/${h.generated} practiced · ${h.correct} correct${h.round2Focus?` · ${h.round2Focus} focus`:""}`:`${h.practised}/${h.generated} practiced · ${pending} left`;
   const title=`Grammar · ${h.label}`;
   const expectedCount=h.fromDay===h.toDay?h.generated:undefined;
   const resume=matchingSession(pausedGrammar,"grammarrevision",title,expectedCount);
   return <article className="pv-history-card" key={`${h.type}-${h.fromDay}-${h.date||i}`}><div><b>{h.label}</b><p>{sub}</p></div><div className="pv-history-side">{h.date&&<span>{shortDate(h.date)}</span>}<button className="btn soft mini" disabled={!h.generated} onClick={()=>setPick({kind:"history",fromDay:h.fromDay,toDay:h.toDay,label:title,resumeSession:resume})}>Review</button></div></article>;
  }):<div className="empty-copy">No Grammar Daily history yet.</div>}</div></section>
 </main>;
}

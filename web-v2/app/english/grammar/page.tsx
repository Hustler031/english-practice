"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Chapter={chapter:string;totalRules:number;coveredRules:number;coveragePercent:number;weakRules:number;dueRules:number;questionCount:number};
type Hub={
 ok:boolean;
 dailyTarget:number;
 stats:{totalRules:number;covered:number;coveragePercent:number;weak:number;due:number;mastered:number};
 today:{date:string;count:number;target:number;ready:boolean};
 available:{smart:number;weak:number;due:number;all:number};
 sizes:number[];
 chapters:Chapter[];
 readOnlyBrowsing:boolean;
};
type Pick={kind:"today"|"practice";label:string;mode?:"smart"|"weak"|"due"|"all";count?:number};
const modes=[["🧠","Smart Practice","smart"],["🔥","Weak","weak"],["◷","Due","due"],["▶","Practice All","all"]] as const;

export default function GrammarWorld(){
 const ready=useAuthGuard(),router=useRouter();
 const [hub,setHub]=useState<Hub|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pendingMode,setPendingMode]=useState<Pick["mode"]|null>(null);
 const [error,setError]=useState("");

 useEffect(()=>{
  if(!ready)return;
  let live=true;
  const accept=(x:Hub)=>{if(live){setHub(x);setError("");}};
  const off=subscribeRpcFresh<Hub>("english_get_grammar_hub",undefined,accept);
  rpc<Hub>("english_get_grammar_hub").then(accept).catch((e:any)=>live&&setError(learnerErrorMessage(e,"Grammar Intelligence is taking longer than usual. Please retry.")));
  return()=>{live=false;off();};
 },[ready]);

 const load=useCallback(()=>{
  if(!pick)return Promise.resolve([]);
  if(pick.kind==="today")return rpc<any>("english_get_grammar_today").then(x=>Array.isArray(x?.items)?x.items:[]);
  return rpc<any[]>("english_get_grammar_batch",{p_mode:pick.mode,p_count:pick.count||20,p_chapter:null});
 },[pick]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/grammar" load={load} module={pick.kind==="today"?"grammardaily":"grammarrevision"} onExit={()=>setPick(null)}/>;

 const s=hub?.stats,a=hub?.available,t=hub?.today,sizeChoices=hub?.sizes?.length?hub.sizes:[10,20,30,50];
 const start=(mode:NonNullable<Pick["mode"]>,count:number)=>setPick({kind:"practice",mode,count,label:`Grammar · ${modes.find(m=>m[2]===mode)?.[1]||mode}`});
 return <main className="phrasal-parity-page">
  <section className="pv-page-subhead"><button className="btn ghost" onClick={()=>window.history.length>1?router.back():router.push("/english")}>← Back</button><div><h1>Grammar</h1><p>Daily rules + adaptive SSC practice.</p></div></section>
  {error&&<div className="error-box">{error}</div>}

  <section className="pv-today-legacy" style={{order:1}}>
   <div className="pv-today-head"><div><h2>Today&apos;s {t?.count||hub?.dailyTarget||20}</h2><p>{t?.ready?`${t.count} permanent questions · ${t.date}`:"Today’s exact-20 Grammar batch has not been published yet."}</p></div><span className={`pv-ready-pill ${t?.ready?"ready":"pending"}`}>{t?.ready?"READY":"PENDING"}</span></div>
   <button className="btn primary pv-today-button" disabled={!t?.ready} onClick={()=>setPick({kind:"today",label:"Grammar · Today"})}>Practice Today&apos;s {t?.count||hub?.dailyTarget||20}</button>
  </section>

  <section className="section-block" style={{order:2}}>
   <details className="practice-more-details" open>
    <summary><span><b>Chapters</b><small>Open a chapter for focused practice and read-only question review</small></span></summary>
    <div className="practice-more-list">{hub?.chapters?.length?hub.chapters.map(ch=><Link href={`/english/grammar/chapter/${encodeURIComponent(ch.chapter)}`} key={ch.chapter}><span><b>{ch.chapter}</b><small>{ch.coveredRules}/{ch.totalRules} covered · {ch.weakRules} weak · {ch.dueRules} due · {ch.questionCount} questions</small></span></Link>):<div className="empty-copy">Grammar chapters are syncing…</div>}</div>
   </details>
  </section>

  <section className="pv-legacy-card" style={{order:3}}>
   <div className="pv-legacy-head"><div><h2>🧠 Grammar Intelligence</h2><p>Rule evidence · weak/due signals · progressive question variants.</p></div><span className="pv-concept-pill">{s?.totalRules??"—"} rules</span></div>
   <div className="pv-legacy-metrics">
    <div><b>{s?`${s.covered} / ${s.totalRules}`:"—"}</b><small>Covered</small></div>
    <div><b>{s?.due??"—"}</b><small>Due</small></div>
    <div><b>{s?.weak??"—"}</b><small>Weak</small></div>
    <div><b>{s?.mastered??"—"}</b><small>Mastered</small></div>
   </div>
   <div className="pv-legacy-actions">{modes.map(([icon,label,mode])=>{
    const n=Number(a?.[mode]||0),disabled=!a||n===0;
    return <button key={mode} className="pv-legacy-action" disabled={disabled} onClick={()=>setPendingMode(mode)}><span>{icon}</span><b>{label}{n?` (${n})`:""}</b></button>;
   })}</div>
   <div className="pv-cache-note">Grammar Intelligence updates from real practice evidence</div>
  </section>

  {pendingMode&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPendingMode(null)}}><section className="pv-picker-sheet" onMouseDown={e=>e.stopPropagation()}><h3>{modes.find(m=>m[2]===pendingMode)?.[1]||"Grammar Practice"} · choose questions</h3><div className="pv-picker-counts">{sizeChoices.map(n=><button key={n} onClick={()=>{start(pendingMode,n);setPendingMode(null)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPendingMode(null)}>Cancel</button></section></div>}
 </main>;
}

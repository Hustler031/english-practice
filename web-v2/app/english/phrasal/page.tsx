"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type HistoryRow={type:string;label:string;fromDay:number;toDay:number;generated:number;practised:number;date?:string};
type Hub={version:string;dailyTarget:number;stats:{totalConcepts:number;exposed:number;exposurePercent:number;due:number;weak:number;recallWeak:number;difficult:number;starred:number;mastered:number;freshVariantChecks:number;eligible:number};today:{date:string;count:number;target:number;ready:boolean;sourceId:string};available:{smart:number;weak:number;difficult:number;starred:number;random:number;all:number};sizes:number[];history:HistoryRow[]};
type Pick={kind:"mastery"|"today"|"history";label:string;mode?:string;count?:number;fromDay?:number;toDay?:number};
const modes=[["🧠","Smart Revision","smart"],["🔥","Weak","weak"],["⚡","Difficult","difficult"],["⭐","Starred","starred"],["🎲","Random","random"],["▶","Practice All","all"]] as const;

export default function PhrasalPage(){
 const ready=useAuthGuard(),router=useRouter();
 const [hub,setHub]=useState<Hub|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pendingMode,setPendingMode]=useState<string|null>(null);
 const [error,setError]=useState("");
 useEffect(()=>{if(ready)rpc<Hub>("english_get_phrasal_hub").then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>{if(!pick)return Promise.resolve([]);if(pick.kind==="today")return rpc<any[]>("english_get_phrasal_today");if(pick.kind==="history")return rpc<any[]>("english_get_phrasal_history_batch",{p_from_day:pick.fromDay,p_to_day:pick.toDay});return rpc<any[]>("english_get_phrasal_batch",{p_mode:pick.mode,p_count:pick.count||20});},[pick]);
 const history=useMemo(()=>{
  const rows=[...(hub?.history||[])];
  if(hub?.today?.ready&&hub.today.count>0&&!rows.some(h=>String(h.date||"")===String(hub.today.date||""))){
   rows.unshift({type:"today",label:"Today",fromDay:0,toDay:0,generated:hub.today.count,practised:0,date:hub.today.date});
  }
  return rows;
 },[hub]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/phrasal" load={load} module={pick.kind==="today"?"phrasaldaily":"phrasalrevision"} onExit={()=>setPick(null)}/>;
 const s=hub?.stats,a=hub?.available,t=hub?.today,sizeChoices=hub?.sizes?.length?hub.sizes:[10,20,30,50];
 const startMastery=(mode:string,count:number)=>setPick({kind:"mastery",mode,count,label:`Phrasal Verb · ${modes.find(m=>m[2]===mode)?.[1]||mode}`});
 return <div className="phrasal-parity-page">
  <section className="pv-page-subhead"><button className="btn ghost" onClick={()=>window.history.length>1?router.back():router.push("/english")}>← Back</button><div><h1>Phrasal Verb</h1><p>Smart revision + today&apos;s permanent batch.</p></div></section>
  {error&&<div className="error-box">{error}</div>}
  <section className="pv-legacy-card">
   <div className="pv-legacy-head"><div><h2>🧠 Smart Revision</h2><p>One concept per slot · central Weak/Due/Starred/Difficult signals.</p></div><span className="pv-concept-pill">{s?.totalConcepts??"—"} concepts</span></div>
   <div className="pv-legacy-metrics">
    <div><b>{s?`${s.exposed} / ${s.totalConcepts}`:"—"}</b><small>Bank Exposure</small></div>
    <div><b>{s?.due??"—"}</b><small>Due</small></div>
    <div><b>{s?.weak??"—"}</b><small>Weak</small></div>
    <div><b>{s?.mastered??"—"}</b><small>Mastered</small></div>
   </div>
   <div className="pv-legacy-actions">{modes.map(([icon,label,mode])=>{
    const n=Number(a?.[mode as keyof typeof a]||0),disabled=!a||n===0;
    return <button key={mode} className="pv-legacy-action" disabled={disabled} onClick={()=>mode==="all"?startMastery("all",100):setPendingMode(mode)}><span>{icon}</span><b>{label}{n?` (${n})`:""}</b></button>;
   })}</div>
   <div className="pv-cache-note">Cached first · refreshes silently in background</div>
  </section>

  <section className="pv-today-legacy">
   <div className="pv-today-head"><div><h2>Today&apos;s {t?.count||hub?.dailyTarget||20}</h2><p>{t?.ready?`${t.count} permanent questions · ${t.date}`:"Today’s permanent batch has not been added yet."}</p></div><span className={`pv-ready-pill ${t?.ready?"ready":"pending"}`}>{t?.ready?"READY":"PENDING"}</span></div>
   <button className="btn primary pv-today-button" disabled={!t?.ready} onClick={()=>setPick({kind:"today",label:"Phrasal Verb · Today"})}>Practice Today&apos;s {t?.count||hub?.dailyTarget||20}</button>
  </section>

  <section className="pv-history-section"><h2>Phrasal Daily History</h2><div className="pv-history-list">{history.length?history.map((h,i)=>{
   const isToday=h.type==="today"||h.label==="Today";
   return <article className="pv-history-card" key={`${h.type}-${h.fromDay}-${h.date||i}`}><div><b>{isToday?"Today":h.label}</b><p>{h.generated} generated · {h.practised} practised</p></div><div className="pv-history-side">{h.date&&<span>{h.date}</span>}<button className="btn soft mini" disabled={!h.generated} onClick={()=>isToday?setPick({kind:"today",label:"Phrasal Verb · Today"}):setPick({kind:"history",fromDay:h.fromDay,toDay:h.toDay,label:`Phrasal Verb · ${h.label}`})}>Practice</button></div></article>;
  }):<div className="empty-copy">No permanent Phrasal history yet.</div>}</div></section>

  {pendingMode&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPendingMode(null)}}><section className="pv-picker-sheet" onMouseDown={e=>e.stopPropagation()}><h3>{pendingMode==="smart"?"Smart Revision":`${pendingMode[0].toUpperCase()+pendingMode.slice(1)} · choose questions`}</h3><div className="pv-picker-counts">{sizeChoices.map(n=><button key={n} onClick={()=>{startMastery(pendingMode,n);setPendingMode(null)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPendingMode(null)}>Cancel</button></section></div>}
 </div>;
}

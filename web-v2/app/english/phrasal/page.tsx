"use client";

import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type HistoryRow={type:string;label:string;fromDay:number;toDay:number;generated:number;practised:number;date?:string};
type Hub={version:string;dailyTarget:number;stats:{totalConcepts:number;exposed:number;exposurePercent:number;due:number;weak:number;recallWeak:number;difficult:number;starred:number;mastered:number;freshVariantChecks:number;eligible:number};today:{date:string;count:number;target:number;ready:boolean;sourceId:string};available:{smart:number;weak:number;difficult:number;starred:number;random:number;all:number};sizes:number[];history:HistoryRow[]};
type Pick={kind:"mastery"|"today"|"history";label:string;mode?:string;count?:number;fromDay?:number;toDay?:number};
const modes=[["🧠","Smart Revision","smart"],["🔥","Weak","weak"],["⚡","Difficult","difficult"],["★","Starred","starred"],["🎲","Random","random"],["▶","Practice All","all"]] as const;

export default function PhrasalPage(){
 const ready=useAuthGuard();const [hub,setHub]=useState<Hub|null>(null);const [pick,setPick]=useState<Pick|null>(null);const [error,setError]=useState("");
 useEffect(()=>{if(ready)rpc<Hub>("english_get_phrasal_hub").then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>{if(!pick)return Promise.resolve([]);if(pick.kind==="today")return rpc<any[]>("english_get_phrasal_today");if(pick.kind==="history")return rpc<any[]>("english_get_phrasal_history_batch",{p_from_day:pick.fromDay,p_to_day:pick.toDay});return rpc<any[]>("english_get_phrasal_batch",{p_mode:pick.mode,p_count:pick.count||20});},[pick]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/phrasal" load={load} module={pick.kind==="today"?"phrasaldaily":"phrasalrevision"} onExit={()=>setPick(null)}/>;
 const s=hub?.stats,a=hub?.available;
 return <>
  <section className="page-intro"><h1>Phrasal Verb</h1><p>Concept-first Central Intelligence with recognition, reverse recall and confusion variants.</p></section>
  {error&&<div className="error-box">{error}</div>}
  <section className="revision-panel"><div className="revision-panel-head"><div><h2>Smart Revision</h2><p>One concept per slot; intelligence chooses priority, then the best least-exposed variant.</p></div><span className="pill">{s?.totalConcepts??"—"} concepts</span></div><div className="revision-metrics"><span><b>{s?.exposed??"—"}</b>Exposed</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.recallWeak??"—"}</b>Recall Weak</span><span><b>{s?.mastered??"—"}</b>Mastered</span></div><div className="action-matrix">{modes.map(([icon,label,mode])=><button key={mode} className="feature-card" disabled={!a||Number(a[mode as keyof typeof a]||0)===0} onClick={()=>setPick({kind:"mastery",mode,count:mode==="all"?100:20,label:`Phrasal Verb · ${label}`})}><b style={{fontSize:18}}>{icon}</b><span>{label}</span></button>)}</div></section>
  <section className="section-block"><h2 className="section-cap">Today&apos;s {hub?.today?.count||hub?.dailyTarget||20}</h2><button className="study-row accent-phrasal" disabled={!hub?.today?.ready} onClick={()=>setPick({kind:"today",label:"Phrasal Verb · Today"})}><span className="row-icon">↗</span><span className="row-copy"><b>{hub?.today?.ready?"Practice Today's Batch":"Today's Batch Pending"}</b><small>{hub?.today?.ready?`${hub.today.count} permanent questions · ${hub.today.date}`:"No permanent batch has been generated; nothing is invented."}</small></span><span className="row-status">{hub?.today?.ready?"READY":"PENDING"}</span><i>›</i></button></section>
  <section className="section-block"><h2 className="section-cap">Phrasal Daily History</h2><div className="study-list">{hub?.history?.length?hub.history.map((h,i)=><button className="study-row" key={`${h.type}-${h.fromDay}-${i}`} disabled={!h.generated} onClick={()=>setPick({kind:"history",fromDay:h.fromDay,toDay:h.toDay,label:`Phrasal Verb · ${h.label}`})}><span className="row-icon">↗</span><span className="row-copy"><b>{h.label}</b><small>{h.generated} generated · {h.practised} practised{h.date?` · ${h.date}`:""}</small></span><span className="row-status">{h.generated?"Practice":"—"}</span><i>›</i></button>):<div className="empty-copy">No permanent Phrasal history yet.</div>}</div></section>
 </>;
}

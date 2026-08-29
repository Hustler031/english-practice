"use client";

import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Stats={active:number;revised:number;neverRevised:number;revisedOnce:number;revisedMultiple:number;longOverdue:number;due:number;weak:number;persistentWeak:number;fragile:number;difficult:number;strong:number;learning:number};
type Hub={stats:Stats;available:{smart:number;notRevised:number;due:number;weak:number;difficult:number;longest:number;all:number};sizes:number[];history:{day:number;label:string;count:number}[]};
type Pick={mode:string;label:string;count:number;fromDay?:number;toDay?:number};
const modes=[["🧠","Smart Mix","smart"],["🆕","Not Revised","notRevised"],["⏰","Due Now","due"],["🔴","Weak Focus","weak"],["⚡","Difficult","difficult"],["🔄","Longest Not Revised","longest"]] as const;

export default function StarredPage(){
 const ready=useAuthGuard();const [hub,setHub]=useState<Hub|null>(null);const [pick,setPick]=useState<Pick|null>(null);const [error,setError]=useState("");const [size,setSize]=useState(20);
 useEffect(()=>{if(ready)rpc<Hub>("english_get_starred_hub",{p_from_day:null,p_to_day:null}).then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>pick?rpc<any[]>("english_get_starred_batch",{p_mode:pick.mode,p_count:pick.count,p_from_day:pick.fromDay??null,p_to_day:pick.toDay??null}):Promise.resolve([]),[pick]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/starred" load={load} module="starredRevision" onExit={()=>setPick(null)}/>;
 const s=hub?.stats,a=hub?.available,coverage=s?.active?Math.round(s.revised*1000/s.active)/10:0;
 return <>
  <section className="page-intro"><h1>⭐ Starred Intelligence</h1><p>Adaptive revision inside your current Central Starred bank only.</p></section>
  {error&&<div className="error-box">{error}</div>}
  <section className="revision-panel"><div className="revision-panel-head"><div><h2>Recommended Now</h2><p>Learning priority + coverage rotation, with manual Star intent preserved.</p></div><span className="pill">{s?.active??"—"} active</span></div><div className="revision-metrics"><span><b>{s?.neverRevised??"—"}</b>Never Revised</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.weak??"—"}</b>Weak</span><span><b>{s?.difficult??"—"}</b>Difficult</span></div><div className="row" style={{marginBottom:10}}>{[10,20,30,50].map(n=><button className={`btn ghost ${size===n?"warn":""}`} key={n} onClick={()=>setSize(n)}>{n}</button>)}</div><div className="action-matrix">{modes.map(([icon,label,mode])=><button key={mode} className="feature-card" disabled={!a||Number(a[mode as keyof typeof a]||0)===0} onClick={()=>setPick({mode:mode.toLowerCase(),label:`Starred · ${label}`,count:size})}><b style={{fontSize:18}}>{icon}</b><span>{label}</span></button>)}</div></section>
  <section className="section-block"><h2 className="section-cap">Starred Coverage</h2><article className="category-row"><div className="category-title"><b>Revised</b><span>{s?`${s.revised} / ${s.active}`:"—"}</span></div><div className="progress-track"><i style={{width:`${coverage}%`}}/></div><small>{coverage.toFixed(1)}% · {s?.revisedOnce??0} once · {s?.revisedMultiple??0} multiple · {s?.longOverdue??0} long overdue</small></article></section>
  <section className="section-block"><h2 className="section-cap">Day-wise Starred History</h2><div className="study-list">{hub?.history?.map(h=><button className="study-row" key={h.day} disabled={!h.count} onClick={()=>setPick({mode:"smart",label:`Starred · ${h.label}`,count:size,fromDay:h.day,toDay:h.day})}><span className="row-icon">★</span><span className="row-copy"><b>{h.label}</b><small>{h.count} currently Starred questions from this day</small></span><span className="row-status">Smart</span><i>›</i></button>)}</div></section>
 </>;
}

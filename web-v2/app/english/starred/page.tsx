"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Stats={active:number;revised:number;neverRevised:number;revisedOnce:number;revisedMultiple:number;longOverdue:number;due:number;weak:number;persistentWeak:number;fragile:number;difficult:number;strong:number;learning:number};
type History={day:number;label:string;count:number};
type Hub={currentDay?:number;stats:Stats;available:{smart:number;notRevised:number;due:number;weak:number;difficult:number;longest:number;all:number};sizes:number[];history:History[]};
type Pick={mode:string;label:string;count:number;fromDay?:number;toDay?:number};
type HistoryGroup={key:string;label:string;rows:History[];fromDay:number;toDay:number;type:"block"|"month"};
const modes=[["🧠","Smart Mix","smart"],["🆕","Not Revised","notRevised"],["⏰","Due Now","due"],["🔴","Weak Focus","weak"],["⚡","Difficult","difficult"],["🔄","Longest Not Revised","longest"]] as const;

export default function StarredPage(){
 const ready=useAuthGuard();const [hub,setHub]=useState<Hub|null>(null);const [pick,setPick]=useState<Pick|null>(null);const [error,setError]=useState("");const [size,setSize]=useState(20);const [smart,setSmart]=useState(false);const [openBlocks,setOpenBlocks]=useState<Set<string>>(new Set());
 useEffect(()=>{if(ready)rpc<Hub>("english_get_starred_hub",{p_from_day:null,p_to_day:null}).then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>pick?rpc<any[]>("english_get_starred_batch",{p_mode:pick.mode,p_count:pick.count,p_from_day:pick.fromDay??null,p_to_day:pick.toDay??null}):Promise.resolve([]),[pick]);
 const hierarchy=useMemo(()=>buildHierarchy(hub?.history||[],hub?.currentDay),[hub]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/starred" load={load} module="starredRevision" onExit={()=>setPick(null)}/>;
 const s=hub?.stats,a=hub?.available,coverage=s?.active?Math.round(s.revised*1000/s.active)/10:0;
 const toggleBlock=(key:string)=>setOpenBlocks(x=>{const n=new Set(x);n.has(key)?n.delete(key):n.add(key);return n;});
 return <>
  <section className="page-intro"><h1>⭐ Starred Revision</h1><p>Manual starred revision, organised by the day you marked it.</p></section>
  {error&&<div className="error-box">{error}</div>}
  {!smart?<><section className="revision-panel"><div className="revision-panel-head"><div><h2>Starred Collection</h2><p>Your manually marked questions. Open Smart Intelligence only when you want adaptive selection.</p></div><span className="pill">{s?.active??"—"} active</span></div><div className="row" style={{marginTop:12}}><button className="btn primary" onClick={()=>setPick({mode:"all",label:"Starred Revision",count:100})}>Practice All</button><button className="btn soft" onClick={()=>setSmart(true)}>🧠 Smart / Intelligence</button></div></section><section className="section-block"><h2 className="section-cap">Starred History</h2><StarredDays rows={hierarchy.current} size={size} onPick={setPick}/><HistoryGroups groups={hierarchy.groups} size={size} openBlocks={openBlocks} toggleBlock={toggleBlock} onPick={setPick}/></section></>:<><section className="revision-panel"><div className="revision-panel-head"><div><h2>Recommended Now</h2><p>Learning priority + coverage rotation, with manual Star intent preserved.</p></div><button className="btn ghost compact-add" onClick={()=>setSmart(false)}>← Starred</button></div><div className="revision-metrics"><span><b>{s?.neverRevised??"—"}</b>Never Revised</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.weak??"—"}</b>Weak</span><span><b>{s?.difficult??"—"}</b>Difficult</span></div><div className="row" style={{marginBottom:2}}>{[10,20,30,50].map(n=><button className={`btn ghost ${size===n?"warn":""}`} key={n} onClick={()=>setSize(n)}>{n}</button>)}</div></section>
  <section className="section-block starred-intelligence-folds">
   <details className="intel-fold" open><summary><span>Starred Coverage</span><b>{s?`${s.revised} / ${s.active}`:"—"}</b></summary><div className="intel-fold-body"><div className="progress-track green"><i style={{width:`${coverage}%`}}/></div><p>{coverage.toFixed(1)}% revised · {s?.revisedOnce??0} once · {s?.revisedMultiple??0} multiple</p></div></details>
   <details className="intel-fold"><summary><span>Learning Health</span><b>{s?.persistentWeak??0} persistent weak</b></summary><div className="intel-grid"><span><b>{s?.persistentWeak??"—"}</b>Persistent Weak</span><span><b>{s?.weak??"—"}</b>Weak total</span><span><b>{s?.fragile??"—"}</b>Fragile</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.difficult??"—"}</b>Difficult</span><span><b>{s?.strong??"—"}</b>Strong</span><span><b>{s?.learning??"—"}</b>Learning / New</span></div></details>
   <details className="intel-fold" open><summary><span>Smart Practice</span><b>{size} questions</b></summary><div className="intel-fold-body"><div className="action-matrix">{modes.map(([icon,label,mode])=><button key={mode} className="feature-card" disabled={!a||Number(a[mode as keyof typeof a]||0)===0} onClick={()=>setPick({mode:mode.toLowerCase(),label:`Starred · ${label}`,count:size})}><b>{icon}</b><span>{label}</span></button>)}</div></div></details>
   <details className="intel-fold"><summary><span>Rotation Health</span><b>{s?.neverRevised??0} not revised</b></summary><div className="intel-grid"><span><b>{s?.neverRevised??"—"}</b>Never Revised</span><span><b>{s?.revisedOnce??"—"}</b>Revised Once</span><span><b>{s?.revisedMultiple??"—"}</b>Revised Multiple</span><span><b>{s?.longOverdue??"—"}</b>Long Overdue</span></div></details>
   <details className="intel-fold"><summary><span>Day-wise Intelligence</span><b>Day {hub?.currentDay??"—"}</b></summary><div className="intel-fold-body"><StarredDays rows={hierarchy.current} size={size} onPick={setPick}/><HistoryGroups groups={hierarchy.groups} size={size} openBlocks={openBlocks} toggleBlock={toggleBlock} onPick={setPick}/></div></details>
  </section></>}
 </>;
}

function buildHierarchy(history:History[],reportedCurrentDay?:number){
 const sorted=[...history].sort((a,b)=>b.day-a.day);const maxDay=sorted[0]?.day||1;const currentDay=Math.max(1,Number(reportedCurrentDay||maxDay));const currentMonth=Math.floor((currentDay-1)/30)+1;const currentMonthStart=(currentMonth-1)*30+1;const currentBlockStart=Math.floor((currentDay-1)/10)*10+1;
 const current=sorted.filter(h=>h.day>=currentBlockStart&&h.day<=currentDay);const groups:HistoryGroup[]=[];
 for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=start+9;const rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`block-${start}`,label:`Days ${start}–${end}`,rows,fromDay:start,toDay:end,type:"block"});}
 for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30;const rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`month-${month}`,label:`Month ${month} · Days ${start}–${end}`,rows,fromDay:start,toDay:end,type:"month"});}
 return {currentDay,current,groups};
}
function HistoryGroups({groups,size,openBlocks,toggleBlock,onPick}:{groups:HistoryGroup[];size:number;openBlocks:Set<string>;toggleBlock:(key:string)=>void;onPick:(p:Pick)=>void}){return <>{groups.map(group=>{const isOpen=openBlocks.has(group.key);const count=group.rows.reduce((n,row)=>n+row.count,0);return <article className="history-fold" key={group.key}><button className="history-fold-head" onClick={()=>toggleBlock(group.key)}><span><b>{group.label}</b><small>{count} currently starred questions</small></span><span>{isOpen?"⌄":"›"}</span></button>{isOpen&&<StarredDays rows={group.rows} size={size} onPick={onPick}/>}</article>})}</>}
function StarredDays({rows,size,onPick}:{rows:History[];size:number;onPick:(p:Pick)=>void}){return <div className="study-list">{rows.map(h=><button className="study-row" key={h.day} disabled={!h.count} onClick={()=>onPick({mode:"smart",label:`Starred · ${h.label}`,count:size,fromDay:h.day,toDay:h.day})}><span className="row-icon">★</span><span className="row-copy"><b>{h.label}</b><small>{h.count} currently starred questions</small></span><span className="row-status">{h.count}</span><i>›</i></button>)}</div>}

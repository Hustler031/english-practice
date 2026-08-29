"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { EnglishLoading } from "@/components/english-frame";

type Saved={id:string;word:string;meaning:string;context:string;status:string;practiceQuestionId:string;gptStatus:string;captureType:string;resolvedType:string;created:string};
type Stats={saved:number;eligible:number;controlledNew:number;neverRevised:number;due:number;weak:number;difficult:number;starred:number;mastered:number};
type History={date:string|null;label:string;saved:number;eligible:number;controlledNew:number;due:number;weak:number;difficult:number;mastered:number};
type Hub={stats:Stats;available:{smart:number;weak:number;difficult:number;starred:number;random:number;all:number};sizes:number[];history:History[]};
type Pick={mode:string;label:string;date?:string|null;count:number};
const types=["AUTO","V","SM","OWS","PV","IP"];
const modes=[["🧠","Smart Revision","smart"],["🔥","Weak","weak"],["⚡","Difficult","difficult"],["★","Starred","starred"],["🎲","Random","random"],["▶","Practice All","all"]] as const;

export default function SavedPage(){
 const ready=useAuthGuard();const [hub,setHub]=useState<Hub|null>(null);const [pick,setPick]=useState<Pick|null>(null);const [manage,setManage]=useState(false);const [rows,setRows]=useState<Saved[]>([]);const [word,setWord]=useState("");const [context,setContext]=useState("");const [type,setType]=useState("AUTO");const [error,setError]=useState("");
 async function refreshHub(){setHub(await rpc<Hub>("english_get_saved_revision_hub"));}
 async function refreshRows(){setRows(await rpc<Saved[]>("english_get_saved_items"));}
 useEffect(()=>{if(ready)refreshHub().catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>{if(!pick)return Promise.resolve([]);if(pick.date)return rpc<any[]>("english_get_saved_history_batch",{p_date:pick.date,p_mode:pick.mode,p_count:pick.count});return rpc<any[]>("english_get_saved_revision_batch",{p_mode:pick.mode,p_count:pick.count});},[pick]);
 async function openManage(){setManage(true);if(!rows.length)try{await refreshRows();}catch(e:any){setError(e.message);}}
 async function add(event:FormEvent){event.preventDefault();setError("");try{await rpc("english_save_word",{p_word:word,p_context:context,p_capture_type:type,p_module:"web-v2",p_source:"Manual capture"});setWord("");setContext("");setType("AUTO");await Promise.all([refreshRows(),refreshHub()]);}catch(e:any){setError(e.message);}}
 async function changeType(id:string,next:string){setRows(a=>a.map(x=>x.id===id?{...x,captureType:next}:x));try{await rpc("english_set_saved_item_type",{p_saved_id:id,p_capture_type:next});await refreshRows();}catch(e:any){setError(e.message);await refreshRows();}}
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/saved" load={load} module="mySavedRevision" onExit={()=>setPick(null)}/>;
 const s=hub?.stats,a=hub?.available;
 return <>
  <section className="page-intro"><h1>My Saved Words</h1><p>Personal revision organised by your central learning intelligence.</p></section>
  {error&&<div className="error-box">{error}</div>}
  <section className="revision-panel"><div className="revision-panel-head"><div><h2>Smart Revision</h2><p>Controlled new + due/weak learning priority + coverage rotation.</p></div></div><div className="revision-metrics"><span><b>{s?.saved??"—"}</b>Saved</span><span><b>{s?.neverRevised??"—"}</b>Never Revised</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.mastered??"—"}</b>Mastered</span></div><div className="action-matrix">{modes.map(([icon,label,mode])=><button key={mode} className="feature-card" disabled={!a||Number(a[mode as keyof typeof a]||0)===0} onClick={()=>setPick({mode,label:`My Saved · ${label}`,count:mode==="all"?100:20})}><b style={{fontSize:18}}>{icon}</b><span>{label}</span></button>)}</div></section>
  <section className="section-block"><div className="section-title-line"><h2>Saved History</h2><button className="btn soft compact-add" onClick={openManage}>Manage Saved Words</button></div><div className="study-list">{hub?.history?.length?hub.history.map((h,i)=><button className="study-row" key={`${h.date||"imported"}-${i}`} disabled={!h.date||!h.eligible} onClick={()=>h.date&&setPick({mode:"all",date:h.date,label:`My Saved · ${h.label}`,count:100})}><span className="row-icon">🔖</span><span className="row-copy"><b>{h.label}</b><small>{h.saved} saved · {h.due} due · {h.weak} weak · {h.difficult} difficult</small></span><span className="row-status">{h.mastered} mastered</span><i>›</i></button>):<div className="empty-copy">No enriched saved words are in practice yet.</div>}</div></section>
  {manage&&<section className="section-block"><div className="section-title-line"><h2>Manage Saved Words</h2><button className="btn ghost compact-add" onClick={()=>setManage(false)}>Close</button></div><form className="card stack" onSubmit={add}><input className="input" value={word} onChange={e=>setWord(e.target.value)} placeholder="Word / doubt / usage point" required/><input className="input" value={context} onChange={e=>setContext(e.target.value)} placeholder="Context (optional)"/><div className="capture-types">{types.map(item=><button type="button" key={item} className={`capture-type ${type===item?"selected":""}`} onClick={()=>setType(item)}>{item==="IP"?"I/P":item}</button>)}<span className="spacer"/><button className="btn primary">Save</button></div></form><div className="study-list" style={{marginTop:10}}>{rows.map(item=><article className="saved-row" key={item.id}><div><b>{item.word}</b><small>{item.meaning||item.context||"Pending enrichment"}</small></div><span className="pill">{item.gptStatus}</span><div className="capture-types">{types.map(next=><button key={next} className={`capture-type ${item.captureType===next?"selected":""}`} onClick={()=>changeType(item.id,next)}>{next==="IP"?"I/P":next}</button>)}</div></article>)}</div></section>}
 </>;
}

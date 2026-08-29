"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Hub={due:number;weak:number;persistentWeak:number;difficult:number;starred:number;seenBefore:number;mastered:number;learning:number};
type Pick={mode:"due"|"weak"|"recall"|"difficult";label:string};
const attention=[["⏰","Due Today","Central spaced-review clock is due","due"],["🔥","Weak / Wrong","Persistent Weak → Weak → Fragile","weak"],["★","Starred Revision","Adaptive revision inside your Central Starred bank","starred"],["⚡","Difficult","Questions you manually marked difficult anywhere","difficult"],["↺","Seen Before / Recall","Rotate previously encountered questions","recall"]] as const;

export default function RevisionHome(){
 const ready=useAuthGuard();const [hub,setHub]=useState<Hub|null>(null);const [pick,setPick]=useState<Pick|null>(null);const [error,setError]=useState("");
 useEffect(()=>{if(ready)rpc<Hub>("english_get_revision_hub").then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>pick?rpc<any[]>("english_get_revision_batch",{p_mode:pick.mode,p_count:30}):Promise.resolve([]),[pick]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/revision" load={load} module="revision" onExit={()=>setPick(null)}/>;
 const count=(id:string)=>id==="due"?hub?.due:id==="weak"?hub?.weak:id==="starred"?hub?.starred:id==="difficult"?hub?.difficult:hub?.seenBefore;
 return <>
  <section className="page-intro"><h1>Revision</h1><p>Central Intelligence decides what needs attention; each module keeps its own candidate pool.</p></section>
  {error&&<div className="error-box">{error}</div>}
  <section className="section-block" style={{marginTop:0}}><h2 className="section-cap">Needs Attention</h2><div className="study-list">{attention.map(([icon,title,sub,id])=>id==="starred"?<Link className="study-row accent-starred" href="/english/starred" key={id}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">{count(id)??"—"}</span><i>›</i></Link>:<button className="study-row" key={id} disabled={!count(id)} onClick={()=>setPick({mode:id as Pick["mode"],label:title})}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><span className="row-status">{count(id)??"—"}</span><i>›</i></button>)}</div></section>
  <section className="section-block"><h2 className="section-cap">Personal Revision</h2><div className="study-list"><Link className="study-row accent-saved" href="/english/saved"><span className="row-icon">🔖</span><span className="row-copy"><b>My Saved Words</b><small>Smart / Weak / Difficult / Starred / Random / Practice All</small></span><i>›</i></Link><Link className="study-row accent-phrasal" href="/english/phrasal"><span className="row-icon">↗</span><span className="row-copy"><b>Phrasal Verb</b><small>Central intelligence + recognition / recall / confusion variants</small></span><i>›</i></Link></div></section>
  <section className="section-block"><h2 className="section-cap">Learning State</h2><div className="compact-metrics"><div><b>{hub?.due??"—"}</b><span>Due</span></div><div><b>{hub?.persistentWeak??"—"}</b><span>Persistent Weak</span></div><div><b>{hub?.difficult??"—"}</b><span>Difficult</span></div><div><b>{hub?.mastered??"—"}</b><span>Mastered</span></div></div></section>
 </>;
}

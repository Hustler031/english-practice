"use client";

import Link from "next/link";
import { useCallback,useEffect,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Hub={due:number;weak:number;persistentWeak:number;difficult:number;starred:number;seenBefore:number;mastered:number;learning:number};
type Pick={mode:"due";label:string;count:number};
type Pending={mode:"due";label:string;available:number};

export default function RevisionHome(){
 const ready=useAuthGuard();
 const[hub,setHub]=useState<Hub|null>(null);
 const[pick,setPick]=useState<Pick|null>(null);
 const[pending,setPending]=useState<Pending|null>(null);
 const[error,setError]=useState("");
 useEffect(()=>{if(!ready)return;rpc<Hub>("english_get_revision_hub").then(setHub).catch((e:any)=>setError(learnerErrorMessage(e,"Could not load Revision.")))},[ready]);
 const load=useCallback(()=>pick?rpc<any[]>("english_get_revision_batch",{p_mode:pick.mode,p_count:pick.count}):Promise.resolve([]),[pick]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/revision" load={load} module="revision" onExit={()=>setPick(null)}/>;
 const openDue=()=>hub?.due&&setPending({mode:"due",label:"Due Now",available:hub.due});
 return <main className="top-level-parity revision-clean-page">
  <section className="page-intro learner-page-header"><h1>Revision</h1><p>Return to what is worth remembering now.</p></section>
  {error&&<div className="error-box">{error}</div>}
  <section className="revision-primary-list">
   <button className="revision-primary-row tone-due" type="button" disabled={!hub?.due} onClick={openDue}><span className="revision-row-icon">◷</span><span><b>Due Now</b><small>Spaced revision ready today</small></span><strong>{hub?.due??"—"}</strong></button>
   <Link className="revision-primary-row tone-repair" href="/english/revision/difficult-incorrect"><span className="revision-row-icon">!</span><span><b>Difficult &amp; Incorrect</b><small>{hub?`${hub.weak} weak / incorrect · ${hub.difficult} difficult`:"Recent mistakes and manually difficult items"}</small></span></Link>
   <Link className="revision-primary-row tone-star" href="/english/starred"><span className="revision-row-icon">★</span><span><b>Starred</b><small>Items you want to revisit</small></span><strong>{hub?.starred??"—"}</strong></Link>
   <Link className="revision-primary-row tone-saved" href="/english/saved"><span className="revision-row-icon">▣</span><span><b>My Saved</b><small>Your personal words and learning collection</small></span></Link>
   <Link className="revision-primary-row tone-topic" href="/english/topics"><span className="revision-row-icon">▦</span><span><b>Browse by Topic</b><small>Open a topic when you want deliberate revision</small></span></Link>
   <Link className="revision-primary-row tone-insights" href="/english/revision/ai-intelligence"><span className="revision-row-icon">◌</span><span><b>Learning Insights</b><small>What needs attention, what is improving, and what is scheduled later</small></span></Link>
  </section>
  {pending&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPending(null)}}><div className="legacy-sheet"><h3>{pending.label}</h3><div className="legacy-muted">{pending.available} available · how many questions?</div><div className="legacy-counts">{[10,20,30,50].map(n=><button key={n} onClick={()=>{setPick({mode:"due",label:pending.label,count:n});setPending(null)}}>{n}</button>)}</div><button className="btn ghost full-width" style={{marginTop:12}} onClick={()=>setPending(null)}>Cancel</button></div></div>}
 </main>;
}

"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { readPausedQuiz, type PausedQuizSession } from "@/lib/quiz-session";

type Mode="smart"|"weak"|"due"|"all";
type Hub={available:{smart:number;weak:number;due:number;all:number};sizes:number[]};
type Pick={mode:Mode;count:number;label:string;resumeSession?:PausedQuizSession|null};
const modes=[["🧠","Smart Practice","Adaptive mix from current Grammar evidence","smart"],["🔥","Weak","Repair rules with recent failures","weak"],["◷","Due","Rules whose review time has arrived","due"],["▶","Practice All","Broad practice across the Grammar bank","all"]] as const;

function firstUnanswered(session:PausedQuizSession|null){
 if(!session)return null;
 const answers=session.answers||{};
 const rows=session.questions as Array<{id?:string}>;
 const next=rows.findIndex(row=>{const id=String(row?.id||"");return !!id&&!answers[id];});
 return {...session,index:next>=0?next:Math.max(0,Math.min(session.index||0,rows.length-1))};
}
function matchingSession(session:PausedQuizSession|null,title:string,count:number){
 if(!session||session.module!=="grammarrevision"||session.backHref!=="/english/grammar/practice"||session.title!==title)return null;
 if(session.questions.length!==count)return null;
 return firstUnanswered(session);
}

export default function GrammarPractice(){
 const ready=useAuthGuard(),router=useRouter();
 const [hub,setHub]=useState<Hub|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pendingMode,setPendingMode]=useState<Mode|null>(null);
 const [paused,setPaused]=useState<PausedQuizSession|null>(null);
 const [error,setError]=useState("");

 useEffect(()=>{
  if(!ready)return;
  let live=true;
  const accept=(x:Hub)=>{if(live){setHub(x);setError("");}};
  const off=subscribeRpcFresh<Hub>("english_get_grammar_hub",undefined,accept);
  rpc<Hub>("english_get_grammar_hub").then(accept).catch((e:any)=>live&&setError(learnerErrorMessage(e,"Grammar practice is taking longer than usual. Please retry.")));
  setPaused(firstUnanswered(readPausedQuiz()));
  return()=>{live=false;off();};
 },[ready]);

 const load=useCallback(()=>{
  if(!pick)return Promise.resolve([]);
  return rpc<any[]>("english_get_grammar_batch",{p_mode:pick.mode,p_count:pick.count,p_chapter:null});
 },[pick]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/grammar/practice" load={load} module="grammarrevision" resumeSession={pick.resumeSession||null} onExit={()=>{setPick(null);window.setTimeout(()=>setPaused(firstUnanswered(readPausedQuiz())),0)}}/>;

 const a=hub?.available,sizeChoices=hub?.sizes?.length?hub.sizes:[10,20,30,50];
 const start=(mode:Mode,count:number)=>{
  const title=`Grammar · ${modes.find(m=>m[3]===mode)?.[1]||mode}`;
  setPick({mode,count,label:title,resumeSession:matchingSession(paused,title,count)});
  setPendingMode(null);
 };

 return <main className="phrasal-parity-page">
  <section className="pv-page-subhead"><button className="btn ghost" onClick={()=>router.push("/english/grammar")}>← Back</button><div><h1>Grammar Practice</h1><p>Choose one focused practice mode.</p></div></section>
  {error&&<div className="error-box">{error}</div>}

  <section className="pv-legacy-card">
   <div className="pv-legacy-head"><div><h2>Practice</h2><p>Smart, Weak, Due and full-bank practice stay separate from Daily.</p></div></div>
   <div className="pv-legacy-actions">{modes.map(([icon,label,sub,mode])=>{
    const n=Number(a?.[mode as keyof typeof a]||0),disabled=!a||n===0;
    return <button key={mode} className="pv-legacy-action" disabled={disabled} onClick={()=>setPendingMode(mode)}><span>{icon}</span><b>{label}{n?` (${n})`:""}</b><small>{sub}</small></button>;
   })}</div>
   <div className="pv-cache-note">Daily completion rules do not block these practice modes.</div>
  </section>

  {pendingMode&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPendingMode(null)}}><section className="pv-picker-sheet" onMouseDown={e=>e.stopPropagation()}><h3>{modes.find(m=>m[3]===pendingMode)?.[1]||"Grammar Practice"} · choose questions</h3><div className="pv-picker-counts">{sizeChoices.map(n=><button key={n} onClick={()=>start(pendingMode,n)}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPendingMode(null)}>Cancel</button></section></div>}
 </main>;
}

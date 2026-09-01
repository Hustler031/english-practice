"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { gkRpc, subscribeGkFresh } from "@/lib/gk-rpc";
import { useAuthGuard } from "@/lib/use-auth";
import { readGkPaused, type GkPausedSession } from "@/lib/gk-session";
import type { GkHomeSnapshot } from "@/lib/gk-types";

const n=(value:unknown)=>Number(value||0);
const quiz=(params:Record<string,string|number>)=>`/gk/quiz?${new URLSearchParams(Object.entries(params).map(([key,value])=>[key,String(value)]))}`;

type QuickItem={icon:string;title:string;copy:string;href:string;status:string;accent:string};

function QuickRow({item}:{item:QuickItem}){
 return <Link className={`gk-v2-quick-row ${item.accent}`} href={item.href}>
  <span className="gk-v2-quick-icon">{item.icon}</span>
  <span className="gk-v2-quick-copy"><b>{item.title}</b><small>{item.copy}</small></span>
  <span className="gk-v2-quick-status">{item.status}</span><i>›</i>
 </Link>;
}

export default function GkHomeV2(){
 const ready=useAuthGuard();
 const[data,setData]=useState<GkHomeSnapshot|null>(null);
 const[paused,setPaused]=useState<GkPausedSession|null>(null);
 const[error,setError]=useState("");

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  const accept=(next:GkHomeSnapshot)=>{if(alive){setData(next);setError("");}};
  const unsubscribe=subscribeGkFresh<GkHomeSnapshot>("gk_get_home_snapshot",undefined,accept);
  gkRpc<GkHomeSnapshot>("gk_get_home_snapshot").then(accept).catch((e:unknown)=>{if(alive)setError(e instanceof Error?e.message:String(e));});
  const refreshPaused=()=>{if(alive)setPaused(readGkPaused());};
  refreshPaused();
  window.addEventListener("storage",refreshPaused);
  return()=>{alive=false;unsubscribe();window.removeEventListener("storage",refreshPaused);};
 },[ready]);

 if(!ready)return <main className="gk-v2-route-loading"><div className="loading-copy">Checking GK session…</div></main>;
 if(!data&&!error)return <main className="gk-v2-route-loading"><div className="loading-copy">Loading GK home…</div></main>;
 if(!data)return <main className="gk-v2-home"><div className="error-box">{error||"GK home could not load."}</div></main>;

 const s=data.summary;
 const weak=n(s.persistentWeak)+n(s.weak)+n(s.fragile);
 const exposure=Math.max(0,Math.min(100,n(s.bankExposure)));
 const retention=Math.max(0,Math.min(100,n(s.retentionAccuracy)));
 const remote=data.resume;
 const resume=paused?{
  href:"/gk/quiz?resume=1",
  eyebrow:"Resume paused practice",
  title:paused.title||"GK Practice",
  copy:`Question ${paused.index+1} of ${paused.questions.length}`
 }:remote?{
  href:"/gk/quiz?remoteResume=1",
  eyebrow:"Resume server session",
  title:remote.title||"GK Practice",
  copy:"Your incomplete session is safely saved"
 }:null;
 const quick:QuickItem[]=[
  {icon:"▦",title:"Teacher PYQ",copy:"Topic-wise + Mixed PYQ · canonical learning history",href:"/gk/teacher",status:"Primary",accent:"accent-teacher"},
  {icon:"📰",title:"Current Affairs",copy:"Freshness filters + smart revision",href:"/gk?tab=content&view=ca",status:"Open",accent:"accent-ca"},
  {icon:"★",title:"Starred Revision",copy:"Marked knowledge · weak · due · difficult",href:"/gk?tab=practice&view=starred",status:`${n(s.starred)} focus`,accent:"accent-star"},
  {icon:"✦",title:"New Practice",copy:"Genuinely unexposed active questions only",href:"/gk?tab=practice&view=new",status:`${n(s.newQuestions)} new`,accent:"accent-new"},
  {icon:"▤",title:"Content Library",copy:"Lectures, subjects, Rapid Recall and source lanes",href:"/gk?tab=content",status:`${n(s.exposed)} seen`,accent:"accent-content"},
 ];

 return <main className="gk-v2-home">
  {error&&<div className="error-box">{error}</div>}
  <section className="gk-v2-daily-card">
   <div className="gk-v2-daily-top">
    <div className="gk-v2-daily-copy"><span className="gk-v2-eyebrow">Daily Revision</span><h1>{n(s.due)>0?`${n(s.due)} ready for recall`:"Today’s GK practice is ready"}</h1><p>Weak, due and controlled-new questions from your existing learning history.</p></div>
    <div className="gk-v2-daily-side"><strong>{retention}% <small>retention</small></strong><Link className="gk-v2-primary" href={quiz({source:"daily",mode:"daily",lane:"MIXED",count:20,title:"Daily Revision"})}>Start Daily</Link></div>
   </div>
   <div className="gk-v2-daily-meta"><span>Bank exposure</span><b>{exposure}%</b></div><div className="gk-v2-progress"><i style={{width:`${exposure}%`}}/></div>
  </section>

  {resume&&<Link className="gk-v2-resume" href={resume.href}><span><small>{resume.eyebrow}</small><b>{resume.title}</b><em>{resume.copy}</em></span><i>›</i></Link>}

  <section className="gk-v2-exam-row"><Link href="/gk/sprint"><span><b>EXAM PREPARATION</b><small>SSC Sprint · Repair → Retest → Retention</small></span><i>›</i></Link></section>

  <section className="gk-v2-section"><div className="gk-v2-section-title"><h2>Quick Start</h2></div><div className="gk-v2-quick-list">{quick.map(item=><QuickRow key={item.href} item={item}/>)}</div></section>

  <section className="gk-v2-section gk-v2-focus-section"><div className="gk-v2-section-title"><h2>Focus Queues</h2><span>Evidence-driven</span></div><div className="gk-v2-focus-grid">
   <Link href={quiz({mode:"weak",lane:"MIXED",count:20,title:"Weak Knowledge"})}><b>{weak}</b><span>Weak / PW</span></Link>
   <Link href={quiz({mode:"difficult",lane:"MIXED",count:20,title:"Difficult"})}><b>{n(s.difficult)}</b><span>Difficult</span></Link>
   <Link href="/gk?tab=practice&view=guessed"><b>{n(s.guessed)}</b><span>Guessed</span></Link>
   <Link href={quiz({mode:"recall_check",lane:"MIXED",count:20,title:"Recall Check"})}><b>{n(s.strong)+n(s.provenMastered)}</b><span>Recall check</span></Link>
  </div></section>
 </main>;
}

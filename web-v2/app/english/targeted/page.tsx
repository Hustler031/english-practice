"use client";

import Link from "next/link";
import { useCallback,useEffect,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary={active:number;dueNow:number;confusions:number;needLearning:number;transferChecks:number;retentionChecks:number;recovered:number};
type Confusion={confusionId:string;status:string;strength:number;primaryName:string;relatedName:string;note?:string;lastSignalAt:string};
type FocusRow={questionId:string;conceptId?:string;name:string;skillFamily?:string;state?:string;confidence?:number;reason?:string;nextReview?:string};
type Recovered={concept_id?:string;conceptId?:string;name:string;at:string;source:string};
type Hub={ok:boolean;summary:Summary;confusions:Confusion[];needLearning:FocusRow[];transferChecks:FocusRow[];retentionChecks:FocusRow[];recovered:Recovered[]};
type Practice={title:string;kind?:"confusion"|"need_learning"|"transfer_check"|"retention_check";confusionId?:string;nonce:string};

const freshNonce=()=>`${Date.now()}-${Math.random().toString(36).slice(2,9)}`;
const stateLabel=(value?:string)=>String(value||"learning").replaceAll("_"," ");

export default function TargetedMasteryPage(){
 const ready=useAuthGuard();
 const[hub,setHub]=useState<Hub|null>(null);
 const[practice,setPractice]=useState<Practice|null>(null);
 const[error,setError]=useState("");
 const[loading,setLoading]=useState(true);

 const refresh=useCallback(async()=>{
  setError("");
  try{setHub(await rpc<Hub>("english_get_targeted_mastery"));}
  catch(e:any){setError(learnerErrorMessage(e,"Could not load Targeted Mastery."));}
  finally{setLoading(false);}
 },[]);
 useEffect(()=>{if(ready)void refresh()},[ready,refresh]);

 const load=useCallback(()=>{
  if(!practice)return Promise.resolve([]);
  return rpc<any[]>("english_get_targeted_session",{
   p_count:15,
   p_kind:practice.kind??null,
   p_confusion_id:practice.confusionId??null,
   p_session_nonce:practice.nonce,
  });
 },[practice]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(practice)return <QuizRunner title={practice.title} backHref="/english/targeted" load={load} module="targeted" onExit={()=>{setPractice(null);void refresh()}} onFinish={refresh}/>;
 const s=hub?.summary;
 const start=(title:string,kind?:Practice["kind"],confusionId?:string)=>setPractice({title,kind,confusionId,nonce:freshNonce()});

 return <main className="top-level-parity targeted-mastery-page">
  <section className="page-intro targeted-intro">
   <Link href="/english/revision" className="back-link">← Revision</Link>
   <span className="intelligence-kicker">Central Intelligence</span>
   <h1>Targeted Mastery</h1>
   <p>Focused repair from real evidence: confusion, guessed confidence, concept gaps and retention checks.</p>
  </section>
  {error&&<div className="error-box">{error}</div>}
  {loading?<EnglishLoading text="Ranking focused repair…"/>:<>
   <section className="targeted-overview">
    <div><small>Active concept repairs</small><strong>{s?.active??0}</strong><span>{s?.dueNow??0} ready now</span></div>
    <button className="btn primary" disabled={!s?.active} onClick={()=>start("Targeted Mastery")}>Start focused set</button>
   </section>
   <div className="targeted-kpis">
    <TargetMetric label="My Confusions" value={s?.confusions??0}/>
    <TargetMetric label="Need Learning" value={s?.needLearning??0}/>
    <TargetMetric label="Transfer Checks" value={s?.transferChecks??0}/>
    <TargetMetric label="Retention" value={s?.retentionChecks??0}/>
   </div>

   <section className="section-block targeted-section">
    <div className="section-title-line"><div><h2>My Confusions</h2><p className="muted">Things you explicitly said you mix up.</p></div>{(s?.confusions??0)>0&&<button className="btn ghost compact-btn" onClick={()=>start("My Confusions","confusion")}>Practice</button>}</div>
    {hub?.confusions?.length?<div className="targeted-list">{hub.confusions.map(c=><div className="targeted-row" key={c.confusionId}><div className="targeted-row-copy"><b>{c.primaryName} <span>↔</span> {c.relatedName}</b>{c.note&&<small>“{c.note}”</small>}<em>{stateLabel(c.status)} · signal strength {c.strength}</em></div><button className="targeted-row-action" onClick={()=>start(`${c.primaryName} ↔ ${c.relatedName}`,"confusion",c.confusionId)}>Start ›</button></div>)}</div>:<EmptyCopy text="No unresolved confusion pairs right now."/>}
   </section>

   <TargetSection title="Need Learning" subtitle="Concepts with evidence of a real learning gap." rows={hub?.needLearning||[]} action={()=>start("Need Learning","need_learning")}/>
   <TargetSection title="Transfer Checks" subtitle="Fresh application checks after uncertainty or I Guessed." rows={hub?.transferChecks||[]} action={()=>start("Transfer Checks","transfer_check")}/>
   <TargetSection title="Retention Checks" subtitle="Previously learned concepts that need spaced confirmation." rows={hub?.retentionChecks||[]} action={()=>start("Retention Checks","retention_check")}/>

   <section className="section-block targeted-section">
    <div className="section-title-line"><div><h2>Recovered</h2><p className="muted">Recently repaired concepts remain visible as evidence, not as permanent weakness.</p></div><span className="targeted-count">{s?.recovered??0}</span></div>
    {hub?.recovered?.length?<div className="targeted-recovered-list">{hub.recovered.slice(0,12).map((r,i)=><div key={`${r.concept_id||r.conceptId||r.name}-${i}`}><b>{r.name}</b><small>{r.source.replaceAll("_"," ")} · {new Date(r.at).toLocaleDateString()}</small></div>)}</div>:<EmptyCopy text="Recovered concepts will appear here after fresh proof."/>}
   </section>
  </>}
 </main>;
}

function TargetMetric({label,value}:{label:string;value:number}){return <div className="targeted-kpi"><strong>{value}</strong><span>{label}</span></div>}
function EmptyCopy({text}:{text:string}){return <div className="empty-state compact-empty"><p className="muted">{text}</p></div>}
function TargetSection({title,subtitle,rows,action}:{title:string;subtitle:string;rows:FocusRow[];action:()=>void}){
 return <section className="section-block targeted-section"><div className="section-title-line"><div><h2>{title}</h2><p className="muted">{subtitle}</p></div>{rows.length>0&&<button className="btn ghost compact-btn" onClick={action}>Practice</button>}</div>{rows.length?<div className="targeted-list">{rows.slice(0,10).map(row=><div className="targeted-row" key={`${title}-${row.questionId}`}><div className="targeted-row-copy"><b>{row.name}</b><small>{row.skillFamily||stateLabel(row.state)}{row.reason?` · ${row.reason}`:""}</small><em>{Math.round(Number(row.confidence)||0)}% confidence · {stateLabel(row.state)}</em></div></div>)}</div>:<EmptyCopy text={`No ${title.toLowerCase()} are due right now.`}/>}</section>
}

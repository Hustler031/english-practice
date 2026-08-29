"use client";

import { useEffect, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Composition={coreBank:number;addedGenerated:number;demandCreated:number;totalActive:number};
type Category={id:string;name:string;total:number;exposed:number;coveragePercent:number;firstAttemptAccuracy:number;retentionAccuracy:number;weak:number;weakConcepts:number;persistentWeak:number;mastered:number;core:number;added:number;demand:number;totalActive:number};
type Progress={schemaVersion:number;bankExposed:number;exposed:number;total:number;left:number;firstAttemptAccuracy:number;afterReviewAccuracy:number;retentionAccuracy:number;weakCount:number;weakConcepts:number;persistentWeakCount:number;masteredCount:number;composition:Composition;categories:Category[]};

export default function ProgressHome(){
 const ready=useAuthGuard();const [p,setP]=useState<Progress|null>(null);const [error,setError]=useState("");const [open,setOpen]=useState<Set<string>>(new Set());
 useEffect(()=>{if(ready)rpc<Progress>("english_get_learning_progress").then(setP).catch((e:any)=>setError(e.message));},[ready]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 const toggle=(id:string)=>setOpen(current=>{const next=new Set(current);next.has(id)?next.delete(id):next.add(id);return next;});
 return <>
  <section className="page-intro"><h1>Progress</h1><p>Your core-bank exposure, first-attempt quality and spaced retention.</p></section>
  {error&&<div className="error-box">{error}</div>}
  <div className="progress-summary progress-six">
   <Metric label="Bank Exposed" value={p?`${p.bankExposed.toFixed(1)}%`:"—"}/><Metric label="First Attempt" value={p?`${p.firstAttemptAccuracy.toFixed(1)}%`:"—"}/><Metric label="Retention" value={p?`${p.retentionAccuracy.toFixed(1)}%`:"—"}/><Metric label="Weak Concepts" value={p?.weakConcepts??"—"}/><Metric label="Persistent Weak" value={p?.persistentWeakCount??"—"}/><Metric label="Mastered" value={p?.masteredCount??"—"}/>
  </div>
  <p className="muted" style={{textAlign:"center",fontSize:11,marginTop:-8}}>After-review accuracy: <b>{p?`${p.afterReviewAccuracy.toFixed(1)}%`:"—"}</b> · immediate same-day retries are excluded from retention.</p>
  <section className="section-block"><h2 className="section-cap">Question Bank</h2><div className="progress-summary"><Metric label="Core Bank" value={p?.composition?.coreBank??"—"}/><Metric label="Added / Generated" value={p?.composition?.addedGenerated??"—"}/><Metric label="Demand-created" value={p?.composition?.demandCreated??"—"}/><Metric label="Total Active" value={p?.composition?.totalActive??"—"}/></div><p className="muted" style={{fontSize:11,lineHeight:1.5}}>Core Bank is the original curated bank. Added / Generated covers later saved-word and Hindu-generated canonical questions. Demand-created counts only genuinely new canonical questions created for a Demand Set; membership of an existing question never increases the total.</p></section>
  <section className="section-block"><h2 className="section-cap">Category Progress</h2><div className="category-list">{p?.categories?.length?p.categories.map(c=>{const expanded=open.has(c.id);const left=Math.max(0,c.total-c.exposed);return <article className={`category-row progress-category ${expanded?"expanded":""}`} key={c.id}><button className="progress-category-head" type="button" aria-expanded={expanded} onClick={()=>toggle(c.id)}><span><b>{c.name}</b><small>{left} left</small></span><span className="progress-category-count">{c.exposed} / {c.total}<i>{expanded?"⌄":"›"}</i></span></button><div className="progress-track green"><i style={{width:`${Math.min(100,c.coveragePercent)}%`}}/></div>{expanded&&<div className="progress-category-details"><small>Coverage {c.coveragePercent.toFixed(1)}% · First {c.firstAttemptAccuracy.toFixed(1)}% · Retention {c.retentionAccuracy.toFixed(1)}%</small><small>Weak {c.weak} · Persistent Weak {c.persistentWeak} · Mastered {c.mastered}</small><small>Core {c.core} · Added {c.added} · Demand {c.demand} · Total active {c.totalActive}</small></div>}</article>}):<div className="empty-copy">Loading category progress…</div>}</div></section>
  <p className="muted" style={{fontSize:11,lineHeight:1.5}}>Bank Exposed = unique genuine core-bank Question_IDs attempted at least once. First Attempt uses only the first genuine attempt per Question_ID. Retention uses the first attempt on later study days, so same-day correction does not inflate retention.</p>
 </>;
}
function Metric({label,value}:{label:string;value:string|number}){return <div><span>{label}</span><b>{value}</b></div>}

"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Category = { id:string; name:string; total:number; exposed:number; available:number; unseen:number; coverage:number; complete:boolean };
type Hub = { total:number; exposed:number; coverage:number; complete:boolean; categories:Category[] };

export default function BankCoveragePage(){
  const ready=useAuthGuard();
  const [hub,setHub]=useState<Hub|null>(null);
  const [pick,setPick]=useState<Category|null>(null);
  const [error,setError]=useState("");
  useEffect(()=>{if(ready)rpc<Hub>("english_get_bank_coverage_hub").then(setHub).catch((e:any)=>setError(e.message));},[ready]);
  const load=useCallback(()=>pick?rpc<any[]>("english_get_bank_coverage_batch",{p_category:pick.id,p_count:10}):Promise.resolve([]),[pick]);
  if(!ready)return <EnglishLoading text="Checking session…"/>;
  if(pick)return <QuizRunner title={`Bank Coverage · ${pick.name}`} backHref="/english/bank" load={load} module="bankCoverage" emptyText="No genuinely unseen questions remain in this category."/>;
  return <>
    <section className="page-intro"><h1>Bank Coverage</h1><p>Optional first-pass exposure. Up to 10 genuinely unseen questions per category.</p></section>
    {error&&<div className="error-box">{error}</div>}
    <section className="revision-panel">
      <div className="revision-panel-head"><div><h2>Bank Exposed</h2><p>{hub?`${hub.exposed} / ${hub.total} unique core-bank questions exposed`:"Loading bank coverage…"}</p></div><strong>{hub?`${hub.coverage.toFixed(1)}%`:"—"}</strong></div>
      <div className="progress-track"><i style={{width:`${Math.min(100,hub?.coverage||0)}%`}}/></div>
    </section>
    <section className="section-block"><h2 className="section-cap">Categories</h2><div className="category-list">{hub?.categories?.length?hub.categories.map(c=><article className="category-row" key={c.id}><div className="category-title"><b>{c.name}</b><span>{c.exposed} / {c.total}</span></div><div className="progress-track"><i style={{width:`${Math.min(100,c.coverage)}%`}}/></div><div className="row" style={{marginTop:8}}><small>{c.coverage.toFixed(1)}% exposed · {c.unseen} unseen</small><span className="spacer"/><button className="btn soft" disabled={c.complete||!c.available} onClick={()=>setPick(c)}>{c.complete?"Fully Exposed":`Start ${c.available}`}</button></div></article>):<div className="empty-copy">Loading categories…</div>}</div></section>
    <div style={{marginTop:16}}><Link className="btn ghost" href="/english/practice">← Practice</Link></div>
  </>;
}

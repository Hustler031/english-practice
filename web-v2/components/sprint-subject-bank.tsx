"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { learnerErrorMessage, localProductionSafetyMode, rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type SubjectRow={subject:string;count:number};
type Overview={ok:boolean;total?:number;subjects?:SubjectRow[];error?:string};

const slugBySubject:Record<string,string>={
  Grammar:"grammar",
  Voice:"voice",
  Narration:"narration",
  Vocabulary:"vocabulary",
  "Phrasal Verbs":"phrasal-verbs",
  "Idioms & OWS":"idioms-ows",
  "Spelling & Usage":"spelling-usage",
};

const hintBySubject:Record<string,string>={
  Grammar:"Error · Improvement · Usage",
  Voice:"Active ↔ Passive",
  Narration:"Direct ↔ Indirect",
  Vocabulary:"Meaning · Synonym · Antonym",
  "Phrasal Verbs":"Saved Sprint phrasal questions",
  "Idioms & OWS":"Idioms · One Word Substitution",
  "Spelling & Usage":"Spelling · Fixed Preposition",
};

export default function SprintSubjectBank(){
  const ready=useAuthGuard();
  const[data,setData]=useState<Overview|null>(null);
  const[error,setError]=useState("");
  const[expanded,setExpanded]=useState(false);

  const load=useCallback(async()=>{
    if(!ready)return;
    try{
      if(!localProductionSafetyMode())await rpc("english_finalize_completed_sprint_bank_marks").catch(()=>undefined);
      const out=await rpc<Overview>("english_get_sprint_bank_overview");setData(out);setError("");
    }catch(e:any){setError(learnerErrorMessage(e,"Could not load the Sprint Question Bank."))}
  },[ready]);

  useEffect(()=>{if(ready)void load()},[ready,load]);
  useEffect(()=>{
    if(!ready)return;
    return subscribeRpcFresh<Overview>("english_get_sprint_bank_overview",undefined,fresh=>{if(fresh?.ok){setData(fresh);setError("")}});
  },[ready]);
  useEffect(()=>{
    if(!ready||typeof document==="undefined")return;
    const observer=new MutationObserver(()=>{if(!document.body.classList.contains("english-sprint-mode"))void load()});
    observer.observe(document.body,{attributes:true,attributeFilter:["class"]});
    return()=>observer.disconnect();
  },[ready,load]);

  if(!ready)return null;
  const rows=Array.isArray(data?.subjects)?data!.subjects!:[];
  return <section className={`sprint-subject-bank ${expanded?"is-expanded":"is-collapsed"}`} aria-label="Subject-wise Sprint Question Bank">
    <header>
      <div><strong>Subject-wise Sprint Bank</strong><span>Only questions you choose from Sprints live here.</span></div>
      <button className="sprint-section-collapse" type="button" aria-expanded={expanded} aria-label={`${expanded?"Collapse":"Expand"} Subject-wise Sprint Bank`} onClick={()=>setExpanded(x=>!x)}><b>{data?.total??0}</b><i>{expanded?"⌃":"⌄"}</i></button>
    </header>
    {expanded&&<>
      {error&&<div className="compact-error sprint-bank-error" role="alert">{error}</div>}
      <div className="sprint-bank-subject-grid">{rows.map(row=><Link key={row.subject} className={`sprint-bank-subject-card ${row.count?"has-items":"empty"}`} href={`/english/exam/bank/${slugBySubject[row.subject]||"grammar"}`}>
        <span><strong>{row.subject}</strong><small>{hintBySubject[row.subject]||"Saved Sprint questions"}</small></span><b>{row.count}<i>›</i></b>
      </Link>)}</div>
      {!rows.length&&!error&&<p className="sprint-bank-empty">Save a useful Sprint question with <b>+ Bank</b>; it will appear here after the Sprint is completed.</p>}
    </>}
  </section>;
}

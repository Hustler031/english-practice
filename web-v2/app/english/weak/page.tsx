"use client";
import Link from "next/link";
import { useCallback,useEffect,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
type Row={concept_id:string;name:string;skill_family:string;coverage_state:string;confidence_score:number;attempts:number;wrong:number};
export default function WeakPage(){
 const ready=useAuthGuard();const [rows,setRows]=useState<Row[]>([]);const [running,setRunning]=useState(false);const [error,setError]=useState("");
 useEffect(()=>{if(ready)rpc<Row[]>("english_get_concept_intelligence_detail",{p_kind:"weak"}).then(x=>setRows(Array.isArray(x)?x:[])).catch((e:any)=>setError(e.message||"Could not load Weak concepts."));},[ready]);
 const load=useCallback(()=>rpc<any[]>("english_get_revision_batch",{p_mode:"weak",p_count:30}),[]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(running)return <QuizRunner title="Weak Concept Revision" backHref="/english/weak" load={load} module="weak" onExit={()=>setRunning(false)}/>;
 return <section className="route-page"><div className="route-head"><Link className="btn ghost" href="/english/revision">← Revision</Link><div><span className="eyebrow">System evidence · concept repair</span><h1>Weak</h1><p>Central Intelligence chooses a focused repair set from your diagnosed weak concepts.</p></div></div>{error&&<div className="error-box">{error}</div>}<section className="route-summary"><Metric label="Priority concepts" value={rows.length}/><Metric label="High risk" value={rows.filter(x=>x.coverage_state==="weak").length}/><Metric label="Retention risk" value={rows.filter(x=>x.coverage_state==="retention_risk").length}/></section><section className="route-start"><h2>Recommended repair</h2><p>Start a system-selected set. It will prefer recent failures and avoid needless repetition.</p><button className="btn primary full-width" disabled={!rows.length} onClick={()=>setRunning(true)}>Start Weak Revision</button></section><section className="route-details"><h2>Priority concepts</h2><div className="legacy-list">{rows.slice(0,20).map(x=><div className="legacy-row" key={x.concept_id}><span className="legacy-row-copy"><b>{x.name}</b><small>{x.skill_family} · {x.coverage_state.replace("_"," ")}</small></span><span>{Math.round(x.confidence_score)}%</span></div>)}</div></section></section>;
}
function Metric({label,value}:{label:string;value:string|number}){return <div><span>{label}</span><b>{value}</b></div>}

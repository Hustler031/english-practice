"use client";
import Link from "next/link";
import { useEffect,useState } from "react";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
type Summary={concepts:number;mapped_questions:number;unresolved_mappings:number;needs_review:number;seen:number;secure:number;exam_ready:number;weak:number;retention_risk:number};
type Row={concept_id:string;domain:string;skill_family:string;name:string;exam_relevance:string;coverage_state:string;confidence_score:number;attempts:number;wrong:number};
export default function AIIntelligencePage(){
 const ready=useAuthGuard(); const [summary,setSummary]=useState<Summary|null>(null); const [rows,setRows]=useState<Row[]>([]); const [kind,setKind]=useState("all"); const [open,setOpen]=useState<string|null>(null); const [error,setError]=useState("");
 useEffect(()=>{if(!ready)return;Promise.all([rpc<Summary>("english_get_concept_intelligence_summary"),rpc<Row[]>("english_get_concept_intelligence_detail",{p_kind:kind})]).then(([s,r])=>{setSummary(s);setRows(Array.isArray(r)?r:[])}).catch((e:any)=>setError(e.message||"Could not load AI Intelligence."))},[ready,kind]);
 if(!ready)return <main className="top-level-parity"><div className="loading-copy">Checking session…</div></main>;
 const cards=[["Exam-ready",summary?.exam_ready??0],["Secure",summary?.secure??0],["Weak",summary?.weak??0],["Retention risk",summary?.retention_risk??0],["Mapped questions",summary?.mapped_questions??0]];
 return <main className="top-level-parity">
  <div className="page-intro"><Link href="/english/revision" className="back-link">← Revision</Link><h1>AI Intelligence</h1><p>Concept-level signals for more efficient revision.</p></div>
  {error&&<div className="error-box">{error}</div>}
  <section className="section-block"><div className="intel-summary-grid">{cards.map(([label,value])=><div className="intel-summary-card" key={String(label)}><b>{String(value)}</b><small>{label}</small></div>)}</div></section>
  <section className="section-block"><div className="section-title-line"><h2>Concept view</h2><select value={kind} onChange={e=>setKind(e.target.value)}><option value="all">All</option><option value="weak">Weak</option><option value="retention">Retention risk</option><option value="coverage">Coverage</option></select></div>
   <div className="legacy-list">{rows.slice(0,80).map(row=><button className="legacy-row" key={row.concept_id} onClick={()=>setOpen(open===row.concept_id?null:row.concept_id)}><span className="legacy-row-copy"><b>{row.name}</b><small>{row.skill_family} · {row.coverage_state.replace("_"," ")}</small>{open===row.concept_id&&<em>{row.confidence_score.toFixed(0)} confidence · {row.attempts} attempts · {row.wrong} wrong</em>}</span><span>{row.exam_relevance} ›</span></button>)}</div>
  </section>
  <section className="section-block"><details><summary>Mapping quality</summary><p className="muted">{summary?.unresolved_mappings??0} unresolved · {summary?.needs_review??0} need review. Conservative mappings remain auditable.</p></details></section>
 </main>;
}

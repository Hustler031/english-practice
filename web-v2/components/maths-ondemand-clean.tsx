"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { MathsLoading } from "@/components/maths-frame";
import { mathsErrorMessage, mathsRpc, rememberMathsSession, subscribeMathsFresh, type MathsSession } from "@/lib/maths-rpc";
import { useAuthGuard } from "@/lib/use-auth";

type Metric={total:number};
type Chapters={ok:boolean;chapters:{chapter:string;metric:Metric}[]};
type Demand={setId:string;name:string;description:string;status:string;count:number;specialist:boolean};
type Hub={ok:boolean;mocks:number;formulas:number;concepts:number;generated:number;demandSets:Demand[]};

export default function MathsOnDemandClean(){
  const ready=useAuthGuard();const router=useRouter();const[data,setData]=useState<Hub|null>(null);const[chapters,setChapters]=useState<Chapters|null>(null);const[chapter,setChapter]=useState("");const[busy,setBusy]=useState(false);const[error,setError]=useState("");
  useEffect(()=>{if(!ready)return;let alive=true;const load=()=>Promise.all([mathsRpc<Hub>("maths_get_ondemand_hub"),mathsRpc<Chapters>("maths_get_chapters_hub")]).then(([h,c])=>{if(alive){setData(h);setChapters(c);setError("");}}).catch(e=>alive&&setError(mathsErrorMessage(e)));void load();const unsub=subscribeMathsFresh<Hub>("maths_get_ondemand_hub",undefined,h=>alive&&setData(h));return()=>{alive=false;unsub();};},[ready]);
  async function start(){if(busy)return;setBusy(true);setError("");try{const s=await mathsRpc<MathsSession>("maths_start_focused_practice",{p_scope:chapter?"chapter":"all",p_chapter:chapter||null,p_kind:"random",p_count:20});if(!s?.ok||!s.sessionId)throw new Error(s?.message||"No eligible academic questions found.");rememberMathsSession(s);router.push(`/maths/session?id=${encodeURIComponent(s.sessionId)}`);}catch(e){setError(mathsErrorMessage(e));}finally{setBusy(false);}}
  if(!ready)return <MathsLoading text="Checking Maths session…"/>;if(!data&&!error)return <MathsLoading text="Loading On Demand…"/>;if(!data)return <div className="maths-error">{error}</div>;
  const sets=data.demandSets.filter(x=>x.setId!=="MOCK_QUESTIONS"&&x.setId!=="MOCK_FORMULA_REVISION"&&x.setId!=="CALC_TRAINING");
  return <section className="m-ondemand-clean">
    <div className="m-title"><div className="m-kicker">Custom</div><h1>On Demand</h1><p>Academic practice and preserved custom sets. Calculation lives only inside Exam Preparation.</p></div>
    {error&&<div className="maths-error compact">{error}</div>}
    <section className="m-card m-quick-practice"><h2>Quick academic practice</h2><select value={chapter} onChange={e=>setChapter(e.target.value)} aria-label="Academic chapter"><option value="">All academic chapters</option>{(chapters?.chapters||[]).map(c=><option key={c.chapter} value={c.chapter}>{c.chapter}</option>)}</select><button className="m-wide-primary" type="button" disabled={busy} onClick={()=>void start()}>{busy?"Starting…":"Start 20 random"}</button></section>
    <h2 className="m-section-title">Specialist practice</h2><div className="m-list"><Link className="m-row no-icon" href="/maths/mocks"><span className="m-row-copy"><b>Mock Questions</b><small>Dedicated academic mock bank</small></span><span className="m-row-status">{data.mocks}</span><i>›</i></Link><Link className="m-row no-icon" href="/maths/formulas"><span className="m-row-copy"><b>Formula Revision</b><small>Formula recall and application</small></span><span className="m-row-status">{data.formulas}</span><i>›</i></Link><Link className="m-row no-icon" href="/maths/concepts"><span className="m-row-copy"><b>Concepts</b><small>Academic saved questions only</small></span><span className="m-row-status">{data.concepts}</span><i>›</i></Link></div>
    {sets.length>0&&<><h2 className="m-section-title secondary">Saved sets</h2><div className="m-list">{sets.map(s=><Link className="m-row no-icon" key={s.setId} href="/maths/demand"><span className="m-row-copy"><b>{s.name}</b><small>{s.count} questions{s.description?` · ${s.description}`:""}</small></span><i>›</i></Link>)}</div></>}
    {data.generated>0&&<><h2 className="m-section-title secondary">Other</h2><div className="m-list"><Link className="m-row no-icon" href="/maths/generated"><span className="m-row-copy"><b>Generated Academic Practice</b><small>Explicit generated academic bank</small></span><span className="m-row-status">{data.generated}</span><i>›</i></Link></div></>}
  </section>;
}

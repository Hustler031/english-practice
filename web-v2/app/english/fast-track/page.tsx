"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { localProductionSafetyMode, rpc, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type OriginRow={origin:string;total:number;mastered:number;retentionWatch:number;remaining:number};
type Overview={ok:boolean;fastTrack:{total:number;readyToVerify:number;waiting:number;retentionWatch:number;retentionDue:number;mastered:number;remaining:number;origins:OriginRow[]}};
const sizes=[10,20,30,50,100];
const requiredOrigins=["Bank Coverage","From Starred","From My Saved","Manual Fast Track","Recovered Weak","Recovered Persistent Weak","Recovered Difficult","Recovered Targeted"];

export default function FastTrackPage(){
 const ready=useAuthGuard();const[overview,setOverview]=useState<Overview|null>(null);const[size,setSize]=useState(30);const[running,setRunning]=useState(false);const[details,setDetails]=useState(false);const[error,setError]=useState("");const localSafe=localProductionSafetyMode();
 const refresh=useCallback(async()=>{const {data,error}=await supabaseBrowser().rpc("english_get_learning_route_overview");if(error)throw error;setOverview(data as Overview);},[]);
 useEffect(()=>{if(ready)refresh().catch((e:any)=>setError(e.message));},[ready,refresh]);
 const load=useCallback(()=>rpc<any[]>("english_get_fast_track_batch_session",{p_count:size,p_origin:null,p_nonce:`ft-${Date.now()}-${Math.random().toString(36).slice(2,8)}`}),[size]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(running)return <QuizRunner title="Fast Track Verification" backHref="/english/fast-track" load={load} module="fasttrack" fastTrackMode onExit={()=>{setRunning(false);void refresh()}} onFinish={refresh}/>;
 const ft=overview?.fastTrack;const byOrigin=new Map((ft?.origins||[]).map(x=>[x.origin,x]));
 return <section className="route-page">
  <div className="route-head"><Link className="btn ghost" href="/english/revision">← Revision</Link><div><span className="eyebrow">Cheap verification · spaced retention</span><h1>Fast Track</h1><p>Verify quickly, then confirm retention after a real gap before it becomes Proven.</p></div></div>
  {error&&<div className="error-box">{error}</div>}
  <section className="route-summary"><Metric label="Ready" value={ft?.readyToVerify??"—"}/><Metric label="Retention" value={ft?.retentionWatch??"—"}/><Metric label="Proven" value={ft?.mastered??"—"}/></section>
  <section className="route-start"><h2>Start Verification</h2><p>Ready items include first verification and any Retention Watch item whose spaced check is due.</p><div className="route-sizes">{sizes.map(n=><button key={n} className={`btn ghost ${size===n?"active":""}`} onClick={()=>setSize(n)}>{n}</button>)}</div><button className="btn primary full-width" disabled={!ft?.readyToVerify||localSafe} onClick={()=>setRunning(true)}>Start {size}</button>{localSafe&&<p className="route-safe-note">Local Safe is active: verification writes are disabled against production data.</p>}<button className="btn ghost full-width" onClick={()=>setDetails(x=>!x)}>{details?"Hide details":"View"}</button></section>
  {details&&<section className="route-details"><div className="section-title-line"><h2>Fast Track Details</h2><Link className="btn ghost mini" href="/english/route-view?route=fast_track">All questions</Link></div><div className="route-table"><div className="route-table-head"><span>Origin</span><span>Total</span><span>Retention</span><span>Proven</span></div>{requiredOrigins.map(origin=>{const row=byOrigin.get(origin)||{origin,total:0,mastered:0,retentionWatch:0,remaining:0};return <Link className="route-table-row" key={origin} href={`/english/route-view?route=fast_track&origin=${encodeURIComponent(origin)}`} title={`${row.remaining} not yet Proven`}><b>{origin}</b><span>{row.total}</span><span>{row.retentionWatch}</span><span>{row.mastered} ›</span></Link>})}<div className="route-table-row route-table-total"><b>TOTAL</b><span>{ft?.total??0}</span><span>{ft?.retentionWatch??0}</span><span>{ft?.mastered??0}</span></div></div></section>}
 </section>;
}
function Metric({label,value}:{label:string;value:string|number}){return <div><span>{label}</span><b>{value}</b></div>}

"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type CountRow={status?:string;category?:string;count:number};
type RouteHistory={at:string;type:string;from?:string;to?:string;origin?:string;reason?:string};
type Item={id:string;word?:string;question?:string;category?:string;topic?:string;options?:Array<{key:string;text:string}>;correctKey?:string;explanation?:string;example?:string;usageNote?:string;meaning?:string;learningRoute?:string;viewStatus?:string;fastTrackStatus?:string;fastTrackOrigins?:string[];fastTrackReason?:string;fastTrackEnteredAt?:string;fastTrackNextCheck?:string;fastTrackMasteredAt?:string;learningStatus?:string;wrong?:number;difficult?:boolean;routeHistory?:RouteHistory[]};
type ViewData={ok:boolean;route:string;origin?:string|null;total:number;filteredTotal:number;statuses:CountRow[];categories:CountRow[];items:Item[]};
type Route="fast_track"|"targeted"|"unclassified";

function queryConfig(){
 if(typeof window==="undefined")return {route:"fast_track" as Route,origin:null as string|null};
 const p=new URLSearchParams(window.location.search);const raw=p.get("route");
 const route:Route=raw==="targeted"||raw==="unclassified"?raw:"fast_track";
 return {route,origin:p.get("origin")};
}
function title(route:Route,origin:string|null){const base=route==="fast_track"?"Fast Track":route==="targeted"?"Targeted Mastery":"Unclassified";return origin?`${origin} → ${base}`:base;}

export default function RouteViewPage(){
 const ready=useAuthGuard();const[config,setConfig]=useState<{route:Route;origin:string|null}>({route:"fast_track",origin:null});const[data,setData]=useState<ViewData|null>(null);const[status,setStatus]=useState<string|null>(null);const[category,setCategory]=useState<string|null>(null);const[showItems,setShowItems]=useState(false);const[open,setOpen]=useState<string|null>(null);const[loading,setLoading]=useState(false);const[error,setError]=useState("");
 useEffect(()=>setConfig(queryConfig()),[]);
 const load=useCallback(async(nextStatus:string|null,nextCategory:string|null)=>{setLoading(true);setError("");try{const {data:out,error:e}=await supabaseBrowser().rpc("english_get_route_view",{p_route:config.route,p_origin:config.origin,p_status:nextStatus,p_category:nextCategory,p_limit:200,p_offset:0});if(e)throw e;setData(out as ViewData);}catch(e:any){setError(e.message||String(e));}finally{setLoading(false)}},[config]);
 useEffect(()=>{if(ready)void load(null,null);},[ready,load]);
 const backHref=config.origin==="From My Saved"?"/english/saved":config.origin==="From Starred"?"/english/starred":config.route==="fast_track"?"/english/fast-track":"/english/revision";
 const selectStatus=(value:string|null)=>{setStatus(value);setCategory(null);setShowItems(true);void load(value,null)};
 const selectCategory=(value:string|null)=>{setCategory(value);setStatus(null);setShowItems(true);void load(null,value)};
 const currentTitle=title(config.route,config.origin);
 const rows=useMemo(()=>data?.items||[],[data]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 return <section className="route-browser-page">
  <div className="route-head"><Link className="btn ghost" href={backHref}>← Back</Link><div><span className="eyebrow">Learning route drill-down</span><h1>{currentTitle}</h1><p>{data?`${data.total} routed items`:"Loading route evidence…"}</p></div></div>
  {error&&<div className="error-box">{error}</div>}
  <section className="route-browser-summary"><div className="section-title-line"><h2>Status</h2><button className="btn ghost mini" disabled={!data?.total} onClick={()=>selectStatus(null)}>All {data?.total??0}</button></div><div className="route-browser-chips">{data?.statuses?.map(x=><button className={`route-count-chip ${status===x.status?"active":""}`} key={x.status} onClick={()=>selectStatus(x.status||null)}><b>{x.count}</b><span>{pretty(x.status||"Status")}</span></button>)}</div></section>
  <section className="route-browser-summary"><h2>Category</h2><div className="route-browser-chips">{data?.categories?.map(x=><button className={`route-count-chip ${category===String(x.category||"").toLowerCase()?"active":""}`} key={x.category} onClick={()=>selectCategory(String(x.category||"").toLowerCase())}><b>{x.count}</b><span>{x.category}</span></button>)}</div></section>
  {!showItems?<section className="route-browser-prompt"><b>Choose a status or category to drill down.</b><span>Grouped counts stay primary; the question inventory opens only when requested.</span><button className="btn ghost" disabled={!data?.total} onClick={()=>selectStatus(null)}>View All Questions</button></section>:<section className="route-browser-items"><div className="section-title-line"><h2>{status?pretty(status):category?pretty(category):"All Questions"}</h2><span className="muted">{loading?"Loading…":`${data?.filteredTotal??0} items`}</span></div>{!loading&&!rows.length?<div className="empty-state"><h3>No items</h3><p className="muted">This route slice is clear.</p></div>:rows.map((q,i)=>{const expanded=open===q.id;const answer=q.options?.find(o=>String(o.key).toUpperCase()===String(q.correctKey||"").toUpperCase());return <article className={`route-question-row ${expanded?"expanded":""}`} key={q.id||i}><button className="route-question-head" onClick={()=>setOpen(expanded?null:q.id)}><span><b>{q.word||q.question||q.id}</b><small>{q.category||q.topic||"English"} · {pretty(q.viewStatus||q.fastTrackStatus||q.learningStatus||q.learningRoute||"")}</small></span><i>{expanded?"⌄":"›"}</i></button>{expanded&&<div className="route-question-detail">{q.word&&q.question?<Detail label="Question" value={q.question}/>:null}<Detail label="Correct Answer" value={answer?`${answer.key}. ${answer.text}`:q.correctKey||"—"}/>{q.explanation&&<Detail label="Explanation" value={q.explanation}/>} {q.example&&<Detail label="Example" value={q.example}/>} {q.usageNote&&<Detail label="Usage" value={q.usageNote}/>}<Detail label="Learning Route" value={`${(q.routeHistory||[]).map(h=>h.to).filter(Boolean).join(" → ")||pretty(q.learningRoute||config.route)}`}/>{q.fastTrackOrigins?.length?<Detail label="Origin(s)" value={q.fastTrackOrigins.join(" · ")}/>:null}{q.fastTrackReason&&<Detail label="Evidence" value={q.fastTrackReason}/>} {q.fastTrackEnteredAt&&<Detail label="Moved to Fast Track" value={date(q.fastTrackEnteredAt)}/>} {q.fastTrackMasteredAt&&<Detail label="Mastered" value={date(q.fastTrackMasteredAt)}/>} {q.fastTrackNextCheck&&<Detail label="Next Check" value={date(q.fastTrackNextCheck)}/>} {q.routeHistory?.length?<details className="route-history"><summary>Route history</summary>{q.routeHistory.map((h,j)=><div key={j}><b>{h.type}</b><span>{h.reason||`${h.from||"—"} → ${h.to||"—"}`}</span><small>{dateTime(h.at)}</small></div>)}</details>:null}</div>}</article>})}</section>}
 </section>;
}
function Detail({label,value}:{label:string;value:string}){return <div className="route-detail-line"><span>{label}</span><b>{value}</b></div>}
function pretty(value:string){return String(value||"").replace(/_/g," ").replace(/\b\w/g,c=>c.toUpperCase())}
function date(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleDateString("en-IN")}
function dateTime(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleString("en-IN")}

"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type CountRow={status?:string;category?:string;count:number};
type RouteHistory={at:string;type:string;from?:string;to?:string;origin?:string;reason?:string};
type Item={id:string;word?:string;question?:string;category?:string;topic?:string;options?:Array<{key:string;text:string}>;correctKey?:string;explanation?:string;example?:string;usageNote?:string;meaning?:string;learningRoute?:string;viewStatus?:string;fastTrackStatus?:string;fastTrackOrigins?:string[];fastTrackReason?:string;fastTrackEnteredAt?:string;fastTrackNextCheck?:string;fastTrackMasteredAt?:string;learningStatus?:string;wrong?:number;difficult?:boolean;routeHistory?:RouteHistory[]};
type ViewData={ok:boolean;route:string;origin?:string|null;total:number;filteredTotal:number;statuses:CountRow[];categories:CountRow[];items:Item[]};
type Route="fast_track"|"targeted"|"unclassified";
type Config={route:Route;origin:string|null};

function readConfig():Config{const p=new URLSearchParams(window.location.search);const raw=p.get("route");const route:Route=raw==="targeted"||raw==="unclassified"?raw:"fast_track";return {route,origin:p.get("origin")}}
function routeName(route:Route){return route==="fast_track"?"Fast Track":route==="targeted"?"Targeted Mastery":"Unclassified"}

export default function RouteViewPage(){
  const ready=useAuthGuard();
  const[config,setConfig]=useState<Config|null>(null);
  const[data,setData]=useState<ViewData|null>(null);
  const[status,setStatus]=useState<string|null>(null);
  const[category,setCategory]=useState<string|null>(null);
  const[showItems,setShowItems]=useState(false);
  const[open,setOpen]=useState<string|null>(null);
  const[loading,setLoading]=useState(false);
  const[error,setError]=useState("");
  const[infoOpen,setInfoOpen]=useState(false);
  const requestId=useRef(0);

  useEffect(()=>{setConfig(readConfig())},[]);

  const load=useCallback(async(nextStatus:string|null,nextCategory:string|null)=>{
    if(!config)return;
    const id=++requestId.current;setLoading(true);setError("");
    try{
      const {data:out,error:e}=await supabaseBrowser().rpc("english_get_route_view",{p_route:config.route,p_origin:config.origin,p_status:nextStatus,p_category:nextCategory,p_limit:200,p_offset:0});
      if(e)throw e;
      if(id===requestId.current)setData(out as ViewData);
    }catch(e:any){if(id===requestId.current)setError(e.message||String(e))}
    finally{if(id===requestId.current)setLoading(false)}
  },[config]);

  useEffect(()=>{if(ready&&config)void load(null,null)},[ready,config,load]);

  if(!ready||!config)return <EnglishLoading text="Checking route…"/>;

  const backHref=config.origin==="From My Saved"?"/english/saved":config.origin==="From Starred"?"/english/starred":config.route==="fast_track"?"/english/fast-track":"/english/revision";
  const label=config.origin||routeName(config.route);
  const routeLabel=routeName(config.route);
  const mastered=data?.statuses?.find(x=>String(x.status).toLowerCase()==="mastered")?.count||0;
  const readyCount=data?.statuses?.find(x=>String(x.status).toLowerCase()==="ready")?.count||0;
  const waiting=data?.statuses?.find(x=>String(x.status).toLowerCase()==="waiting")?.count||0;
  const remaining=Math.max(0,(data?.total||0)-mastered);
  const rows=data?.items||[];

  const selectStatus=(value:string|null)=>{setStatus(value);setCategory(null);setShowItems(true);void load(value,null)};
  const selectCategory=(value:string|null)=>{setCategory(value);setStatus(null);setShowItems(true);void load(null,value)};

  return <section className="route-clean-page">
    <header className="module-compact-head">
      <Link className="compact-back" href={backHref}>← Back</Link>
      <div className="compact-head-copy"><strong>{label}</strong><span>{config.origin?routeLabel:"Learning route"}</span></div>
      <button className="compact-info" type="button" aria-label="Route details" onClick={()=>setInfoOpen(true)}>i</button>
    </header>

    {error&&<div className="compact-error" role="alert">{error}</div>}

    <section className="route-compact-summary">
      <div><span>Total</span><b>{data?.total??0}</b></div>
      {config.route==="fast_track"?<><div><span>Mastered</span><b>{mastered}</b></div><div><span>Remaining</span><b>{remaining}</b></div></>:<><div><span>Active</span><b>{data?.total??0}</b></div><div><span>Filtered</span><b>{data?.filteredTotal??data?.total??0}</b></div></>}
    </section>

    <section className="route-category-line">
      <div className="section-inline-title"><strong>Category</strong><button type="button" onClick={()=>{setCategory(null);setStatus(null);setShowItems(true);void load(null,null)}}>All</button></div>
      <div className="route-chip-scroll">{data?.categories?.map(x=><button type="button" className={category===String(x.category||"").toLowerCase()?"active":""} key={x.category} onClick={()=>selectCategory(String(x.category||"").toLowerCase())}><b>{x.count}</b><span>{pretty(x.category||"")}</span></button>)}</div>
    </section>

    {!showItems?<button className="route-view-questions" type="button" disabled={!data?.total} onClick={()=>selectStatus(null)}>View Questions</button>:<section className="route-inventory-clean"><header><div><strong>{status?pretty(status):category?pretty(category):"All Questions"}</strong><span>{loading?"Loading…":`${data?.filteredTotal??0} items`}</span></div><button type="button" onClick={()=>{setShowItems(false);setOpen(null)}}>Hide</button></header>{!loading&&!rows.length?<div className="empty-state"><h3>No items</h3><p className="muted">This route slice is clear.</p></div>:rows.map((q,i)=>{const key=q.id||String(i);const expanded=open===key;const answer=q.options?.find(o=>String(o.key).toUpperCase()===String(q.correctKey||"").toUpperCase());return <article className={`route-question-row clean ${expanded?"expanded":""}`} key={key}><button className="route-question-head" type="button" onClick={()=>setOpen(expanded?null:key)}><span><b>{q.word||q.question||q.id}</b><small>{pretty(q.category||q.topic||"English")} · {pretty(q.viewStatus||q.fastTrackStatus||q.learningStatus||q.learningRoute||"")}</small></span><i>{expanded?"⌄":"›"}</i></button>{expanded&&<div className="route-question-detail clean-detail">{q.meaning&&<Detail label="Meaning" value={q.meaning}/>} {q.word&&q.question?<Detail label="Question" value={q.question}/>:null}<Detail label="Correct Answer" value={answer?`${answer.key}. ${answer.text}`:q.correctKey||"—"}/>{q.explanation&&<Detail label="Explanation" value={q.explanation}/>} {q.example&&<Detail label="Example" value={q.example}/>} {q.usageNote&&<Detail label="Usage" value={q.usageNote}/>}<Detail label="Learning Route" value={(q.routeHistory||[]).map(h=>h.to).filter(Boolean).join(" → ")||pretty(q.learningRoute||config.route)}/>{q.fastTrackOrigins?.length?<Detail label="Origin(s)" value={q.fastTrackOrigins.join(" · ")}/>:null}{q.fastTrackReason&&<Detail label="Evidence" value={q.fastTrackReason}/>} {q.fastTrackEnteredAt&&<Detail label="Moved" value={date(q.fastTrackEnteredAt)}/>} {q.fastTrackMasteredAt&&<Detail label="Mastered" value={date(q.fastTrackMasteredAt)}/>} {q.fastTrackNextCheck&&<Detail label="Next Check" value={date(q.fastTrackNextCheck)}/>} {q.routeHistory?.length?<details className="route-history"><summary>Route history</summary>{q.routeHistory.map((h,j)=><div key={j}><b>{h.type}</b><span>{h.reason||`${h.from||"—"} → ${h.to||"—"}`}</span><small>{dateTime(h.at)}</small></div>)}</details>:null}</div>}</article>})}</section>}

    {infoOpen&&<div className="clean-modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)setInfoOpen(false)}}><section className="clean-modal route-info-modal" role="dialog" aria-modal="true" aria-label="Route details"><header><div><strong>{label}</strong><span>{data?.total??0} items in this exact route/origin</span></div><button type="button" aria-label="Close" onClick={()=>setInfoOpen(false)}>×</button></header><div className="info-metric-grid"><div className="mini-metric"><span>Ready</span><strong>{readyCount}</strong></div><div className="mini-metric"><span>Waiting</span><strong>{waiting}</strong></div><div className="mini-metric"><span>Mastered</span><strong>{mastered}</strong></div></div><section className="info-section"><h3>Status</h3><div className="simple-list">{data?.statuses?.map(x=><button type="button" key={x.status} onClick={()=>{setInfoOpen(false);selectStatus(x.status||null)}}><span>{pretty(x.status||"")}</span><b>{x.count}</b></button>)}</div></section><section className="info-section"><h3>Category breakdown</h3><div className="simple-list">{data?.categories?.map(x=><button type="button" key={x.category} onClick={()=>{setInfoOpen(false);selectCategory(String(x.category||"").toLowerCase())}}><span>{pretty(x.category||"")}</span><b>{x.count}</b></button>)}</div></section></section></div>}
  </section>;
}

function Detail({label,value}:{label:string;value:string}){return <div className="route-detail-line"><span>{label}</span><b>{value}</b></div>}
function pretty(value:string){return String(value||"").replace(/_/g," ").replace(/\b\w/g,c=>c.toUpperCase())}
function date(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleDateString("en-IN")}
function dateTime(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleString("en-IN")}

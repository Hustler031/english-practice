"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { DAILY_ANALYSIS_CATEGORIES,DAILY_ANALYSIS_RANGES,isDailyAnalysisRange,rangeLabel,type DailyAnalysisRange,type DailyAnalysisSummary } from "@/lib/daily-analysis";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function DailyAnalysisPage(){
 const ready=useAuthGuard();
 const [range,setRange]=useState<DailyAnalysisRange>("today");
 const [data,setData]=useState<DailyAnalysisSummary|null>(null);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");

 useEffect(()=>{
  if(typeof window==="undefined")return;
  const requested=new URLSearchParams(window.location.search).get("range")||"today";
  if(isDailyAnalysisRange(requested))setRange(requested);
 },[]);

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  setLoading(true);setError("");
  rpc<DailyAnalysisSummary>("english_get_daily_analysis_summary_filtered",{p_range:range})
   .then(x=>alive&&setData(x))
   .catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load English practice analysis.")))
   .finally(()=>alive&&setLoading(false));
  return()=>{alive=false};
 },[ready,range]);

 function changeRange(next:DailyAnalysisRange){
  setRange(next);
  if(typeof window!=="undefined"){
   const qs=new URLSearchParams(window.location.search);qs.set("range",next);
   window.history.replaceState(window.history.state,"",`${window.location.pathname}?${qs.toString()}`);
  }
 }

 if(!ready)return null;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page daily-analysis-page">
  <PageHeader back={<Link href="/english/revision/ai-intelligence" className="back-link">← Learning Insights</Link>} eyebrow="All English practice" title="Daily Analysis" subtitle="Inspect learning signals from every English module."/>
  <div className="daily-analysis-readonly-note">Read-only review · opening a question does not change attempts, mastery, or cooldown.</div>
  <div className="daily-analysis-filter-row">
   <span><b>{rangeLabel(range)}</b><small>{range==="today"?"All English activity today":range==="7d"?"All English activity from the last 7 days":"All recorded English activity"}</small></span>
   <RangeFilter value={range} onChange={changeRange}/>
  </div>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading {rangeLabel(range).toLowerCase()} analysis…</div>:<>
   <div className="daily-analysis-mini-summary">
    <span><b>{data?.attemptedQuestions||0}</b><small>questions attempted</small></span>
    <span><b>{data?.attemptCount||0}</b><small>total attempts</small></span>
    <span><b>{data?.wrongAttempts||0}</b><small>wrong attempts</small></span>
   </div>
   <section className="daily-analysis-category-list" aria-label="Daily analysis categories">
    {DAILY_ANALYSIS_CATEGORIES.map(item=><Link key={item.key} className={`daily-analysis-category-row category-${item.key}`} href={`/english/revision/ai-intelligence/daily-analysis/questions?category=${encodeURIComponent(item.key)}&range=${range}`}>
      <span><b>{item.title}</b><small>{item.subtitle}</small></span><strong>{data?.categories?.[item.key]??0}</strong><i>›</i>
    </Link>)}
   </section>
  </>}
 </main>;
}

function RangeFilter({value,onChange}:{value:DailyAnalysisRange;onChange:(value:DailyAnalysisRange)=>void}){
 return <div className="daily-analysis-range-filter" role="group" aria-label="Daily Analysis period">{DAILY_ANALYSIS_RANGES.map(item=><button key={item.key} type="button" className={value===item.key?"active":""} aria-pressed={value===item.key} onClick={()=>onChange(item.key)}>{item.label}</button>)}</div>;
}

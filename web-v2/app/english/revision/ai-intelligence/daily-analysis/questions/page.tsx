"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { DAILY_ANALYSIS_RANGES,categoryMeta,dailyAnalysisRowNote,isDailyAnalysisCategory,isDailyAnalysisRange,rangeLabel,stateLabel,type DailyAnalysisList,type DailyAnalysisRange } from "@/lib/daily-analysis";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function DailyAnalysisQuestionsPage(){
 const ready=useAuthGuard();
 const [category,setCategory]=useState("");
 const [range,setRange]=useState<DailyAnalysisRange>("today");
 const [data,setData]=useState<DailyAnalysisList|null>(null);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");

 useEffect(()=>{
  if(typeof window==="undefined")return;
  const qs=new URLSearchParams(window.location.search);
  setCategory(qs.get("category")||"");
  const requested=qs.get("range")||"today";
  if(isDailyAnalysisRange(requested))setRange(requested);
 },[]);

 useEffect(()=>{
  if(!ready||!category)return;
  if(!isDailyAnalysisCategory(category)){setError("Unknown Daily Analysis category.");setLoading(false);return;}
  let alive=true;
  setLoading(true);setError("");
  rpc<DailyAnalysisList>("english_get_daily_analysis_questions_filtered",{p_category:category,p_range:range,p_limit:200})
   .then(x=>alive&&setData(x))
   .catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load these questions.")))
   .finally(()=>alive&&setLoading(false));
  return()=>{alive=false};
 },[ready,category,range]);

 function changeRange(next:DailyAnalysisRange){
  setRange(next);
  if(typeof window!=="undefined"){
    const qs=new URLSearchParams(window.location.search);qs.set("range",next);
    window.history.replaceState(window.history.state,"",`${window.location.pathname}?${qs.toString()}`);
  }
 }

 if(!ready)return null;
 const meta=categoryMeta(category);
 const periodCopy=range==="today"?"Today’s Daily plan":range==="7d"?"Daily plans from the last 7 days":"All recorded Daily plans";
 return <main className="top-level-parity learner-rebuild-page learner-insights-page daily-analysis-page daily-analysis-list-page">
  <PageHeader back={<Link href="/english/revision/ai-intelligence/daily-analysis" className="back-link">← Daily Analysis</Link>} eyebrow="Daily review" title={meta?.title||"Daily Analysis"} subtitle={meta?.subtitle||"Review Daily questions."}/>
  <div className="daily-analysis-filter-row">
   <span><b>{rangeLabel(range)}</b><small>{periodCopy}</small></span>
   <RangeFilter value={range} onChange={changeRange}/>
  </div>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading {rangeLabel(range).toLowerCase()} questions…</div>:data?.questions?.length?<section className="daily-analysis-question-list">{data.questions.map(row=><Link key={row.questionId} className="daily-analysis-question-row" href={`/english/revision/ai-intelligence/daily-analysis/review?category=${encodeURIComponent(category)}&questionId=${encodeURIComponent(row.questionId)}&range=${range}`}>
    <span className="daily-analysis-question-main"><b>{row.displayName}</b><small>{row.topic} · {dailyAnalysisRowNote(row,range)}</small></span>
    <span className={`daily-analysis-state ${(row.periodWrong??row.wrongToday??0)>0?"has-wrong":""}`}>{(row.periodWrong??row.wrongToday??0)>0?`${row.periodWrong??row.wrongToday} wrong`:stateLabel(row.currentState)}</span><i>›</i>
   </Link>)}</section>:<div className="learner-empty">No {meta?.title?.toLowerCase()||"review"} questions in {rangeLabel(range).toLowerCase()}.</div>}
 </main>;
}

function RangeFilter({value,onChange}:{value:DailyAnalysisRange;onChange:(value:DailyAnalysisRange)=>void}){
 return <div className="daily-analysis-range-filter" role="group" aria-label="Daily Analysis period">{DAILY_ANALYSIS_RANGES.map(item=><button key={item.key} type="button" className={value===item.key?"active":""} aria-pressed={value===item.key} onClick={()=>onChange(item.key)}>{item.label}</button>)}</div>;
}

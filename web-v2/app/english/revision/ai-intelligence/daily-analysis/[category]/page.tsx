"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { categoryMeta,dailyAnalysisRowNote,isDailyAnalysisCategory,stateLabel,type DailyAnalysisList } from "@/lib/daily-analysis";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function DailyAnalysisCategoryPage(){
 const ready=useAuthGuard();
 const params=useParams<{category:string}>();
 const category=useMemo(()=>String(params?.category||""),[params]);
 const meta=categoryMeta(category);
 const [data,setData]=useState<DailyAnalysisList|null>(null);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");
 useEffect(()=>{
  if(!ready)return;
  if(!isDailyAnalysisCategory(category)){setError("Unknown Daily Analysis category.");setLoading(false);return;}
  let alive=true;
  rpc<DailyAnalysisList>("english_get_daily_analysis_questions",{p_category:category,p_limit:120})
   .then(x=>alive&&setData(x)).catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load these questions."))).finally(()=>alive&&setLoading(false));
  return()=>{alive=false};
 },[ready,category]);
 if(!ready)return null;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page daily-analysis-page daily-analysis-list-page">
  <PageHeader back={<Link href="/english/revision/ai-intelligence/daily-analysis" className="back-link">← Daily Analysis</Link>} eyebrow="Today’s Daily" title={meta?.title||"Daily Analysis"} subtitle={meta?.subtitle||"Review today’s questions."}/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading questions…</div>:data?.questions?.length?<section className="daily-analysis-question-list">{data.questions.map(row=><Link key={row.questionId} className="daily-analysis-question-row" href={`/english/revision/ai-intelligence/daily-analysis/${category}/${encodeURIComponent(row.questionId)}`}>
    <span className="daily-analysis-question-main"><b>{row.displayName}</b><small>{row.topic} · {dailyAnalysisRowNote(row)}</small></span>
    <span className={`daily-analysis-state ${row.wrongToday>0?"has-wrong":""}`}>{row.wrongToday>0?`${row.wrongToday} wrong`:stateLabel(row.currentState)}</span><i>›</i>
   </Link>)}</section>:<div className="learner-empty">No questions in this category today.</div>}
 </main>;
}

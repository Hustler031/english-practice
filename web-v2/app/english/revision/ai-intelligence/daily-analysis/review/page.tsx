"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { DAILY_ANALYSIS_RANGES,categoryMeta,formatAttemptTime,isDailyAnalysisCategory,isDailyAnalysisRange,rangeLabel,stateLabel,type DailyAnalysisDetail,type DailyAnalysisRange } from "@/lib/daily-analysis";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function DailyAnalysisReviewPage(){
 const ready=useAuthGuard();
 const [category,setCategory]=useState("");
 const [questionId,setQuestionId]=useState("");
 const [categoryRange,setCategoryRange]=useState<DailyAnalysisRange>("today");
 const [attemptRange,setAttemptRange]=useState<DailyAnalysisRange>("today");
 const [data,setData]=useState<DailyAnalysisDetail|null>(null);
 const [loading,setLoading]=useState(true);
 const [attemptBusy,setAttemptBusy]=useState(false);
 const [error,setError]=useState("");

 useEffect(()=>{
  if(typeof window==="undefined")return;
  const qs=new URLSearchParams(window.location.search);
  setCategory(qs.get("category")||"");
  setQuestionId(qs.get("questionId")||"");
  const requestedRange=qs.get("range")||"today";
  const safeRange=isDailyAnalysisRange(requestedRange)?requestedRange:"today";
  setCategoryRange(safeRange);
  const requestedAttempts=qs.get("attemptRange")||safeRange;
  setAttemptRange(isDailyAnalysisRange(requestedAttempts)?requestedAttempts:safeRange);
 },[]);

 useEffect(()=>{
  if(!ready||!category||!questionId)return;
  if(!isDailyAnalysisCategory(category)){setError("This Daily Analysis question is unavailable.");setLoading(false);return;}
  let alive=true;
  if(data)setAttemptBusy(true);else setLoading(true);
  setError("");
  rpc<DailyAnalysisDetail>("english_get_daily_analysis_question_filtered",{
    p_category:category,
    p_question_id:questionId,
    p_category_range:categoryRange,
    p_attempt_range:attemptRange
  })
   .then(x=>alive&&setData(x))
   .catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not open this review.")))
   .finally(()=>{if(alive){setLoading(false);setAttemptBusy(false)}});
  return()=>{alive=false};
 // data is intentionally not a dependency; it only decides whether to show the small filter loader.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[ready,category,questionId,categoryRange,attemptRange]);

 function changeAttemptRange(next:DailyAnalysisRange){
  setAttemptRange(next);
  if(typeof window!=="undefined"){
    const qs=new URLSearchParams(window.location.search);qs.set("attemptRange",next);
    window.history.replaceState(window.history.state,"",`${window.location.pathname}?${qs.toString()}`);
  }
 }

 if(!ready)return null;
 const meta=categoryMeta(category);
 const q=data?.question,a=data?.analysis;
 const correct=String(q?.correctKey||"").toUpperCase();
 const selected=String(a?.latestSelected||"").toUpperCase();
 const backHref=category?`/english/revision/ai-intelligence/daily-analysis/questions?category=${encodeURIComponent(category)}&range=${categoryRange}`:"/english/revision/ai-intelligence/daily-analysis";
 const periodAttempts=a?.periodAttempts??0,periodWrong=a?.periodWrong??0;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page daily-analysis-page daily-analysis-detail-page">
  <PageHeader back={<Link href={backHref} className="back-link">← {meta?.title||"Daily Analysis"}</Link>} eyebrow="Read-only review" title={a?.displayName||"Question review"} subtitle="Correct answer is shown for manual weakness review."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Opening review…</div>:q&&a?<>
   <section className="daily-analysis-evidence-strip">
    <span><b>{stateLabel(a.currentState)}</b><small>current state</small></span>
    <span><b>{periodWrong} / {periodAttempts}</b><small>wrong / attempts · {rangeLabel(categoryRange)}</small></span>
    <span><b>{a.totalWrong} / {a.totalAttempts}</b><small>wrong / attempts · lifetime</small></span>
   </section>
   <section className="daily-review-card">
    <div className="daily-review-meta"><span>{q.topic||a.topic}</span>{a.dailyReason&&<span>{a.dailyReason}</span>}{q.revisionApplied&&<span>AI revision in use</span>}</div>
    <h2>{q.question}</h2>
    <div className="daily-review-options">{(q.options||[]).map(opt=>{
      const key=String(opt.key||"").toUpperCase();
      const isCorrect=key===correct;
      const isSelected=key===selected;
      const cls=isCorrect?"correct":isSelected?"selected-wrong":"";
      return <div className={`daily-review-option ${cls}`} key={key}><b>{key}</b><span>{opt.text}</span><em>{isCorrect?"Correct answer":isSelected?"Your answer":""}</em></div>;
    })}</div>
    <div className="daily-review-answer"><span>Correct answer</span><b>{correct||"—"}</b>{selected&&<small>Your latest in {rangeLabel(categoryRange).toLowerCase()}: {selected} · {a.latestCorrect?"Correct":"Wrong"}</small>}</div>
   </section>
   {q.explanation&&<section className="daily-review-explanation"><span>Explanation</span><p>{q.explanation}</p>{q.example&&<p><b>Example:</b> {q.example}</p>}{q.tip&&<p><b>Tip:</b> {q.tip}</p>}</section>}
   <section className="daily-review-why"><span>Why it is here</span><p>{whyHere(category,a.dailyReason,a.conceptState,periodWrong,a.totalWrong,categoryRange)}</p></section>

   <section className="daily-review-attempts" aria-label="Review only · nothing is recorded here">
    <div className="daily-review-section-head">
     <span><h2>Recent attempts</h2><small>{attemptSummaryText(data)}</small></span>
     <RangeFilter value={attemptRange} onChange={changeAttemptRange}/>
    </div>
    {attemptBusy?<div className="daily-attempt-filter-loading">Updating attempts…</div>:data.recentAttempts?.length?<div className="daily-review-attempt-list">{data.recentAttempts.map((x,i)=><div className="daily-review-attempt" key={`${x.attemptedAt}-${i}`}><span><b>{x.selected||"—"}</b><small>{formatAttemptTime(x.attemptedAt)}{x.module?` · ${moduleLabel(x.module)}`:""}</small></span><em className={x.correct?"ok":"bad"}>{x.correct?"Correct":"Wrong"}</em></div>)}</div>:<div className="daily-attempt-empty">No attempts in {rangeLabel(attemptRange).toLowerCase()}.</div>}
   </section>
  </>:!error?<div className="learner-empty">Question unavailable.</div>:null}
 </main>;
}

function RangeFilter({value,onChange}:{value:DailyAnalysisRange;onChange:(value:DailyAnalysisRange)=>void}){
 return <div className="daily-analysis-range-filter attempt-range-filter" role="group" aria-label="Attempt period">{DAILY_ANALYSIS_RANGES.map(item=><button key={item.key} type="button" className={value===item.key?"active":""} aria-pressed={value===item.key} onClick={()=>onChange(item.key)}>{item.label}</button>)}</div>;
}

function attemptSummaryText(data:DailyAnalysisDetail){
 const s=data.attemptSummary;
 if(!s||s.total===0)return "No attempts in this period";
 if(s.range==="overall"&&s.truncated)return `Latest ${s.shown}: ${s.shownCorrect} correct · ${s.shownWrong} wrong · ${s.total} lifetime`;
 return `${s.correct} correct · ${s.wrong} wrong · ${s.total} attempts`;
}

function whyHere(category:string,dailyReason?:string,conceptState?:string,periodWrong=0,totalWrong=0,range:DailyAnalysisRange="today"){
 const period=rangeLabel(range).toLowerCase();
 if(category==="persistent_weak")return periodWrong>0?`It entered the selected Daily period as Persistent Weak and was wrong ${periodWrong} time${periodWrong===1?"":"s"} in ${period}.`:`It entered the selected Daily period as Persistent Weak because the weakness has persisted across practice.`;
 if(category==="weak")return periodWrong>0?`It entered the selected Daily period as Weak and was missed again in ${period}.`:"It entered Daily as Weak based on repeated error evidence.";
 if(category==="retention_risk")return `The concept was recorded as ${stateLabel(conceptState||"retention_risk")} for this Daily review evidence: earlier learning was not holding reliably enough.`;
 if(category==="fragile_learning")return `It entered Daily as ${dailyReason||"Fragile / Learning"}; the concept is still stabilising.`;
 if(category==="due_revision")return "It entered Daily for spaced revision. Review the answer pattern rather than memorising the option position.";
 return totalWrong?`This item has ${totalWrong} recorded wrong attempt${totalWrong===1?"":"s"}.`:"This item is part of Daily review.";
}
function moduleLabel(value:string){return String(value||"").replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase())}

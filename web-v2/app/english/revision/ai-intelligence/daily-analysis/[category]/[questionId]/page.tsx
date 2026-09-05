"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { categoryMeta,formatAttemptTime,isDailyAnalysisCategory,stateLabel,type DailyAnalysisDetail } from "@/lib/daily-analysis";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function DailyAnalysisQuestionPage(){
 const ready=useAuthGuard();
 const params=useParams<{category:string;questionId:string}>();
 const category=useMemo(()=>String(params?.category||""),[params]);
 const questionId=useMemo(()=>decodeURIComponent(String(params?.questionId||"")),[params]);
 const meta=categoryMeta(category);
 const [data,setData]=useState<DailyAnalysisDetail|null>(null);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");
 useEffect(()=>{
  if(!ready)return;
  if(!isDailyAnalysisCategory(category)||!questionId){setError("This Daily Analysis question is unavailable.");setLoading(false);return;}
  let alive=true;
  rpc<DailyAnalysisDetail>("english_get_daily_analysis_question",{p_category:category,p_question_id:questionId})
   .then(x=>alive&&setData(x)).catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not open this review."))).finally(()=>alive&&setLoading(false));
  return()=>{alive=false};
 },[ready,category,questionId]);
 if(!ready)return null;
 const q=data?.question,a=data?.analysis;
 const correct=String(q?.correctKey||"").toUpperCase();
 const selected=String(a?.latestSelected||"").toUpperCase();
 return <main className="top-level-parity learner-rebuild-page learner-insights-page daily-analysis-page daily-analysis-detail-page">
  <PageHeader back={<Link href={`/english/revision/ai-intelligence/daily-analysis/${category}`} className="back-link">← {meta?.title||"Daily Analysis"}</Link>} eyebrow="Read-only review" title={a?.displayName||"Question review"} subtitle="Correct answer is shown so you can inspect the weakness manually."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Opening review…</div>:q&&a?<>
   <section className="daily-analysis-evidence-strip">
    <span><b>{stateLabel(a.currentState)}</b><small>current state</small></span>
    <span><b>{a.wrongToday}</b><small>wrong today</small></span>
    <span><b>{a.totalWrong} / {a.totalAttempts}</b><small>wrong / attempts</small></span>
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
    <div className="daily-review-answer"><span>Correct answer</span><b>{correct||"—"}</b>{selected&&<small>Your latest: {selected} · {a.latestCorrect?"Correct":"Wrong"}</small>}</div>
   </section>

   {q.explanation&&<section className="daily-review-explanation"><span>Explanation</span><p>{q.explanation}</p>{q.example&&<p><b>Example:</b> {q.example}</p>}{q.tip&&<p><b>Tip:</b> {q.tip}</p>}</section>}

   <section className="daily-review-why"><span>Why it is here</span><p>{whyHere(category,a.dailyReason,a.conceptState,a.wrongToday,a.totalWrong)}</p></section>

   {!!data.recentAttempts?.length&&<section className="daily-review-attempts"><div className="daily-review-section-head"><h2>Recent attempts</h2><small>Review only · nothing is recorded here</small></div><div className="daily-review-attempt-list">{data.recentAttempts.map((x,i)=><div className="daily-review-attempt" key={`${x.attemptedAt}-${i}`}><span><b>{x.selected||"—"}</b><small>{formatAttemptTime(x.attemptedAt)}{x.module?` · ${moduleLabel(x.module)}`:""}</small></span><em className={x.correct?"ok":"bad"}>{x.correct?"Correct":"Wrong"}</em></div>)}</div></section>}
  </>:!error?<div className="learner-empty">Question unavailable.</div>:null}
 </main>;
}

function whyHere(category:string,dailyReason?:string,conceptState?:string,wrongToday=0,totalWrong=0){
 if(category==="persistent_weak")return wrongToday>0?`It entered today’s Daily as Persistent Weak and was wrong ${wrongToday} time${wrongToday===1?"":"s"} today.`:`It entered today’s Daily as Persistent Weak because the weakness has persisted across practice.`;
 if(category==="weak")return wrongToday>0?`It entered today’s Daily as Weak and was missed again today.`:`It entered today’s Daily as Weak based on repeated error evidence.`;
 if(category==="retention_risk")return `The concept is currently marked ${stateLabel(conceptState||"retention_risk")}: earlier learning is not holding reliably enough.`;
 if(category==="fragile_learning")return `It entered today’s Daily as ${dailyReason||"Fragile / Learning"}; the concept is still stabilising.`;
 if(category==="due_revision")return `It entered today’s Daily for spaced revision. Review the answer pattern rather than memorising the option position.`;
 return totalWrong?`This item has ${totalWrong} recorded wrong attempt${totalWrong===1?"":"s"}.`:"This item is part of today’s Daily review.";
}
function moduleLabel(value:string){return String(value||"").replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase())}

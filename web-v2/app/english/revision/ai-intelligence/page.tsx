"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import type { DailyAnalysisSummary } from "@/lib/daily-analysis";
import type { Updates } from "@/lib/learning-ai-updates";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type WorkerState={healthy:boolean;lastRun?:string;status?:string};
type WorkerHealth={workers:{semantic:WorkerState;learning:WorkerState;quality:WorkerState};queued:number;processing:number;retrying:number;failed7d:number;oldestPendingAt?:string};
type QualityItem={reviewId:string;questionId:string;displayName:string;topic?:string;learnerNote?:string;status:string;verdict?:"valid"|"issue_suspected";rationale?:string;confidence?:number;markedAnswer?:string;recommendedAnswer?:string;createdAt:string;reviewedAt?:string};
type QualityUpdates={ok:boolean;summary:{total:number;pending:number;reviewed:number;valid:number;issues:number;failed:number};items:QualityItem[]};

export default function LearningInsightsPage(){
 const ready=useAuthGuard();
 const [updates,setUpdates]=useState<Updates|null>(null);
 const [workerHealth,setWorkerHealth]=useState<WorkerHealth|null>(null);
 const [quality,setQuality]=useState<QualityUpdates|null>(null);
 const [dailyAnalysis,setDailyAnalysis]=useState<DailyAnalysisSummary|null>(null);
 const [error,setError]=useState("");
 const [loading,setLoading]=useState(true);

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  Promise.all([
   rpc<Updates>("english_get_learning_ai_updates",{p_limit:40}),
   rpc<WorkerHealth>("english_get_ai_worker_health"),
   rpc<QualityUpdates>("english_get_question_quality_updates",{p_limit:20})
  ]).then(([u,w,q])=>{if(!alive)return;setUpdates(u);setWorkerHealth(w);setQuality(q)})
    .catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load Learning Insights.")))
    .finally(()=>alive&&setLoading(false));
  rpc<DailyAnalysisSummary>("english_get_daily_analysis_summary").then(x=>alive&&setDailyAnalysis(x)).catch(()=>{});
  return()=>{alive=false};
 },[ready]);

 if(!ready)return null;
 const summary=updates?.summary;
 const working=(summary?.contextPending||0)+(summary?.revisionWorking||0)+(quality?.summary.pending||0);
 const attention=(summary?.contextFailed||0)+(summary?.revisionFailed||0)+(quality?.summary.failed||0)+(quality?.summary.issues||0);
 const improved=(summary?.revisionReady||0)+(summary?.revisionApplied||0);

 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-only-insights-page">
  <PageHeader back={<Link href="/english/revision" className="back-link">← Revision</Link>} eyebrow="AI learning activity" title="Learning Insights" subtitle="See what AI understood and changed."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading AI updates…</div>:<>
   <section className="ai-hub-grid" aria-label="Learning Insights sections">
    <Link className="ai-hub-card tone-good" href="/english/revision/ai-intelligence/context">
     <span><b>What AI understood</b><small>Your context notes</small></span><strong>{summary?.contextDone||0}</strong><i>›</i>
    </Link>
    <Link className="ai-hub-card tone-soon" href="/english/revision/ai-intelligence/improvements">
     <span><b>Question improvements</b><small>Ready revisions</small></span><strong>{improved}</strong><i>›</i>
    </Link>
    <div className="ai-hub-card tone-good static"><span><b>Answer doubts</b><small>Independent AI reviews</small></span><strong>{quality?.summary.reviewed||0}</strong></div>
    <div className="ai-hub-card tone-later static"><span><b>AI working</b><small>In progress</small></span><strong>{working}</strong></div>
    <div className={`ai-hub-card ${attention?"tone-fix":"tone-neutral"} static`}><span><b>Needs attention</b><small>Failed checks or flagged answers</small></span><strong>{attention}</strong></div>
   </section>

   {!!quality?.items?.length&&<section className="learner-section">
    <div className="section-title-line"><h2>Answer doubt reviews</h2><span className="muted">{quality.summary.pending?`${quality.summary.pending} waiting`:"Up to date"}</span></div>
    <div className="ai-focused-list">{quality.items.slice(0,8).map(item=><QualityReviewItem key={item.reviewId} item={item}/>)}</div>
   </section>}

   {workerHealth&&<details className="insights-how-details learner-section ai-health-details"><summary><span><b>Background AI health</b><small>Technical status only.</small></span></summary><div className="insights-how-copy"><p><b>Understanding:</b> {healthText(workerHealth.workers.semantic)} · <b>Learning:</b> {healthText(workerHealth.workers.learning)} · <b>Question quality:</b> {healthText(workerHealth.workers.quality)}</p><p><b>Queued:</b> {workerHealth.queued} · <b>Processing:</b> {workerHealth.processing} · <b>Retrying:</b> {workerHealth.retrying} · <b>Failed (7d):</b> {workerHealth.failed7d}</p>{workerHealth.oldestPendingAt&&<p>Oldest pending: {timeAgo(workerHealth.oldestPendingAt)}</p>}</div></details>}

   <Link className="ai-daily-analysis-launch" href="/english/revision/ai-intelligence/daily-analysis">
    <span><b>Daily Analysis</b><small>Inspect today’s weak and due questions</small></span>
    <strong>{dailyAnalysis?.relevantCount??"…"}</strong><i>›</i>
   </Link>
  </>}
 </main>;
}

function QualityReviewItem({item}:{item:QualityItem}){
 const pending=item.status==="queued"||item.status==="processing";
 const valid=item.status==="reviewed"&&item.verdict==="valid";
 const issue=item.status==="reviewed"&&item.verdict==="issue_suspected";
 const summary=pending?"AI is independently checking the marked answer.":valid?"The marked answer was independently verified.":issue?"AI found a possible answer or ambiguity issue.":item.status==="failed"?"The review could not finish safely.":"Answer review recorded.";
 return <details className="ai-focused-item"><summary><span><b>{item.displayName}</b><small>{summary}</small></span><em>{pending?"Reviewing":valid?"Verified":issue?"Check needed":item.status==="failed"?"Needs attention":"Recorded"} · {timeAgo(item.createdAt)}</em><i>›</i></summary><div className="ai-focused-body">
  {item.learnerNote&&<section className="ai-insight-detail-card"><span className="ai-detail-kicker">Your doubt</span><p>{item.learnerNote}</p></section>}
  <section className={`ai-insight-detail-card ${issue?"emphasis":""}`}><span className="ai-detail-kicker">AI review</span>
   {pending?<p>The review is queued in the background. Your canonical question remains unchanged while it is checked.</p>:item.status==="failed"?<p>The review service did not complete. The question was not changed.</p>:<>
    {valid&&item.markedAnswer&&<p><b>Conclusion:</b> “{item.markedAnswer}” remains the supported answer.</p>}
    {issue&&<p><b>Conclusion:</b> A possible content issue was found. The canonical question has not been changed automatically.{item.recommendedAnswer?` The review points to “${item.recommendedAnswer}” for verification.`:""}</p>}
    {item.rationale&&<p>{item.rationale}</p>}
   </>}
  </section>
 </div></details>;
}

function timeAgo(value:string){const t=new Date(value).getTime();if(!Number.isFinite(t))return"unknown";const mins=Math.max(0,Math.round((Date.now()-t)/60000));return mins<2?"just now":mins<60?`${mins} min ago`:mins<1440?`${Math.round(mins/60)} hr ago`:`${Math.round(mins/1440)} d ago`}
function healthText(x:WorkerState){return x?.healthy?"Healthy":x?.status?`Needs attention (${x.status})`:"No recent scheduler run"}

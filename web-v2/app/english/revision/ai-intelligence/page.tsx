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

export default function LearningInsightsPage(){
 const ready=useAuthGuard();
 const [updates,setUpdates]=useState<Updates|null>(null);
 const [workerHealth,setWorkerHealth]=useState<WorkerHealth|null>(null);
 const [dailyAnalysis,setDailyAnalysis]=useState<DailyAnalysisSummary|null>(null);
 const [error,setError]=useState("");
 const [loading,setLoading]=useState(true);

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  Promise.all([
   rpc<Updates>("english_get_learning_ai_updates",{p_limit:40}),
   rpc<WorkerHealth>("english_get_ai_worker_health")
  ]).then(([u,w])=>{if(!alive)return;setUpdates(u);setWorkerHealth(w)})
    .catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load Learning Insights.")))
    .finally(()=>alive&&setLoading(false));
  rpc<DailyAnalysisSummary>("english_get_daily_analysis_summary").then(x=>alive&&setDailyAnalysis(x)).catch(()=>{});
  return()=>{alive=false};
 },[ready]);

 if(!ready)return null;
 const summary=updates?.summary;
 const working=(summary?.contextPending||0)+(summary?.revisionWorking||0);
 const attention=(summary?.contextFailed||0)+(summary?.revisionFailed||0);
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
    <div className="ai-hub-card tone-later static"><span><b>AI working</b><small>In progress</small></span><strong>{working}</strong></div>
    <div className={`ai-hub-card ${attention?"tone-fix":"tone-neutral"} static`}><span><b>Needs attention</b><small>Failed checks</small></span><strong>{attention}</strong></div>
   </section>

   {workerHealth&&<details className="insights-how-details learner-section ai-health-details"><summary><span><b>Background AI health</b><small>Technical status only.</small></span></summary><div className="insights-how-copy"><p><b>Understanding:</b> {healthText(workerHealth.workers.semantic)} · <b>Learning:</b> {healthText(workerHealth.workers.learning)} · <b>Question quality:</b> {healthText(workerHealth.workers.quality)}</p><p><b>Queued:</b> {workerHealth.queued} · <b>Processing:</b> {workerHealth.processing} · <b>Retrying:</b> {workerHealth.retrying} · <b>Failed (7d):</b> {workerHealth.failed7d}</p>{workerHealth.oldestPendingAt&&<p>Oldest pending: {timeAgo(workerHealth.oldestPendingAt)}</p>}</div></details>}

   <Link className="ai-daily-analysis-launch" href="/english/revision/ai-intelligence/daily-analysis">
    <span><b>Daily Analysis</b><small>Inspect today’s weak and due questions</small></span>
    <strong>{dailyAnalysis?.relevantCount??"…"}</strong><i>›</i>
   </Link>
  </>}
 </main>;
}

function timeAgo(value:string){const t=new Date(value).getTime();if(!Number.isFinite(t))return"unknown";const mins=Math.max(0,Math.round((Date.now()-t)/60000));return mins<2?"just now":mins<60?`${mins} min ago`:`${Math.round(mins/60)} hr ago`}
function healthText(x:WorkerState){return x?.healthy?"Healthy":x?.status?`Needs attention (${x.status})`:"No recent scheduler run"}

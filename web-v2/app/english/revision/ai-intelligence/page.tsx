"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { LearnerRow, OverviewCard, PageHeader } from "@/components/learner-ui";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Tone="fix"|"soon"|"good"|"later"|"neutral";
type WorkerState={healthy:boolean;lastRun?:string;status?:string};
type WorkerHealth={workers:{semantic:WorkerState;learning:WorkerState;quality:WorkerState};queued:number;processing:number;retrying:number;failed7d:number;oldestPendingAt?:string};
type ContextUpdate={
 kind:"context";noteId:string;questionId:string;displayName:string;topic?:string;learnerNote:string;status:string;
 understood?:string;diagnosisType?:string;action?:string;urgency?:string;relatedTerms?:string[];requiresTransfer?:boolean;
 changedTargeted?:boolean;createdConfusion?:boolean;createdAt:string;processedAt?:string;
};
type RevisionPayload={question?:string;optionA?:string;optionB?:string;optionC?:string;optionD?:string;correctKey?:string;explanation?:string};
type RevisionUpdate={
 kind:"revision";proposalId:string;questionId:string;displayName:string;topic?:string;version:number;feedbackReason?:string;
 feedbackNote?:string;status:string;original?:RevisionPayload;revised?:RevisionPayload;qualityNote?:string;active?:boolean;
 errorCode?:string;createdAt:string;readyAt?:string;decidedAt?:string;
};
type UpdateSummary={contextTotal:number;contextDone:number;contextPending:number;contextFailed:number;revisionTotal:number;revisionReady:number;revisionWorking:number;revisionApplied:number;revisionFailed:number};
type Updates={ok:boolean;summary:UpdateSummary;contextUpdates:ContextUpdate[];revisionUpdates:RevisionUpdate[]};
type Detail={kind:"context";item:ContextUpdate}|{kind:"revision";item:RevisionUpdate};

export default function LearningInsightsPage(){
 const ready=useAuthGuard();
 const [updates,setUpdates]=useState<Updates|null>(null);
 const [workerHealth,setWorkerHealth]=useState<WorkerHealth|null>(null);
 const [detail,setDetail]=useState<Detail|null>(null);
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
  return()=>{alive=false};
 },[ready]);

 if(!ready)return null;
 if(detail?.kind==="context")return <ContextDetail item={detail.item} onBack={()=>setDetail(null)}/>;
 if(detail?.kind==="revision")return <RevisionDetail item={detail.item} onBack={()=>setDetail(null)}/>;

 const summary=updates?.summary;
 const working=(summary?.contextPending||0)+(summary?.revisionWorking||0);
 const attention=(summary?.contextFailed||0)+(summary?.revisionFailed||0);
 const improved=(summary?.revisionReady||0)+(summary?.revisionApplied||0);

 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-only-insights-page">
  <PageHeader back={<Link href="/english/revision" className="back-link">← Revision</Link>} eyebrow="AI learning activity" title="Learning Insights" subtitle="See what AI understood and exactly what it changed."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading AI updates…</div>:<>
   <section className="learner-section ai-insight-summary-section">
    <div className="learner-overview-stack ai-insight-summary-grid">
     <OverviewCard tone="good" title="Context analysed" subtitle="Your notes AI has interpreted." count={summary?.contextDone||0}/>
     <OverviewCard tone="soon" title="Question improvements" subtitle="Revisions ready or already used." count={improved}/>
     <OverviewCard tone="later" title="AI working" subtitle="Analysis or revisions still in progress." count={working}/>
     <OverviewCard tone={attention?"fix":"neutral"} title="Needs attention" subtitle="Updates that did not pass processing or quality checks." count={attention}/>
    </div>
   </section>

   <section className="learner-section ai-update-section">
    <div className="learner-section-head"><div><h2>What AI understood</h2><p>Actual interpretation of the context you gave while studying.</p></div></div>
    {updates?.contextUpdates?.length?<div className="learner-row-list">{updates.contextUpdates.map(item=><LearnerRow key={item.noteId} title={item.displayName} subtitle={contextSummary(item)} status={`${contextStatus(item.status)} · ${timeAgo(item.createdAt)}`} tone={contextTone(item.status)} onClick={()=>setDetail({kind:"context",item})}/>)}</div>:<div className="learner-empty">No AI context analysis yet.</div>}
   </section>

   <section className="learner-section ai-update-section">
    <div className="learner-section-head"><div><h2>Question improvements</h2><p>See the original version, revised version, and the exact options AI changed.</p></div></div>
    {updates?.revisionUpdates?.length?<div className="learner-row-list">{updates.revisionUpdates.map(item=><LearnerRow key={item.proposalId} title={item.displayName} subtitle={revisionSummary(item)} status={`${revisionStatus(item.status)} · ${timeAgo(item.createdAt)}`} tone={revisionTone(item.status)} onClick={()=>setDetail({kind:"revision",item})}/>)}</div>:<div className="learner-empty">No question improvement requests yet.</div>}
   </section>

   {workerHealth&&<details className="insights-how-details learner-section ai-health-details"><summary><span><b>Background AI health</b><small>Technical status only. It does not change your mastery score.</small></span></summary><div className="insights-how-copy"><p><b>Understanding:</b> {healthText(workerHealth.workers.semantic)} · <b>Learning:</b> {healthText(workerHealth.workers.learning)} · <b>Question quality:</b> {healthText(workerHealth.workers.quality)}</p><p><b>Queued:</b> {workerHealth.queued} · <b>Processing:</b> {workerHealth.processing} · <b>Retrying:</b> {workerHealth.retrying} · <b>Failed (7d):</b> {workerHealth.failed7d}</p>{workerHealth.oldestPendingAt&&<p>Oldest pending: {timeAgo(workerHealth.oldestPendingAt)}</p>}</div></details>}
  </>}
 </main>;
}

function ContextDetail({item,onBack}:{item:ContextUpdate;onBack:()=>void}){
 const changes=contextChanges(item);
 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-insight-detail-page">
  <button className="learner-back" type="button" onClick={onBack}>← Learning Insights</button>
  <PageHeader eyebrow={item.topic||"English"} title={item.displayName} subtitle={`${contextStatus(item.status)} · ${timeAgo(item.createdAt)}`}/>
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">What you told AI</span><p>{item.learnerNote||"No written note was saved."}</p></section>
  <section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">What AI understood</span><p>{item.understood||contextFallback(item.status)}</p></section>
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">What changed</span>{changes.length?<ul>{changes.map((x,i)=><li key={`${i}-${x}`}>{x}</li>)}</ul>:<p>{item.status==="done"?"AI did not change your study plan from this note.":"No change has been applied yet."}</p>}</section>
 </main>;
}

function RevisionDetail({item,onBack}:{item:RevisionUpdate;onBack:()=>void}){
 const changed=changedOptionKeys(item.original,item.revised);
 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-insight-detail-page">
  <button className="learner-back" type="button" onClick={onBack}>← Learning Insights</button>
  <PageHeader eyebrow={item.topic||"English"} title={item.displayName} subtitle={`${revisionStatus(item.status)} · ${feedbackLabel(item.feedbackReason)}`}/>
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">Your feedback</span><p>{item.feedbackNote||feedbackLabel(item.feedbackReason)}</p></section>
  {item.revised?<div className="ai-revision-compare">
   <RevisionVersion title="Original version" payload={item.original}/>
   <RevisionVersion title="AI revision" payload={item.revised} compare={item.original}/>
   <section className="ai-insight-detail-card change-summary"><span className="ai-detail-kicker">What changed</span><p>{revisionChangeText(item.original,item.revised,changed)}</p>{item.qualityNote&&<p className="ai-quality-note"><b>Quality check:</b> {item.qualityNote}</p>}</section>
  </div>:<section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">AI revision</span><p>{revisionFallback(item.status)}</p></section>}
 </main>;
}

function RevisionVersion({title,payload,compare}:{title:string;payload?:RevisionPayload;compare?:RevisionPayload}){
 if(!payload)return <section className="ai-insight-detail-card"><span className="ai-detail-kicker">{title}</span><p>Version unavailable.</p></section>;
 const questionChanged=!!compare&&clean(compare.question)!==clean(payload.question);
 return <section className="ai-insight-detail-card ai-revision-version"><span className="ai-detail-kicker">{title}</span><p className={questionChanged?"ai-field-changed":""}>{payload.question||"Question text unavailable."}</p><div className="ai-option-compare">{(["A","B","C","D"] as const).map(key=>{const text=option(payload,key),was=compare?option(compare,key):"";const changed=!!compare&&clean(was)!==clean(text);return <div className={`ai-option-line ${changed?"changed":""}`} key={key}><b>{key}</b><span>{text||"—"}</span>{changed&&<em>changed</em>}</div>})}</div>{payload.explanation&&<details className="ai-explanation-detail"><summary>Explanation</summary><p>{payload.explanation}</p></details>}</section>;
}

function option(payload:RevisionPayload|undefined,key:"A"|"B"|"C"|"D"){if(!payload)return"";return key==="A"?payload.optionA||"":key==="B"?payload.optionB||"":key==="C"?payload.optionC||"":payload.optionD||""}
function clean(v?:string){return String(v||"").trim()}
function changedOptionKeys(a?:RevisionPayload,b?:RevisionPayload){if(!a||!b)return[] as string[];return (["A","B","C","D"] as const).filter(k=>clean(option(a,k))!==clean(option(b,k)))}
function revisionChangeText(a:RevisionPayload|undefined,b:RevisionPayload|undefined,changed:string[]){if(!a||!b)return"The revised version is ready.";const parts:string[]=[];if(clean(a.question)!==clean(b.question))parts.push("question wording");if(changed.length)parts.push(`option${changed.length===1?"":"s"} ${changed.join(", ")}`);if(clean(a.explanation)!==clean(b.explanation))parts.push("explanation");return parts.length?`AI changed ${joinNatural(parts)}.`:"AI kept the question, options and explanation unchanged after review."}
function joinNatural(parts:string[]){if(parts.length<2)return parts[0]||"";if(parts.length===2)return`${parts[0]} and ${parts[1]}`;return`${parts.slice(0,-1).join(", ")}, and ${parts.at(-1)}`}

function contextSummary(item:ContextUpdate){if(item.understood)return clip(item.understood,150);if(item.status==="processing")return"AI is analysing what this note means for your learning.";if(item.status==="queued"||item.status==="pending")return"Waiting for AI analysis.";if(item.status==="failed")return"The analysis did not complete successfully.";return"AI analysis completed."}
function contextChanges(item:ContextUpdate){const out:string[]=[];if(item.createdConfusion)out.push("Created a confusion pair for focused practice.");if(item.changedTargeted)out.push("Added or updated focused work in Targeted Mastery.");if(item.requiresTransfer)out.push("Added a fresh understanding check so the idea is tested in a new form.");if(item.relatedTerms?.length)out.push(`Connected this with: ${item.relatedTerms.join(", ")}.`);return out}
function contextFallback(status:string){if(status==="processing")return"AI is still analysing this note.";if(status==="queued"||status==="pending")return"This note is waiting for AI analysis.";if(status==="failed")return"AI could not finish this analysis. The note remains saved.";return"AI finished processing this note, but no separate interpretation was stored."}
function contextStatus(status:string){return status==="done"?"Analysed":status==="processing"?"Analysing":status==="queued"?"Queued":status==="failed"?"Needs attention":"Waiting"}
function contextTone(status:string):Tone{return status==="done"?"good":status==="failed"?"fix":status==="processing"||status==="queued"?"soon":"later"}

function feedbackLabel(reason?:string){const x=String(reason||"").toLowerCase();if(x==="options_too_obvious")return"Options were too obvious";if(x==="distractors_unrelated")return"Distractors were unrelated";if(x==="explanation_weak")return"Explanation was weak";if(x==="answer_doubtful")return"Correct answer looked doubtful";if(x==="custom")return"Custom improvement request";return x?x.replaceAll("_"," "):"Question improvement"}
function revisionSummary(item:RevisionUpdate){if(item.revised){const changed=changedOptionKeys(item.original,item.revised);if(changed.length)return`AI changed option${changed.length===1?"":"s"} ${changed.join(", ")} after your feedback.`;if(clean(item.original?.question)!==clean(item.revised.question))return"AI rewrote the question while preserving the intended skill.";return"AI prepared a revised version and quality-checked it."}if(item.status==="failed")return"AI rejected the draft because it did not pass the quality gate.";if(item.status==="processing"||item.status==="queued")return"AI is working on a safer, stronger version.";return feedbackLabel(item.feedbackReason)}
function revisionStatus(status:string){return status==="ready"?"Ready to review":status==="applied"?"In use":status==="kept"?"Original kept":status==="processing"?"Improving":status==="queued"?"Queued":status==="failed"?"No safe revision":status==="superseded"?"Updated again":"Recorded"}
function revisionTone(status:string):Tone{return status==="applied"?"good":status==="ready"||status==="processing"||status==="queued"?"soon":status==="failed"?"fix":status==="kept"?"neutral":"later"}
function revisionFallback(status:string){if(status==="failed")return"AI did not show a rejected draft. It failed the quality gate, so your current question remains unchanged.";if(status==="processing"||status==="queued")return"AI is still working on this request. No revision has been applied yet.";if(status==="superseded")return"A newer improvement request replaced this one.";return"No revised version is available for this request."}

function clip(value:string,max:number){const s=String(value||"").trim();return s.length<=max?s:`${s.slice(0,max-1).trimEnd()}…`}
function timeAgo(value:string){const t=new Date(value).getTime();if(!Number.isFinite(t))return"unknown";const mins=Math.max(0,Math.round((Date.now()-t)/60000));return mins<2?"just now":mins<60?`${mins} min ago`:mins<1440?`${Math.round(mins/60)} hr ago`:`${Math.round(mins/1440)} d ago`}
function healthText(x:WorkerState){return x?.healthy?"Healthy":x?.status?`Needs attention (${x.status})`:"No recent scheduler run"}

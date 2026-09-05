"use client";

import Link from "next/link";
import { useEffect,useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { changedOptionKeys,clean,feedbackLabel,option,revisionChangeText,revisionFallback,revisionStatus,revisionSummary,timeAgo,type RevisionPayload,type RevisionUpdate,type Updates } from "@/lib/learning-ai-updates";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function ImprovementInsightsPage(){
 const ready=useAuthGuard();
 const [items,setItems]=useState<RevisionUpdate[]>([]);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");
 useEffect(()=>{if(!ready)return;let alive=true;rpc<Updates>("english_get_learning_ai_updates",{p_limit:60}).then(x=>alive&&setItems(x.revisionUpdates||[])).catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load question improvements."))).finally(()=>alive&&setLoading(false));return()=>{alive=false}},[ready]);
 if(!ready)return null;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-insight-list-page">
  <PageHeader back={<Link href="/english/revision/ai-intelligence" className="back-link">← Learning Insights</Link>} eyebrow="Question feedback" title="Question improvements" subtitle="Only questions you asked AI to improve."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading improvements…</div>:items.length?<section className="ai-focused-list">{items.map(item=><ImprovementItem key={item.proposalId} item={item}/>)}</section>:<div className="learner-empty">No question improvement requests yet.</div>}
 </main>;
}

function ImprovementItem({item}:{item:RevisionUpdate}){
 return <details className="ai-focused-item"><summary><span><b>{item.displayName}</b><small>{revisionSummary(item)}</small></span><em>{revisionStatus(item.status)} · {timeAgo(item.createdAt)}</em><i>›</i></summary><div className="ai-focused-body">
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">Your feedback</span><p>{item.feedbackNote||feedbackLabel(item.feedbackReason)}</p></section>
  {item.revised?<>
   <RevisionVersion title="Original version" payload={item.original}/>
   <RevisionVersion title="AI revision" payload={item.revised} compare={item.original}/>
   <section className="ai-insight-detail-card change-summary"><span className="ai-detail-kicker">What changed</span><p>{revisionChangeText(item.original,item.revised)}</p>{item.qualityNote&&<p className="ai-quality-note"><b>Quality check:</b> {item.qualityNote}</p>}</section>
  </>:<section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">AI revision</span><p>{revisionFallback(item.status)}</p></section>}
 </div></details>;
}

function RevisionVersion({title,payload,compare}:{title:string;payload?:RevisionPayload;compare?:RevisionPayload}){
 if(!payload)return <section className="ai-insight-detail-card"><span className="ai-detail-kicker">{title}</span><p>Version unavailable.</p></section>;
 const questionChanged=!!compare&&clean(compare.question)!==clean(payload.question);
 const changed=changedOptionKeys(compare,payload);
 return <section className="ai-insight-detail-card ai-revision-version"><span className="ai-detail-kicker">{title}</span><p className={questionChanged?"ai-field-changed":""}>{payload.question||"Question text unavailable."}</p><div className="ai-option-compare">{(["A","B","C","D"] as const).map(key=>{const text=option(payload,key);const isChanged=changed.includes(key);return <div className={`ai-option-line ${isChanged?"changed":""}`} key={key}><b>{key}</b><span>{text||"—"}</span>{isChanged&&<em>changed</em>}</div>})}</div>{payload.explanation&&<details className="ai-explanation-detail"><summary>Explanation</summary><p>{payload.explanation}</p></details>}</section>;
}

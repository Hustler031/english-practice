"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { contextChanges,contextFallback,contextStatus,contextSummary,timeAgo,type ContextUpdate,type Updates } from "@/lib/learning-ai-updates";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function ContextInsightsPage(){
 const ready=useAuthGuard();
 const [items,setItems]=useState<ContextUpdate[]>([]);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");
 useEffect(()=>{if(!ready)return;let alive=true;rpc<Updates>("english_get_learning_ai_updates",{p_limit:60}).then(x=>alive&&setItems(x.contextUpdates||[])).catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load AI context updates."))).finally(()=>alive&&setLoading(false));return()=>{alive=false}},[ready]);
 if(!ready)return null;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-insight-list-page">
  <PageHeader back={<Link href="/english/revision/ai-intelligence" className="back-link">← Learning Insights</Link>} eyebrow="Context notes" title="What AI understood" subtitle="Only questions where you added context."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading context analysis…</div>:items.length?<section className="ai-focused-list">{items.map(item=><ContextItem key={item.noteId} item={item}/>)}</section>:<div className="learner-empty">No context notes yet.</div>}
 </main>;
}

function ContextItem({item}:{item:ContextUpdate}){
 const changes=contextChanges(item);
 return <details className="ai-focused-item"><summary><span><b>{item.displayName}</b><small>{contextSummary(item)}</small></span><em>{contextStatus(item.status)} · {timeAgo(item.createdAt)}</em><i>›</i></summary><div className="ai-focused-body">
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">What you told AI</span><p>{item.learnerNote||"No written note was saved."}</p></section>
  <section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">What AI understood</span><p>{item.understood||contextFallback(item.status)}</p></section>
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">What changed</span>{changes.length?<ul>{changes.map((x,i)=><li key={`${item.noteId}-${i}`}>{x}</li>)}</ul>:<p>{item.status==="done"?"No extra study action was needed.":"No change has been applied yet."}</p>}</section>
 </div></details>;
}

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
  <PageHeader back={<Link href="/english/revision/ai-intelligence" className="back-link">← Learning Insights</Link>} eyebrow="Question feedback" title="Question improvements" subtitle="What you asked, what AI changed, and the exact revised content."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading improvements…</div>:items.length?<section className="ai-focused-list">{items.map(item=><ImprovementItem key={item.proposalId} item={item}/>)}</section>:<div className="learner-empty">No question improvement requests yet.</div>}
 </main>;
}

function ImprovementItem({item}:{item:RevisionUpdate}){
 return <details className="ai-focused-item"><summary><span><b>{item.displayName}</b><small>{revisionSummary(item)}</small></span><em>{revisionStatus(item.status)} · {timeAgo(item.createdAt)}</em><i>›</i></summary><div className="ai-focused-body">
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">You asked</span><p>{item.feedbackNote||feedbackLabel(item.feedbackReason)}</p></section>
  <section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">AI did</span>
   {item.revised?<><p>{revisionChangeText(item.original,item.revised)}</p><ChangePreview original={item.original} revised={item.revised}/></>:<p>{revisionFallback(item.status)}</p>}
  </section>
  {item.original&&<details className="insights-how-details"><summary><span><b>Original version</b><small>Open only if you want to compare</small></span></summary><div className="insights-how-copy"><RevisionVersion title="Original version" payload={item.original}/></div></details>}
  {item.qualityNote&&<details className="insights-how-details"><summary><span><b>Quality check</b><small>Why this AI revision passed</small></span></summary><div className="insights-how-copy"><p>{item.qualityNote}</p></div></details>}
  <ReviseAgain questionId={item.questionId}/>
 </div></details>;
}

function ChangePreview({original,revised}:{original?:RevisionPayload;revised?:RevisionPayload}){
 if(!revised)return null;
 const changed=changedOptionKeys(original,revised);
 const questionChanged=!!original&&clean(original.question)!==clean(revised.question);
 const explanationChanged=!original||clean(original.explanation)!==clean(revised.explanation);
 return <div className="ai-revision-version ai-mobile-change-preview">
  <span className="ai-detail-kicker ai-change-kicker">What changed · AI revision</span>
  {questionChanged&&revised.question&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">New question wording</span><p>{revised.question}</p></div>}
  {!!changed.length&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">Changed options</span><div className="ai-option-compare">{changed.map(key=><div className="ai-option-line changed" key={key}><b>{key}</b><span>{option(revised,key)}</span><em>changed</em></div>)}</div></div>}
  {explanationChanged&&revised.explanation&&<div className="ai-insight-detail-card ai-readable-explanation"><span className="ai-detail-kicker">New explanation</span><p>{revised.explanation}</p></div>}
  {!questionChanged&&!changed.length&&!explanationChanged&&<p>AI reviewed the item and kept the visible content unchanged.</p>}
 </div>;
}

function RevisionVersion({title,payload}:{title:string;payload?:RevisionPayload}){
 if(!payload)return null;
 return <section className="ai-insight-detail-card ai-revision-version"><span className="ai-detail-kicker">{title}</span><p>{payload.question||"Question text unavailable."}</p><div className="ai-option-compare">{(["A","B","C","D"] as const).map(key=><div className="ai-option-line" key={key}><b>{key}</b><span>{option(payload,key)||"—"}</span></div>)}</div>{payload.explanation&&<details className="ai-explanation-detail"><summary>Explanation</summary><p>{payload.explanation}</p></details>}</section>;
}

function ReviseAgain({questionId}:{questionId:string}){
 const [open,setOpen]=useState(false),[note,setNote]=useState(""),[busy,setBusy]=useState(false),[message,setMessage]=useState(""),[error,setError]=useState("");
 async function submit(){if(busy||note.trim().length<2)return;setBusy(true);setError("");setMessage("");try{await rpc("english_save_context_note",{p_question_id:questionId,p_note:note.trim(),p_attempt_id:null,p_context_snapshot:{route:"Learning Insights",module:"learninginsights"}});setMessage("Sent to AI. You can keep studying while it works in the background.");setNote("");setOpen(false)}catch(e:any){setError(learnerErrorMessage(e,"Could not send this follow-up."))}finally{setBusy(false)}}
 return <div className="question-revision-actions ai-revise-again">
  <button className="btn ghost" type="button" onClick={()=>{setOpen(v=>!v);setMessage("");setError("")}}>Revise again</button>
  {open&&<div className="ai-help-panel question-improve-sheet"><strong>What should AI revise now?</strong><span>Write naturally. You can ask for a simpler explanation, all option meanings, closer distractors, examples, or describe the remaining doubt.</span><input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Example: explanation is better, but show why B and C are wrong too"/><button className="btn primary" type="button" disabled={busy||note.trim().length<2} onClick={()=>void submit()}>{busy?"Sending…":"Send to AI"}</button></div>}
  {message&&<div className="context-saved">{message}</div>}{error&&<div className="error-box">{error}</div>}
 </div>;
}

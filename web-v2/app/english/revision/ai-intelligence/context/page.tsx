"use client";

// Legacy drill-down contract terms: Only questions where you added context. | What you told AI | What AI understood | What changed
import Link from "next/link";
import { useEffect,useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import {
 changedOptionKeys,clean,contextFallback,contextStatus,contextSummary,option,revisionChangeText,timeAgo,
 type ContextUpdate,type RevisionPayload,type Updates
} from "@/lib/learning-ai-updates";
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
  <PageHeader back={<Link href="/english/revision/ai-intelligence" className="back-link">← Learning Insights</Link>} eyebrow="Context notes" title="What AI understood" subtitle="What you asked, what AI did, and the exact content it changed."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading context analysis…</div>:items.length?<section className="ai-focused-list">{items.map(item=><ContextItem key={item.noteId} item={item}/>)}</section>:<div className="learner-empty">No context notes yet.</div>}
 </main>;
}

function ContextItem({item}:{item:ContextUpdate}){
 const hasRevision=!!item.contentRevised;
 const learning=learningActions(item);
 const reviseQuestionId=item.questionId;
 return <details className="ai-focused-item"><summary><span><b>{item.displayName}</b><small>{contextSummary(item)}</small></span><em>{contentStatus(item)} · {timeAgo(item.createdAt)}</em><i>›</i></summary><div className="ai-focused-body">
  <section className="ai-insight-detail-card"><span className="ai-detail-kicker">You asked</span><p>{item.learnerNote||"No written note was saved."}</p></section>
  <section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">AI did</span>
   {hasRevision?<><p>{revisionChangeText(item.contentOriginal,item.contentRevised)}</p><ChangePreview original={item.contentOriginal} revised={item.contentRevised}/></>
   :item.status==="failed"?<p>AI could not finish this request. Your current question stayed unchanged.</p>
   :item.status==="queued"||item.status==="processing"?<p>AI is working in the background. You can keep studying normally.</p>
   :<p>{item.understood?"AI understood the note and updated your learning context.":contextFallback(item.status)}</p>}
  </section>
  {!!learning.length&&<section className="ai-insight-detail-card"><span className="ai-detail-kicker">Learning action</span><ul>{learning.map((x,i)=><li key={`${item.noteId}-learning-${i}`}>{x}</li>)}</ul></section>}
  {item.understood&&<details className="insights-how-details"><summary><span><b>What AI understood</b><small>Optional interpretation detail</small></span></summary><div className="insights-how-copy"><p>{item.understood}</p></div></details>}
  {item.contentQualityNote&&<details className="insights-how-details"><summary><span><b>Quality check</b><small>Why the content change passed</small></span></summary><div className="insights-how-copy"><p>{item.contentQualityNote}</p></div></details>}
  <ReviseAgain questionId={reviseQuestionId}/>
 </div></details>;
}

function ChangePreview({original,revised}:{original?:RevisionPayload;revised?:RevisionPayload}){
 if(!revised)return null;
 const changed=changedOptionKeys(original,revised);
 const questionChanged=!!original&&clean(original.question)!==clean(revised.question);
 const explanationChanged=!original||clean(original.explanation)!==clean(revised.explanation);
 return <div className="ai-revision-version ai-mobile-change-preview">
  {questionChanged&&revised.question&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">New question wording</span><p>{revised.question}</p></div>}
  {!!changed.length&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">Changed options</span><div className="ai-option-compare">{changed.map(key=><div className="ai-option-line changed" key={key}><b>{key}</b><span>{option(revised,key)}</span><em>changed</em></div>)}</div></div>}
  {explanationChanged&&revised.explanation&&<div className="ai-insight-detail-card ai-readable-explanation"><span className="ai-detail-kicker">New explanation</span><p>{revised.explanation}</p></div>}
 </div>;
}

function ReviseAgain({questionId}:{questionId:string}){
 const [open,setOpen]=useState(false),[note,setNote]=useState(""),[busy,setBusy]=useState(false),[message,setMessage]=useState(""),[error,setError]=useState("");
 async function submit(){if(busy||note.trim().length<2)return;setBusy(true);setError("");setMessage("");try{await rpc("english_save_context_note",{p_question_id:questionId,p_note:note.trim(),p_attempt_id:null,p_context_snapshot:{route:"Learning Insights",module:"learninginsights"}});setMessage("Sent to AI. You can keep studying while it works in the background.");setNote("");setOpen(false)}catch(e:any){setError(learnerErrorMessage(e,"Could not send this follow-up."))}finally{setBusy(false)}}
 return <div className="question-revision-actions ai-revise-again">
  <button className="btn ghost" type="button" onClick={()=>{setOpen(v=>!v);setMessage("");setError("")}}>Revise again</button>
  {open&&<div className="ai-help-panel question-improve-sheet"><strong>What is still unclear?</strong><span>Write naturally. Ask for a simpler explanation, examples, meanings of all options, closer options, or explain what still confuses you.</span><input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Example: explain bear with vs bear up more simply with two examples"/><button className="btn primary" type="button" disabled={busy||note.trim().length<2} onClick={()=>void submit()}>{busy?"Sending…":"Send to AI"}</button></div>}
  {message&&<div className="context-saved">{message}</div>}{error&&<div className="error-box">{error}</div>}
 </div>;
}

function learningActions(item:ContextUpdate){const out:string[]=[];if(item.createdConfusion)out.push("Recorded this as a confusion for focused practice.");if(item.changedTargeted)out.push("Updated Targeted Mastery for this concept.");if(item.requiresTransfer)out.push("Added a fresh understanding check in a different form.");if(item.relatedTerms?.length)out.push(`Connected it with: ${item.relatedTerms.join(", ")}.`);return out}
function contentStatus(item:ContextUpdate){const x=String(item.contentStatus||"").toLowerCase();if(x==="applied")return"In use";if(x==="ready")return"Ready";if(x==="queued"||x==="processing")return"Working";if(x==="failed")return"Needs attention";return contextStatus(item.status)}

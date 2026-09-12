"use client";

import Link from "next/link";
import { useEffect,useMemo,useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import {
 changedOptionKeys,clean,contextChanges,contextStatus,contextSummary,feedbackLabel,option,
 revisionChangeText,revisionFallback,revisionStatus,revisionSummary,timeAgo,
 type ContextUpdate,type RevisionPayload,type RevisionUpdate,type Updates
} from "@/lib/learning-ai-updates";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type FeedItem={kind:"context";createdAt:string;item:ContextUpdate}|{kind:"revision";createdAt:string;item:RevisionUpdate};

export default function LearningInsightsPage(){
 const ready=useAuthGuard();
 const [updates,setUpdates]=useState<Updates|null>(null);
 const [error,setError]=useState("");
 const [loading,setLoading]=useState(true);

 useEffect(()=>{
  if(!ready)return;
  let alive=true;
  rpc<Updates>("english_get_learning_ai_updates",{p_limit:60})
   .then(x=>alive&&setUpdates(x))
   .catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load Learning Insights.")))
   .finally(()=>alive&&setLoading(false));
  return()=>{alive=false};
 },[ready]);

 const feed=useMemo<FeedItem[]>(()=>{
  if(!updates)return[];
  const linked=new Set((updates.contextUpdates||[]).map(x=>x.contentProposalId).filter(Boolean));
  return [
   ...(updates.contextUpdates||[]).map(item=>({kind:"context" as const,createdAt:item.createdAt,item})),
   ...(updates.revisionUpdates||[]).filter(item=>!linked.has(item.proposalId)).map(item=>({kind:"revision" as const,createdAt:item.createdAt,item}))
  ].sort((a,b)=>new Date(b.createdAt).getTime()-new Date(a.createdAt).getTime());
 },[updates]);

 if(!ready)return null;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page ai-only-insights-page">
  <PageHeader back={<Link href="/english/revision" className="back-link">← Revision</Link>} eyebrow="AI change log" title="Learning Insights" subtitle="What you asked → what AI did. Open any item to read the new explanation or options."/>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading your AI changes…</div>:feed.length?
   <section className="ai-focused-list" aria-label="Your AI learning changes">
    {feed.map(row=>row.kind==="context"?<ContextInsight key={`c-${row.item.noteId}`} item={row.item}/>:<RevisionInsight key={`r-${row.item.proposalId}`} item={row.item}/>) }
   </section>
   :<div className="learner-empty">No AI changes yet. Use Add Context or Improve Question while practising.</div>}
 </main>;
}

function ContextInsight({item}:{item:ContextUpdate}){
 const changes=contextChanges(item);
 const hasRevision=!!item.contentRevised;
 const reviseQuestionId=item.questionId;
 return <details className="ai-focused-item">
  <summary><span><b>{item.displayName}</b><small>{contextSummary(item)}</small></span><em>{contentStatusLabel(item)} · {timeAgo(item.createdAt)}</em><i>›</i></summary>
  <div className="ai-focused-body">
   <section className="ai-insight-detail-card"><span className="ai-detail-kicker">You asked</span><p>{item.learnerNote||"No written note was saved."}</p></section>
   <section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">AI did</span>
    {hasRevision?<><p>{revisionChangeText(item.contentOriginal,item.contentRevised)}</p><ChangePreview original={item.contentOriginal} revised={item.contentRevised}/></>
    :changes.length?<ul>{changes.map((x,i)=><li key={`${item.noteId}-${i}`}>{x}</li>)}</ul>
    :item.status==="failed"?<p>AI could not finish this request. Your existing question was left unchanged.</p>
    :item.status==="queued"||item.status==="processing"?<p>AI is working in the background. You can keep studying normally.</p>
    :<p>Your note was saved. No question-content change was needed.</p>}
   </section>
   {item.contentQualityNote&&<details className="insights-how-details"><summary><span><b>Quality check</b><small>Why this change passed</small></span></summary><div className="insights-how-copy"><p>{item.contentQualityNote}</p></div></details>}
   <ReviseAgain questionId={reviseQuestionId}/>
  </div>
 </details>;
}

function RevisionInsight({item}:{item:RevisionUpdate}){
 const reviseQuestionId=item.questionId;
 return <details className="ai-focused-item">
  <summary><span><b>{item.displayName}</b><small>{revisionSummary(item)}</small></span><em>{revisionStatus(item.status)} · {timeAgo(item.createdAt)}</em><i>›</i></summary>
  <div className="ai-focused-body">
   <section className="ai-insight-detail-card"><span className="ai-detail-kicker">You asked</span><p>{item.feedbackNote||feedbackLabel(item.feedbackReason)}</p></section>
   <section className="ai-insight-detail-card emphasis"><span className="ai-detail-kicker">AI did</span>
    {item.revised?<><p>{revisionChangeText(item.original,item.revised)}</p><ChangePreview original={item.original} revised={item.revised}/></>:<p>{revisionFallback(item.status)}</p>}
   </section>
   {item.qualityNote&&<details className="insights-how-details"><summary><span><b>Quality check</b><small>Why this change passed</small></span></summary><div className="insights-how-copy"><p>{item.qualityNote}</p></div></details>}
   <ReviseAgain questionId={reviseQuestionId}/>
  </div>
 </details>;
}

function ChangePreview({original,revised}:{original?:RevisionPayload;revised?:RevisionPayload}){
 if(!revised)return null;
 const changed=changedOptionKeys(original,revised);
 const questionChanged=!!original&&clean(original.question)!==clean(revised.question);
 const explanationChanged=!original||clean(original.explanation)!==clean(revised.explanation);
 return <div className="ai-revision-version">
  {questionChanged&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">New question wording</span><p>{revised.question}</p></div>}
  {!!changed.length&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">Changed options</span><div className="ai-option-compare">{changed.map(key=><div className="ai-option-line changed" key={key}><b>{key}</b><span>{option(revised,key)}</span><em>changed</em></div>)}</div></div>}
  {explanationChanged&&revised.explanation&&<div className="ai-insight-detail-card"><span className="ai-detail-kicker">New explanation</span><p>{revised.explanation}</p></div>}
 </div>;
}

function ReviseAgain({questionId}:{questionId:string}){
 const [open,setOpen]=useState(false);const [note,setNote]=useState("");const [busy,setBusy]=useState(false);const [message,setMessage]=useState("");const [error,setError]=useState("");
 async function submit(){
  if(busy||note.trim().length<2)return;
  setBusy(true);setError("");setMessage("");
  try{
   await rpc("english_save_context_note",{p_question_id:questionId,p_note:note.trim(),p_attempt_id:null,p_context_snapshot:{route:"Learning Insights",module:"learninginsights"}});
   setMessage("Sent. AI will handle it in the background — you can keep studying.");setNote("");setOpen(false);
  }catch(e:any){setError(learnerErrorMessage(e,"Could not send this revision note."));}
  finally{setBusy(false);}
 }
 return <div className="question-revision-actions">
  <button className="btn ghost" type="button" onClick={()=>{setOpen(v=>!v);setMessage("");setError("");}}>Revise again</button>
  {open&&<div className="ai-help-panel question-improve-sheet"><strong>What is still wrong or unclear?</strong><span>Write naturally. You can ask for a simpler explanation, meanings of all options, closer options, or tell AI what you still confuse.</span><input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Example: explanation is still too vague; explain part with vs part from with examples"/><button className="btn primary" type="button" disabled={busy||note.trim().length<2} onClick={()=>void submit()}>{busy?"Sending…":"Send to AI"}</button></div>}
  {message&&<div className="context-saved">{message}</div>}{error&&<div className="error-box">{error}</div>}
 </div>;
}

function contentStatusLabel(item:ContextUpdate){
 const status=String(item.contentStatus||"").toLowerCase();
 if(status==="applied")return"In use";
 if(status==="ready")return"Ready";
 if(status==="queued"||status==="processing")return"Working";
 if(status==="failed")return"Needs attention";
 return contextStatus(item.status);
}

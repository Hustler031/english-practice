"use client";

import { useCallback, useEffect, useState } from "react";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import type { RevisionPayload } from "@/lib/question-revisions";

type RevisionStatus = "queued" | "processing" | "ready" | "applied" | "kept" | "failed" | "superseded";
type Proposal = {
  proposalId: string;
  questionId: string;
  version: number;
  status: RevisionStatus;
  feedbackReason?: string;
  feedbackNote?: string;
  proposed?: RevisionPayload;
  generationSource?: "bank_informed_ai" | "ai_last_resort";
  lastError?: string;
};
type QualityReview = {
  reviewId: string;
  status: "queued" | "processing" | "reviewed" | "failed" | "closed";
  verdict?: "valid" | "issue_suspected";
  rationale?: string;
  confidence?: number;
};
type RevisionState = { ok?: boolean; activeVersion?: number; proposal?: Proposal | null; qualityReview?: QualityReview | null };

type Reason = { value: string; label: string };
const REASONS: Reason[] = [
  { value: "options_too_obvious", label: "Options too obvious" },
  { value: "distractors_unrelated", label: "Distractors are unrelated" },
  { value: "explanation_weak", label: "Explanation is weak" },
  { value: "correct_answer_doubtful", label: "Correct answer looks doubtful" },
  { value: "custom", label: "Write your own note" },
];

function looksLikeRelatedPractice(note:string){
 const value=note.trim().toLowerCase();
 return /^(related practice|related question|new related question|another related question)\b/.test(value)
  || (/\b(related|confus\w*|mix\w*)\b/.test(value)&&/\b(question|practice)\b/.test(value));
}

export default function QuestionRevisionActions({ questionId }: { questionId: string }) {
  const [open,setOpen]=useState(false);
  const [preview,setPreview]=useState(false);
  const [reason,setReason]=useState("");
  const [note,setNote]=useState("");
  const [state,setState]=useState<RevisionState|null>(null);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");
  const [message,setMessage]=useState("");

  const refresh=useCallback(async()=>{
    if(!questionId)return;
    try{
      const next=await rpc<RevisionState>("english_get_question_revision_state",{p_question_id:questionId,p_cache_buster:Date.now()});
      setState(next);setError("");
    }catch(e:any){setError(learnerErrorMessage(e,"Could not check the question-improvement state right now."));}
  },[questionId]);

  useEffect(()=>{
    setOpen(false);setPreview(false);setReason("");setNote("");setState(null);setError("");setMessage("");
    void refresh();
  },[questionId,refresh]);

  useEffect(()=>{
    const proposalBusy=state?.proposal?.status==="queued"||state?.proposal?.status==="processing";
    const reviewBusy=state?.qualityReview?.status==="queued"||state?.qualityReview?.status==="processing";
    if(!proposalBusy&&!reviewBusy)return;
    const timer=window.setInterval(()=>void refresh(),7000);
    return()=>window.clearInterval(timer);
  },[state?.proposal?.status,state?.qualityReview?.status,refresh]);

  async function submit(){
    if(!reason||busy)return;
    if(reason==="custom"&&note.trim().length<3){setError("Add a short note describing what should improve.");return;}
    setBusy(true);setError("");setMessage("");
    try{
      if(reason==="correct_answer_doubtful"){
        await rpc("english_request_question_quality_review",{p_question_id:questionId,p_note:note.trim()||null});
        setMessage("Sent for answer review. The current question will not be changed automatically.");
      }else if(reason==="custom"&&looksLikeRelatedPractice(note)){
        const result=await rpc<any>("english_request_related_practice",{p_question_id:questionId,p_note:note.trim()});
        setMessage(result?.status==="ready"?"Related practice added to Targeted Mastery.":"Related practice queued. A close SSC-level question will be prepared in the background.");
      }else{
        await rpc("english_request_question_revision",{p_question_id:questionId,p_feedback_reason:reason,p_feedback_note:note.trim()||null});
        setMessage("Improvement queued. Keep studying — it is checked in the background.");
      }
      setOpen(false);setNote("");setReason("");await refresh();
    }catch(e:any){setError(learnerErrorMessage(e,"Could not queue this question improvement."));}
    finally{setBusy(false);}
  }

  async function useRevision(){
    const proposal=state?.proposal;if(!proposal?.proposalId||proposal.status!=="ready"||busy)return;
    setBusy(true);setError("");
    try{await rpc("english_use_question_revision",{p_proposal_id:proposal.proposalId});setPreview(false);setMessage("Revised version will be used in future practice.");await refresh();}
    catch(e:any){setError(learnerErrorMessage(e,"Could not apply this revision."));}
    finally{setBusy(false);}
  }
  async function keepCurrent(){
    const proposal=state?.proposal;if(!proposal?.proposalId||proposal.status!=="ready"||busy)return;
    setBusy(true);setError("");
    try{await rpc("english_keep_question_revision",{p_proposal_id:proposal.proposalId});setPreview(false);setMessage("Current version kept.");await refresh();}
    catch(e:any){setError(learnerErrorMessage(e,"Could not keep the current version."));}
    finally{setBusy(false);}
  }

  const proposal=state?.proposal;
  const review=state?.qualityReview;
  const repairOnly=reason==="options_too_obvious"||reason==="distractors_unrelated";
  return <div className="question-revision-actions">
    <button className="btn ghost" type="button" onClick={()=>setOpen(v=>!v)}>Too Easy / Improve Question</button>

    {proposal?.status==="queued"||proposal?.status==="processing"?<div className="context-saved">Improvement queued. Keep studying — the proposal is being checked in the background.</div>:null}
    {proposal?.status==="ready"&&proposal.proposed?<div className="context-saved revision-ready-inline"><b>Revision proposal ready</b><button className="btn ghost" type="button" onClick={()=>setPreview(true)}>Preview</button></div>:null}
    {proposal?.status==="applied"?<div className="context-saved">Revised version active for future practice.</div>:null}
    {proposal?.status==="kept"?<div className="context-saved">Current version kept.</div>:null}
    {proposal?.status==="failed"?<div className="error-box">This proposal did not pass the quality checks. You can submit fresh feedback.</div>:null}

    {review?.status==="queued"||review?.status==="processing"?<div className="context-saved">Correct-answer review queued. Nothing will be changed automatically.</div>:null}
    {review?.status==="reviewed"&&review.verdict==="valid"?<div className="context-saved">Answer review: the current key looks valid.</div>:null}
    {review?.status==="reviewed"&&review.verdict==="issue_suspected"?<div className="error-box">Answer review found a possible content issue. The canonical question is still unchanged.</div>:null}

    {message&&<div className="context-saved">{message}</div>}
    {error&&<div className="error-box">{error}</div>}

    {open&&<div className="ai-help-panel question-improve-sheet">
      <strong>What should improve?</strong>
      <div className="action-matrix">{REASONS.map(item=><button key={item.value} className={`btn ${reason===item.value?"primary":"soft"}`} type="button" aria-pressed={reason===item.value} onClick={()=>setReason(item.value)}>{item.label}</button>)}</div>
      {repairOnly&&<span>Only the weak options and matching explanation will be repaired. The question stem and correct answer stay the same.</span>}
      {reason==="explanation_weak"&&<span>The question and all four options stay unchanged; only the explanation is rewritten.</span>}
      {reason==="correct_answer_doubtful"&&<span>This sends the canonical answer for independent review. It does not rewrite the question.</span>}
      {reason==="custom"&&<><input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Briefly describe the problem…"/><small className="improve-related-hint">Want a new related/confusable question? Start with “Related practice: …”</small></>}
      {reason&&reason!=="custom"&&<input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Optional detail…"/>}
      <button className="btn primary" type="button" disabled={busy||!reason||(reason==="custom"&&note.trim().length<3)} onClick={()=>void submit()}>{busy?"Saving…":reason==="correct_answer_doubtful"?"Send for answer review":"Request improvement"}</button>
    </div>}

    {preview&&proposal?.status==="ready"&&proposal.proposed&&<RevisionPreview payload={proposal.proposed} busy={busy} onUse={()=>void useRevision()} onKeep={()=>void keepCurrent()} onClose={()=>setPreview(false)}/>} 
  </div>;
}

function RevisionPreview({payload,busy,onUse,onKeep,onClose}:{payload:RevisionPayload;busy:boolean;onUse:()=>void;onKeep:()=>void;onClose:()=>void}){
  const options:[[string,string],[string,string],[string,string],[string,string]]=[["A",payload.optionA],["B",payload.optionB],["C",payload.optionC],["D",payload.optionD]];
  return <div className="sheet-backdrop" role="dialog" aria-modal="true" aria-label="Revision proposal preview" onMouseDown={e=>{if(e.target===e.currentTarget&&!busy)onClose();}}>
    <section className="add-word-sheet intelligence-sheet">
      <div className="sheet-heading"><div><strong>Revision proposal ready</strong><span>Nothing changes until you choose Use revised version.</span></div><button className="control-icon" type="button" aria-label="Close" disabled={busy} onClick={onClose}>×</button></div>
      <div className="question-area"><div className="question">{payload.question}</div></div>
      <div className="options">{options.map(([key,text])=><div className={`option ${key===payload.correctKey?"correct":""}`} key={key}><span className="option-key">{key}</span><span>{text}</span></div>)}</div>
      <div className="explanation"><h3>Correct answer: {payload.correctKey}</h3><p>{payload.explanation}</p></div>
      <div className="action-matrix"><button className="btn primary" type="button" disabled={busy} onClick={onUse}>Use revised version</button><button className="btn ghost" type="button" disabled={busy} onClick={onKeep}>Keep current</button></div>
    </section>
  </div>;
}

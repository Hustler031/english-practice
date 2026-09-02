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
  generationSource?: "bank_first" | "ai_last_resort";
  lastError?: string;
};
type RevisionState = { ok?: boolean; activeVersion?: number; proposal?: Proposal | null };

type Reason = { value: string; label: string };
const REASONS: Reason[] = [
  { value: "options_too_obvious", label: "Options too obvious" },
  { value: "distractors_unrelated", label: "Distractors are unrelated" },
  { value: "explanation_weak", label: "Explanation is weak" },
  { value: "correct_answer_doubtful", label: "Correct answer looks doubtful" },
  { value: "custom", label: "Write your own note" },
];

export default function QuestionRevisionActions({ questionId }: { questionId: string }) {
  const [open,setOpen]=useState(false);
  const [preview,setPreview]=useState(false);
  const [reason,setReason]=useState("");
  const [note,setNote]=useState("");
  const [state,setState]=useState<RevisionState|null>(null);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");

  const refresh=useCallback(async()=>{
    if(!questionId)return;
    try{
      const next=await rpc<RevisionState>("english_get_question_revision_state",{p_question_id:questionId,p_cache_buster:Date.now()});
      setState(next);setError("");
    }catch(e:any){setError(learnerErrorMessage(e,"Could not check the revision proposal right now."));}
  },[questionId]);

  useEffect(()=>{setOpen(false);setPreview(false);setReason("");setNote("");setState(null);setError("");void refresh();},[questionId,refresh]);
  useEffect(()=>{
    const status=state?.proposal?.status;
    if(status!=="queued"&&status!=="processing")return;
    const timer=window.setTimeout(()=>void refresh(),7000);
    return()=>window.clearTimeout(timer);
  },[state?.proposal?.status,state?.proposal?.version,refresh]);

  async function submit(){
    if(!reason||busy)return;
    if(reason==="custom"&&note.trim().length<3){setError("Add a short note describing what should improve.");return;}
    setBusy(true);setError("");
    try{
      await rpc("english_request_question_revision",{p_question_id:questionId,p_feedback_reason:reason,p_feedback_note:note.trim()||null});
      setOpen(false);setNote("");setReason("");await refresh();
    }catch(e:any){setError(learnerErrorMessage(e,"Could not queue this question improvement."));}
    finally{setBusy(false);}
  }
  async function useRevision(){
    const proposal=state?.proposal;if(!proposal?.proposalId||proposal.status!=="ready"||busy)return;
    setBusy(true);setError("");
    try{await rpc("english_use_question_revision",{p_proposal_id:proposal.proposalId});setPreview(false);await refresh();}
    catch(e:any){setError(learnerErrorMessage(e,"Could not apply this revision."));}
    finally{setBusy(false);}
  }
  async function keepCurrent(){
    const proposal=state?.proposal;if(!proposal?.proposalId||proposal.status!=="ready"||busy)return;
    setBusy(true);setError("");
    try{await rpc("english_keep_question_revision",{p_proposal_id:proposal.proposalId});setPreview(false);await refresh();}
    catch(e:any){setError(learnerErrorMessage(e,"Could not keep the current version."));}
    finally{setBusy(false);}
  }

  const proposal=state?.proposal;
  return <div className="question-revision-actions">
    <button className="btn ghost" type="button" onClick={()=>setOpen(v=>!v)}>Too Easy / Improve Question</button>
    {proposal?.status==="queued"||proposal?.status==="processing"?<div className="context-saved">Improvement queued. Keep studying — the proposal is being checked in the background.</div>:null}
    {proposal?.status==="ready"&&proposal.proposed?<div className="context-saved"><b>Revision proposal ready</b> <button className="btn ghost" type="button" onClick={()=>setPreview(true)}>Preview</button></div>:null}
    {proposal?.status==="applied"?<div className="context-saved">Revised version active for future practice.</div>:null}
    {proposal?.status==="kept"?<div className="context-saved">Current version kept.</div>:null}
    {proposal?.status==="failed"?<div className="error-box">This proposal did not pass the quality checks. You can submit fresh feedback.</div>:null}
    {error&&<div className="error-box">{error}</div>}
    {open&&<div className="ai-help-panel">
      <strong>What should improve?</strong>
      <div className="action-matrix">{REASONS.map(item=><button key={item.value} className={`btn ${reason===item.value?"primary":"soft"}`} type="button" aria-pressed={reason===item.value} onClick={()=>setReason(item.value)}>{item.label}</button>)}</div>
      {reason==="custom"&&<input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Briefly describe the problem…"/>}
      {reason&&reason!=="custom"&&<input value={note} maxLength={600} onChange={e=>setNote(e.target.value)} placeholder="Optional detail…"/>}
      <button className="btn primary" type="button" disabled={busy||!reason||(reason==="custom"&&note.trim().length<3)} onClick={()=>void submit()}>{busy?"Saving…":"Request improvement"}</button>
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

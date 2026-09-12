export type Tone="fix"|"soon"|"good"|"later"|"neutral";

export type RevisionPayload={question?:string;optionA?:string;optionB?:string;optionC?:string;optionD?:string;correctKey?:string;explanation?:string};

export type ContextUpdate={
 kind:"context";noteId:string;questionId:string;displayName:string;topic?:string;learnerNote:string;status:string;
 understood?:string;diagnosisType?:string;action?:string;urgency?:string;relatedTerms?:string[];requiresTransfer?:boolean;
 changedTargeted?:boolean;createdConfusion?:boolean;contentAction?:string;contentProposalId?:string;contentStatus?:string;
 contentFeedbackReason?:string;contentOriginal?:RevisionPayload;contentRevised?:RevisionPayload;contentQualityNote?:string;
 createdAt:string;processedAt?:string;
};

export type RevisionUpdate={
 kind:"revision";proposalId:string;questionId:string;displayName:string;topic?:string;version:number;feedbackReason?:string;
 feedbackNote?:string;status:string;original?:RevisionPayload;revised?:RevisionPayload;qualityNote?:string;active?:boolean;
 errorCode?:string;createdAt:string;readyAt?:string;decidedAt?:string;
};
export type UpdateSummary={contextTotal:number;contextDone:number;contextPending:number;contextFailed:number;revisionTotal:number;revisionReady:number;revisionWorking:number;revisionApplied:number;revisionFailed:number};
export type Updates={ok:boolean;summary:UpdateSummary;contextUpdates:ContextUpdate[];revisionUpdates:RevisionUpdate[]};

export function contextSummary(item:ContextUpdate){
 if(item.contentRevised)return revisionChangeText(item.contentOriginal,item.contentRevised);
 const changes=contextChanges(item);if(changes.length)return changes[0];
 if(item.status==="processing")return"AI is analysing this note.";
 if(item.status==="queued"||item.status==="pending")return"Waiting for AI analysis.";
 if(item.status==="failed")return"Analysis did not complete.";
 return"AI recorded your learning context.";
}
export function contextChanges(item:ContextUpdate){
 const out:string[]=[];const action=String(item.contentAction||"").toLowerCase();const contentStatus=String(item.contentStatus||"").toLowerCase();
 if(action&&action!=="none"){
  const allOptions=action==="explain_all_options";const improveOptions=action==="improve_options";
  if(contentStatus==="applied")out.push(improveOptions?"Improved the answer options and put the quality-checked version in use.":allOptions?"Expanded the explanation to cover every answer option and put it in use.":"Improved the explanation and put the quality-checked version in use.");
  else if(contentStatus==="ready")out.push(improveOptions?"Prepared improved answer options.":allOptions?"Prepared an explanation covering every answer option.":"Prepared a clearer explanation.");
  else if(contentStatus==="queued"||contentStatus==="processing")out.push(improveOptions?"Queued the option improvement.":allOptions?"Queued an explanation for every answer option.":"Queued the explanation improvement.");
  else if(contentStatus==="failed")out.push("The requested question improvement did not pass the quality gate.");
  else if(contentStatus==="skipped_newer_revision")out.push("A newer question revision already exists, so this older request was not applied.");
  else out.push(improveOptions?"Requested improved answer options.":allOptions?"Requested an explanation for every answer option.":"Requested a clearer explanation.");
 }
 if(item.createdConfusion)out.push("Recorded the confusion for focused practice.");
 if(item.changedTargeted)out.push("Added or updated this concept in Targeted Mastery.");
 if(item.requiresTransfer)out.push("Added a fresh understanding check in a new form.");
 if(item.relatedTerms?.length)out.push(`Connected this with: ${item.relatedTerms.join(", ")}.`);
 return out;
}
export function contextFallback(status:string){if(status==="processing")return"AI is still analysing this note.";if(status==="queued"||status==="pending")return"This note is waiting for AI analysis.";if(status==="failed")return"AI could not finish this analysis. The note remains saved.";return"AI finished this note without storing a separate interpretation."}
export function contextStatus(status:string){return status==="done"?"Done":status==="processing"?"Working":status==="queued"?"Queued":status==="failed"?"Needs attention":"Saved"}
export function contextTone(status:string):Tone{return status==="done"?"good":status==="failed"?"fix":status==="processing"||status==="queued"?"soon":"later"}

export function feedbackLabel(reason?:string){const x=String(reason||"").toLowerCase();if(x==="options_too_obvious")return"Improve the answer options";if(x==="distractors_unrelated")return"Make the distractors more relevant";if(x==="explanation_weak")return"Improve the explanation";if(x==="correct_answer_doubtful"||x==="answer_doubtful")return"Check the correct answer";if(x==="custom")return"Custom improvement request";return x?x.replaceAll("_"," "):"Question improvement"}
export function revisionSummary(item:RevisionUpdate){if(item.revised)return revisionChangeText(item.original,item.revised);if(item.status==="failed")return"No safe revision passed the quality gate.";if(item.status==="processing"||item.status==="queued")return"AI is improving this question.";return feedbackLabel(item.feedbackReason)}
export function revisionStatus(status:string){return status==="ready"?"Ready":status==="applied"?"In use":status==="kept"?"Original kept":status==="processing"?"Improving":status==="queued"?"Queued":status==="failed"?"No safe revision":status==="superseded"?"Updated again":"Recorded"}
export function revisionTone(status:string):Tone{return status==="applied"?"good":status==="ready"||status==="processing"||status==="queued"?"soon":status==="failed"?"fix":status==="kept"?"neutral":"later"}
export function revisionFallback(status:string){if(status==="failed")return"The draft failed the quality gate, so your current question stayed unchanged.";if(status==="processing"||status==="queued")return"AI is still working. You can continue studying normally.";if(status==="superseded")return"A newer request replaced this one.";return"No revised version is available."}
export function revisionChangeText(a:RevisionPayload|undefined,b:RevisionPayload|undefined){if(!a||!b)return"A quality-checked revision is ready.";const parts:string[]=[];const changed=changedOptionKeys(a,b);if(clean(a.question)!==clean(b.question))parts.push("question wording");if(changed.length)parts.push(`option${changed.length===1?"":"s"} ${changed.join(", ")}`);if(clean(a.explanation)!==clean(b.explanation))parts.push("explanation");return parts.length?`AI changed ${joinNatural(parts)}.`:"AI kept the question, options and explanation unchanged after review."}
export function changedOptionKeys(a?:RevisionPayload,b?:RevisionPayload){if(!a||!b)return[] as string[];return (["A","B","C","D"] as const).filter(k=>clean(option(a,k))!==clean(option(b,k)))}
export function option(payload:RevisionPayload|undefined,key:"A"|"B"|"C"|"D"){if(!payload)return"";return key==="A"?payload.optionA||"":key==="B"?payload.optionB||"":key==="C"?payload.optionC||"":payload.optionD||""}
export function clean(v?:string){return String(v||"").trim()}
export function clip(value:string,max:number){const s=String(value||"").trim();return s.length<=max?s:`${s.slice(0,max-1).trimEnd()}…`}
export function timeAgo(value:string){const t=new Date(value).getTime();if(!Number.isFinite(t))return"unknown";const mins=Math.max(0,Math.round((Date.now()-t)/60000));return mins<2?"just now":mins<60?`${mins} min ago`:mins<1440?`${Math.round(mins/60)} hr ago`:`${Math.round(mins/1440)} d ago`}
function joinNatural(parts:string[]){if(parts.length<2)return parts[0]||"";if(parts.length===2)return`${parts[0]} and ${parts[1]}`;return`${parts.slice(0,-1).join(", ")}, and ${parts.at(-1)}`}

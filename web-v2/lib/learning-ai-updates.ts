export type Tone="fix"|"soon"|"good"|"later"|"neutral";

export type ContextUpdate={
 kind:"context";noteId:string;questionId:string;displayName:string;topic?:string;learnerNote:string;status:string;
 understood?:string;diagnosisType?:string;action?:string;urgency?:string;relatedTerms?:string[];requiresTransfer?:boolean;
 changedTargeted?:boolean;createdConfusion?:boolean;createdAt:string;processedAt?:string;
};

export type RevisionPayload={question?:string;optionA?:string;optionB?:string;optionC?:string;optionD?:string;correctKey?:string;explanation?:string};
export type RevisionUpdate={
 kind:"revision";proposalId:string;questionId:string;displayName:string;topic?:string;version:number;feedbackReason?:string;
 feedbackNote?:string;status:string;original?:RevisionPayload;revised?:RevisionPayload;qualityNote?:string;active?:boolean;
 errorCode?:string;createdAt:string;readyAt?:string;decidedAt?:string;
};
export type UpdateSummary={contextTotal:number;contextDone:number;contextPending:number;contextFailed:number;revisionTotal:number;revisionReady:number;revisionWorking:number;revisionApplied:number;revisionFailed:number};
export type Updates={ok:boolean;summary:UpdateSummary;contextUpdates:ContextUpdate[];revisionUpdates:RevisionUpdate[]};

export function contextSummary(item:ContextUpdate){if(item.understood)return clip(item.understood,135);if(item.status==="processing")return"AI is analysing this note.";if(item.status==="queued"||item.status==="pending")return"Waiting for AI analysis.";if(item.status==="failed")return"Analysis did not complete.";return"AI analysis completed."}
export function contextChanges(item:ContextUpdate){const out:string[]=[];if(item.createdConfusion)out.push("Created a confusion pair for focused practice.");if(item.changedTargeted)out.push("Updated focused work in Targeted Mastery.");if(item.requiresTransfer)out.push("Added a fresh understanding check in a new form.");if(item.relatedTerms?.length)out.push(`Connected this with: ${item.relatedTerms.join(", ")}.`);return out}
export function contextFallback(status:string){if(status==="processing")return"AI is still analysing this note.";if(status==="queued"||status==="pending")return"This note is waiting for AI analysis.";if(status==="failed")return"AI could not finish this analysis. The note remains saved.";return"AI finished this note without storing a separate interpretation."}
export function contextStatus(status:string){return status==="done"?"Analysed":status==="processing"?"Analysing":status==="queued"?"Queued":status==="failed"?"Needs attention":"Waiting"}
export function contextTone(status:string):Tone{return status==="done"?"good":status==="failed"?"fix":status==="processing"||status==="queued"?"soon":"later"}

export function feedbackLabel(reason?:string){const x=String(reason||"").toLowerCase();if(x==="options_too_obvious")return"Options were too obvious";if(x==="distractors_unrelated")return"Distractors were unrelated";if(x==="explanation_weak")return"Explanation was weak";if(x==="answer_doubtful")return"Correct answer looked doubtful";if(x==="custom")return"Custom improvement request";return x?x.replaceAll("_"," "):"Question improvement"}
export function revisionSummary(item:RevisionUpdate){if(item.revised){const changed=changedOptionKeys(item.original,item.revised);if(changed.length)return`Changed option${changed.length===1?"":"s"} ${changed.join(", ")}.`;if(clean(item.original?.question)!==clean(item.revised.question))return"Question wording was revised.";return"A quality-checked revision is ready."}if(item.status==="failed")return"No safe revision passed the quality gate.";if(item.status==="processing"||item.status==="queued")return"AI is improving this question.";return feedbackLabel(item.feedbackReason)}
export function revisionStatus(status:string){return status==="ready"?"Ready":status==="applied"?"In use":status==="kept"?"Original kept":status==="processing"?"Improving":status==="queued"?"Queued":status==="failed"?"No safe revision":status==="superseded"?"Updated again":"Recorded"}
export function revisionTone(status:string):Tone{return status==="applied"?"good":status==="ready"||status==="processing"||status==="queued"?"soon":status==="failed"?"fix":status==="kept"?"neutral":"later"}
export function revisionFallback(status:string){if(status==="failed")return"The draft failed the quality gate, so your current question stayed unchanged.";if(status==="processing"||status==="queued")return"AI is still working. Nothing has been applied yet.";if(status==="superseded")return"A newer request replaced this one.";return"No revised version is available."}
export function revisionChangeText(a:RevisionPayload|undefined,b:RevisionPayload|undefined){if(!a||!b)return"The revised version is ready.";const parts:string[]=[];const changed=changedOptionKeys(a,b);if(clean(a.question)!==clean(b.question))parts.push("question wording");if(changed.length)parts.push(`option${changed.length===1?"":"s"} ${changed.join(", ")}`);if(clean(a.explanation)!==clean(b.explanation))parts.push("explanation");return parts.length?`AI changed ${joinNatural(parts)}.`:"AI kept the question, options and explanation unchanged after review."}
export function changedOptionKeys(a?:RevisionPayload,b?:RevisionPayload){if(!a||!b)return[] as string[];return (["A","B","C","D"] as const).filter(k=>clean(option(a,k))!==clean(option(b,k)))}
export function option(payload:RevisionPayload|undefined,key:"A"|"B"|"C"|"D"){if(!payload)return"";return key==="A"?payload.optionA||"":key==="B"?payload.optionB||"":key==="C"?payload.optionC||"":payload.optionD||""}
export function clean(v?:string){return String(v||"").trim()}
export function clip(value:string,max:number){const s=String(value||"").trim();return s.length<=max?s:`${s.slice(0,max-1).trimEnd()}…`}
export function timeAgo(value:string){const t=new Date(value).getTime();if(!Number.isFinite(t))return"unknown";const mins=Math.max(0,Math.round((Date.now()-t)/60000));return mins<2?"just now":mins<60?`${mins} min ago`:mins<1440?`${Math.round(mins/60)} hr ago`:`${Math.round(mins/1440)} d ago`}
function joinNatural(parts:string[]){if(parts.length<2)return parts[0]||"";if(parts.length===2)return`${parts[0]} and ${parts[1]}`;return`${parts.slice(0,-1).join(", ")}, and ${parts.at(-1)}`}

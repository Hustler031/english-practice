"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { learnerErrorMessage, localProductionSafetyMode, rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Filter="all"|"correct"|"wrong"|"unanswered";
type Recent={sessionId:string;setNo?:number|null;mode:string;score:number;maxMarks?:number;questionCount?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;completedAt:string};
type RecentPayload={ok:boolean;items?:Recent[];error?:string};
type SprintOption={key:string;text:string};
type Diagnosis={position:number;diagnosis:string;action:string;confusedWith?:string;rationale?:string};
type SprintItem={position:number;category:string;questionType:string;question:string;options:SprintOption[];selectedKey?:string|null;timeSeconds?:number;correctKey?:string;explanation?:string;diagnosis?:string|null;action?:string|null;confusedWith?:string|null};
type SprintResult={score:number;maxMarks?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;analysis?:{items?:Diagnosis[]}};
type SprintSession={ok:boolean;sessionId:string;setNo?:number|null;mode:string;status:string;startedAt:string;completedAt?:string|null;questionCount:number;items:SprintItem[];result?:SprintResult|null;error?:string};

export default function SprintReportHistory(){
  const ready=useAuthGuard();
  const[reports,setReports]=useState<Recent[]>([]);
  const[loading,setLoading]=useState(true);
  const[opening,setOpening]=useState("");
  const[session,setSession]=useState<SprintSession|null>(null);
  const[error,setError]=useState("");
  const[expanded,setExpanded]=useState(false);

  const load=useCallback(async()=>{
    if(!ready)return;
    setLoading(true);
    try{
      const recent=await rpc<RecentPayload>("english_get_recent_sprint_reports",{p_days:3650});
      if(!recent?.ok)throw new Error(recent?.error||"Sprint archive unavailable");
      setReports(Array.isArray(recent.items)?recent.items:[]);setError("");
    }catch(e:any){setError(learnerErrorMessage(e,"Could not load Sprint archive."));}
    finally{setLoading(false)}
  },[ready]);

  useEffect(()=>{if(ready)void load()},[ready,load]);
  useEffect(()=>{
    if(!ready)return;
    return subscribeRpcFresh<RecentPayload>("english_get_recent_sprint_reports",{p_days:3650},fresh=>{
      if(!fresh?.ok)return;setReports(Array.isArray(fresh.items)?fresh.items:[]);setLoading(false);setError("");
    });
  },[ready]);
  useEffect(()=>{
    if(!ready||typeof document==="undefined")return;
    const observer=new MutationObserver(()=>{if(!document.body.classList.contains("english-sprint-mode"))void load()});
    observer.observe(document.body,{attributes:true,attributeFilter:["class"]});
    return()=>observer.disconnect();
  },[ready,load]);
  useEffect(()=>{
    if(!session||typeof document==="undefined")return;
    document.body.classList.add("english-sprint-report-mode");
    return()=>document.body.classList.remove("english-sprint-report-mode");
  },[session]);

  async function openReport(report:Recent){
    setOpening(report.sessionId);setError("");
    try{
      const out=await rpc<SprintSession>("english_get_sprint_session",{p_session_id:report.sessionId});
      if(!out?.ok||out.status!=="completed")throw new Error(out?.error||"Completed Sprint set not found");
      setSession({...out,setNo:out.setNo??report.setNo,completedAt:out.completedAt||report.completedAt});
    }catch(e:any){setError(learnerErrorMessage(e,"Could not open this Sprint set."));}
    finally{setOpening("")}
  }

  if(!ready)return null;
  return <>
    <section className={`sprint-report-history ${expanded?"is-expanded":"is-collapsed"}`} aria-label="Sprint set archive">
      <header>
        <div><strong>Previous Sprint Sets</strong><span>Permanent archive · set number + date + full question review</span></div>
        <button className="sprint-section-collapse" type="button" aria-expanded={expanded} aria-label={`${expanded?"Collapse":"Expand"} previous Sprint sets`} onClick={()=>setExpanded(x=>!x)}><b>{reports.length} sets</b><i>{expanded?"⌃":"⌄"}</i></button>
      </header>
      {expanded&&<>
        {error&&<div className="compact-error sprint-report-error" role="alert">{error}</div>}
        {loading&&!reports.length?<div className="sprint-report-skeleton" aria-label="Loading Sprint archive"><i/><i/><i/></div>:
        reports.length?<div className="sprint-history-list">{reports.map((report,index)=>
          <button type="button" key={report.sessionId} className="sprint-history-row" disabled={opening===report.sessionId} onClick={()=>void openReport(report)}>
            <span className="sprint-history-copy">
              <strong>Set {report.setNo??reports.length-index}</strong>
              <small>{fullDate(report.completedAt)} · {reportClock(report.completedAt)} · {formatTime(report.durationSeconds)}</small>
              <em><i className="correct"/> {report.correct} correct <i className="wrong"/> {report.wrong} incorrect <i className="unanswered"/> {report.unanswered} skipped</em>
            </span>
            <span className="sprint-history-score"><b>{formatScore(report.score)}</b><small>/{report.maxMarks??50}</small><i>View Questions ›</i></span>
          </button>
        )}</div>:<p className="sprint-history-empty">No completed Sprint set yet.</p>}
      </>}
    </section>
    {session&&<SetQuestionReview session={session} onClose={()=>{setSession(null);void load()}}/>}
  </>;
}

function SetQuestionReview({session,onClose}:{session:SprintSession;onClose:()=>void}){
  const[filter,setFilter]=useState<Filter>("all");
  const[index,setIndex]=useState(0);
  const[banked,setBanked]=useState<Set<number>>(()=>new Set());
  const[bankBusy,setBankBusy]=useState<Set<number>>(()=>new Set());
  const[bankError,setBankError]=useState("");
  const diagnosis=useMemo(()=>Array.isArray(session.result?.analysis?.items)?session.result!.analysis!.items!:[],[session.result?.analysis]);
  const diagnosisMap=useMemo(()=>new Map(diagnosis.map(x=>[x.position,x])),[diagnosis]);
  const filtered=useMemo(()=>filter==="all"?session.items:session.items.filter(x=>itemStatus(x)===filter),[filter,session.items]);
  const safeIndex=Math.min(Math.max(0,index),Math.max(0,filtered.length-1));
  const item=filtered[safeIndex]||null;
  const result=session.result;
  const currentSaved=item?banked.has(item.position):false;
  const currentBusy=item?bankBusy.has(item.position):false;

  useEffect(()=>{
    let live=true;
    setBanked(new Set());setBankError("");
    void rpc<{ok:boolean;items?:Array<{position:number}>}>("english_get_sprint_bank_marks",{p_session_id:session.sessionId})
      .then(out=>{if(live)setBanked(new Set((out.items||[]).map(x=>Number(x.position)).filter(Number.isFinite)));})
      .catch(()=>{});
    return()=>{live=false};
  },[session.sessionId]);

  function choose(next:Exclude<Filter,"all">){
    setFilter(current=>current===next?"all":next);setIndex(0);
  }

  async function saveToBank(position:number){
    if(banked.has(position)||bankBusy.has(position))return;
    if(localProductionSafetyMode()){setBankError("Save to Bank is disabled in Local Safe.");return;}
    setBankError("");
    setBankBusy(prev=>{const next=new Set(prev);next.add(position);return next;});
    try{
      const out=await rpc<{ok:boolean;saved:boolean;questionId?:string|null}>("english_set_sprint_bank_mark",{p_session_id:session.sessionId,p_position:position,p_saved:true});
      if(!out?.ok||out.saved!==true)throw new Error("Could not save this question to the bank.");
      setBanked(prev=>{const next=new Set(prev);next.add(position);return next;});
    }catch(e:any){setBankError(learnerErrorMessage(e,"Could not save this question to the bank."));}
    finally{setBankBusy(prev=>{const next=new Set(prev);next.delete(position);return next;});}
  }

  return <div className="sprint-report-overlay"><main className="sprint-report-question-page">
    <header className="module-compact-head">
      <button className="compact-back" type="button" onClick={onClose}>← Sets</button>
      <div className="compact-head-copy"><strong>Set {session.setNo??"—"}</strong><span>{fullDate(session.completedAt||session.startedAt)} · {formatScore(result?.score??0)}/{result?.maxMarks??50}</span></div>
      <span/>
    </header>

    <section className="sprint-report-filter-bar" aria-label="Filter reviewed questions">
      <FilterChip tone="correct" label="Correct" count={result?.correct??session.items.filter(x=>itemStatus(x)==="correct").length} active={filter==="correct"} onClick={()=>choose("correct")}/>
      <FilterChip tone="wrong" label="Incorrect" count={result?.wrong??session.items.filter(x=>itemStatus(x)==="wrong").length} active={filter==="wrong"} onClick={()=>choose("wrong")}/>
      <FilterChip tone="unanswered" label="Skipped" count={result?.unanswered??session.items.filter(x=>itemStatus(x)==="unanswered").length} active={filter==="unanswered"} onClick={()=>choose("unanswered")}/>
    </section>

    {bankError&&<div className="compact-error sprint-report-error" role="alert">{bankError}</div>}

    {item?<>
      <section className="sprint-review-question-card">
        <div className="question-eyebrow">
          <span>{pretty(item.category)}</span>
          <span style={{display:"inline-flex",alignItems:"center",gap:8}}>
            Q {item.position} · {statusLabel(itemStatus(item))}
            <button type="button" aria-label={currentSaved?"Saved to bank":"Save question to bank"} aria-pressed={currentSaved} disabled={currentSaved||currentBusy} onClick={()=>void saveToBank(item.position)} style={{border:"1px solid currentColor",borderRadius:999,background:"transparent",color:"inherit",fontSize:10,fontWeight:800,lineHeight:1.1,padding:"4px 7px",opacity:currentBusy?0.55:currentSaved?0.72:0.88,whiteSpace:"nowrap"}}>{currentSaved?"✓ Bank":currentBusy?"Saving…":"＋ Bank"}</button>
          </span>
        </div>
        <h1>{item.question}</h1>
        <div className="sprint-review-options">{item.options.map(option=>{
          const isCorrect=option.key===item.correctKey;const isSelected=option.key===item.selectedKey;
          const state=isCorrect&&isSelected?"selected-correct":isCorrect?"correct":isSelected?"selected-wrong":"";
          return <div key={option.key} className={state}><span>{option.key}</span><b>{option.text}</b>{isCorrect&&isSelected?<em>Your answer · Correct</em>:isCorrect?<em>Correct answer</em>:isSelected?<em>Your answer</em>:null}</div>
        })}</div>
      </section>
      <section className="sprint-review-answer-row"><div className={itemStatus(item)}><span>Your answer</span><b>{optionText(item.options,item.selectedKey)||"Skipped"}</b></div><div className="correct"><span>Correct answer</span><b>{optionText(item.options,item.correctKey)||item.correctKey||"—"}</b></div></section>
      {item.explanation&&<section className="sprint-review-explanation"><strong>Explanation</strong><p>{item.explanation}</p></section>}
      {diagnosisFor(item,diagnosisMap)&&<DiagnosisBox diagnosis={diagnosisFor(item,diagnosisMap)!}/>} 
      <nav className="sprint-review-nav">
        <button type="button" disabled={safeIndex===0} onClick={()=>setIndex(x=>Math.max(0,x-1))}>← Previous</button>
        <button type="button" className="back-report" onClick={()=>{setFilter("all");setIndex(0)}}>{filter==="all"?`All ${session.items.length}`:"Show All"}</button>
        <button type="button" disabled={safeIndex>=filtered.length-1} onClick={()=>setIndex(x=>Math.min(filtered.length-1,x+1))}>Next →</button>
      </nav>
    </>:<p className="sprint-report-filter-empty">No questions in this result group. Tap the active filter again to show all.</p>}
  </main></div>;
}

function DiagnosisBox({diagnosis}:{diagnosis:Diagnosis}){return <section className={`sprint-review-diagnosis ${diagnosisTone(diagnosis.diagnosis)}`}><div><strong>{diagnosis.diagnosis}</strong><span>{diagnosis.action}</span></div>{diagnosis.confusedWith&&<small>Confused with: {diagnosis.confusedWith}</small>}{diagnosis.rationale&&<p>{diagnosis.rationale}</p>}</section>}
function FilterChip({tone,label,count,active,onClick}:{tone:string;label:string;count:number;active:boolean;onClick:()=>void}){return <button type="button" className={`sprint-report-filter-chip ${tone} ${active?"active":""}`} aria-pressed={active} onClick={onClick}><span>{label}</span><b>{count}</b></button>}
function diagnosisFor(item:SprintItem,map:Map<number,Diagnosis>){const saved=map.get(item.position);if(saved)return saved;if(!item.diagnosis)return undefined;return {position:item.position,diagnosis:item.diagnosis,action:item.action||"Review",confusedWith:item.confusedWith||undefined}}
function itemStatus(item:SprintItem){if(!item.selectedKey)return "unanswered";return item.selectedKey===item.correctKey?"correct":"wrong"}
function statusLabel(status:string){return status==="correct"?"Correct":status==="wrong"?"Incorrect":"Skipped"}
function diagnosisTone(name:string){return /careless|misread|time pressure/i.test(name)?"execution":/confusion|distractor/i.test(name)?"confusion":/knowledge|rule/i.test(name)?"learning":"neutral"}
function formatScore(value:number){const n=Number(value||0);return n.toFixed(Number.isInteger(n)?0:1)}
function formatTime(seconds:number){const safe=Math.max(0,Math.round(Number(seconds)||0));return `${String(Math.floor(safe/60)).padStart(2,"0")}:${String(safe%60).padStart(2,"0")}`}
function optionText(options:SprintOption[]|undefined,key:string|null|undefined){if(!key)return "";const found=options?.find(x=>x.key===key);return found?`${found.key}. ${found.text}`:key}
function pretty(value:string){return String(value||"").replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase())}
function fullDate(value:string){return new Intl.DateTimeFormat("en-IN",{timeZone:"Asia/Kolkata",day:"2-digit",month:"short",year:"numeric"}).format(new Date(value))}
function reportClock(value:string){return new Intl.DateTimeFormat("en-IN",{timeZone:"Asia/Kolkata",hour:"numeric",minute:"2-digit",hour12:true}).format(new Date(value))}

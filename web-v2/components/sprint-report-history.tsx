"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Mode="standard"|"weakness"|"trap"|"mistakes";
type Recent={sessionId:string;mode:string;score:number;maxMarks?:number;questionCount?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;completedAt:string};
type RecentPayload={ok:boolean;days?:number;items?:Recent[];error?:string};
type ExamFallback={ok?:boolean;recentSprints?:Recent[]};
type SprintOption={key:string;text:string};
type Diagnosis={position:number;diagnosis:string;action:string;confusedWith?:string;rationale?:string};
type SprintItem={position:number;category:string;questionType:string;question:string;options:SprintOption[];selectedKey?:string|null;timeSeconds?:number;correctKey?:string;explanation?:string;diagnosis?:string|null;action?:string|null;confusedWith?:string|null};
type SprintResult={score:number;maxMarks?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;analysis?:{items?:Diagnosis[]}};
type SprintSession={ok:boolean;sessionId:string;mode:string;status:string;startedAt:string;completedAt?:string|null;questionCount:number;items:SprintItem[];result?:SprintResult|null;error?:string};

const modeLabel:Record<Mode,string>={standard:"SSC Standard",weakness:"Weakness Sprint",trap:"Trap Sprint",mistakes:"Previous Mistakes"};

export default function SprintReportHistory(){
  const ready=useAuthGuard();
  const[reports,setReports]=useState<Recent[]>([]);
  const[loading,setLoading]=useState(true);
  const[opening,setOpening]=useState("");
  const[session,setSession]=useState<SprintSession|null>(null);
  const[error,setError]=useState("");

  const load=useCallback(async()=>{
    if(!ready)return;
    setLoading(true);
    try{
      let rows:Recent[]=[];
      try{
        const recent=await rpc<RecentPayload>("english_get_recent_sprint_reports",{p_days:5});
        if(recent?.ok)rows=Array.isArray(recent.items)?recent.items:[];
        else throw new Error(recent?.error||"Recent Sprint reports unavailable");
      }catch{
        const fallback=await rpc<ExamFallback>("english_get_exam_preparation");
        rows=Array.isArray(fallback?.recentSprints)?fallback.recentSprints:[];
      }
      setReports(rows);
      setError("");
    }catch(e:any){setError(learnerErrorMessage(e,"Could not load recent Sprint reports."));}
    finally{setLoading(false)}
  },[ready]);

  useEffect(()=>{if(ready)void load()},[ready,load]);

  useEffect(()=>{
    if(!ready||typeof document==="undefined")return;
    const observer=new MutationObserver(()=>{
      if(!document.body.classList.contains("english-sprint-mode"))void load();
    });
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
      if(!out?.ok||out.status!=="completed")throw new Error(out?.error||"Completed Sprint report not found");
      setSession({...out,completedAt:out.completedAt||report.completedAt});
    }catch(e:any){setError(learnerErrorMessage(e,"Could not open this Sprint report."));}
    finally{setOpening("")}
  }

  if(!ready)return null;
  return <>
    <section className="sprint-report-history" aria-label="Recent Sprint reports">
      <header><div><strong>Sprint Reports</strong><span>Completed attempts stay reviewable for 5 days</span></div><b>5 days</b></header>
      {error&&<div className="compact-error sprint-report-error" role="alert">{error}</div>}
      {loading&&!reports.length?<div className="sprint-report-skeleton" aria-label="Loading recent reports"><i/><i/><i/></div>:
      reports.length?<div className="sprint-history-list">{reports.map((report,index)=>{
        const day=reportDayLabel(report.completedAt);
        const title=day==="Today"&&index===0?"Today's Sprint":day;
        return <button type="button" key={report.sessionId} className="sprint-history-row" disabled={opening===report.sessionId} onClick={()=>void openReport(report)}>
          <span className="sprint-history-copy"><strong>{title}</strong><small>{labelMode(report.mode)} · {reportClock(report.completedAt)} · {formatTime(report.durationSeconds)}</small><em><i className="correct"/> {report.correct} correct <i className="wrong"/> {report.wrong} wrong {report.unanswered>0&&<><i className="unanswered"/> {report.unanswered} blank</>}</em></span>
          <span className="sprint-history-score"><b>{formatScore(report.score)}</b><small>/{report.maxMarks??modeMaxMarks(report.mode,report.questionCount)}</small><i>›</i></span>
        </button>
      })}</div>:<p className="sprint-history-empty">No completed Sprint in the last 5 days yet.</p>}
    </section>
    {session&&<SprintReportOverlay session={session} onClose={()=>{setSession(null);void load()}}/>}
  </>;
}

function SprintReportOverlay({session,onClose}:{session:SprintSession;onClose:()=>void}){
  const[selectedPosition,setSelectedPosition]=useState<number|null>(null);
  const diagnosis=useMemo(()=>Array.isArray(session.result?.analysis?.items)?session.result!.analysis!.items!:[],[session.result?.analysis]);
  const diagnosisMap=useMemo(()=>new Map(diagnosis.map(x=>[x.position,x])),[diagnosis]);
  const diagnosisCounts=useMemo(()=>{
    const counts=new Map<string,number>();
    for(const item of diagnosis)counts.set(item.diagnosis,(counts.get(item.diagnosis)||0)+1);
    return [...counts.entries()].sort((a,b)=>b[1]-a[1]);
  },[diagnosis]);
  const selectedIndex=selectedPosition==null?-1:session.items.findIndex(x=>x.position===selectedPosition);
  const selectedItem=selectedIndex>=0?session.items[selectedIndex]:null;
  const result=session.result;
  const maxMarks=result?.maxMarks??session.questionCount*2;

  if(selectedItem)return <div className="sprint-report-overlay"><ReviewQuestion item={selectedItem} diagnosis={diagnosisFor(selectedItem,diagnosisMap)} index={selectedIndex} count={session.items.length} onBack={()=>setSelectedPosition(null)} onPrev={()=>selectedIndex>0&&setSelectedPosition(session.items[selectedIndex-1].position)} onNext={()=>selectedIndex<session.items.length-1&&setSelectedPosition(session.items[selectedIndex+1].position)}/></div>;

  return <div className="sprint-report-overlay"><main className="sprint-report-page">
    <header className="module-compact-head sprint-report-head"><button className="compact-back" type="button" onClick={onClose}>← Exam Prep</button><div className="compact-head-copy"><strong>Sprint Report</strong><span>{reportDayLabel(session.completedAt||session.startedAt)} · {labelMode(session.mode)}</span></div><span/></header>

    <section className={`sprint-report-hero ${session.mode==="standard"&&(result?.score??0)>=45?"goal":""}`}><span>Score</span><strong>{formatScore(result?.score??0)}<small>/{maxMarks}</small></strong><p>{session.mode==="standard"&&(result?.score??0)>=45?"45+ target reached":"Use the question review to recover lost marks."}</p></section>

    <section className="sprint-report-metrics" aria-label="Sprint result summary">
      <ReportMetric tone="correct" label="Correct" value={result?.correct??0}/>
      <ReportMetric tone="wrong" label="Wrong" value={result?.wrong??0}/>
      <ReportMetric tone="unanswered" label="Unanswered" value={result?.unanswered??0}/>
      <ReportMetric tone="accuracy" label="Accuracy" value={`${result?.accuracy??0}%`}/>
      <ReportMetric tone="time" label="Time" value={formatTime(result?.durationSeconds??0)}/>
    </section>

    <section className="sprint-diagnostic-summary"><header><strong>Performance signals</strong><span>{diagnosisCounts.length?"From saved mistake analysis":"No diagnostic flags saved"}</span></header>{diagnosisCounts.length?<div>{diagnosisCounts.map(([name,count])=><span key={name} className={`diagnostic-chip ${diagnosisTone(name)}`}><b>{count}</b>{name}</span>)}</div>:<p>Correct / wrong / unanswered evidence is still fully available below.</p>}</section>

    <section className="sprint-report-question-list"><header><strong>Questions</strong><span>Tap any question to review it like the quiz</span></header>{session.items.map(item=>{
      const status=itemStatus(item);const d=diagnosisFor(item,diagnosisMap);
      return <button type="button" key={item.position} className={`sprint-report-question-row ${status}`} onClick={()=>setSelectedPosition(item.position)}>
        <span className="report-q-number">Q{item.position}</span><span className="report-q-copy"><strong>{item.question}</strong><small>{pretty(item.category)}{Number(item.timeSeconds)>0?` · ${formatQuestionTime(Number(item.timeSeconds))}`:""}{d?` · ${d.diagnosis}`:""}</small></span><span className="report-q-state">{statusLabel(status)}<i>›</i></span>
      </button>
    })}</section>
  </main></div>;
}

function ReviewQuestion({item,diagnosis,index,count,onBack,onPrev,onNext}:{item:SprintItem;diagnosis?:Diagnosis;index:number;count:number;onBack:()=>void;onPrev:()=>void;onNext:()=>void}){
  const status=itemStatus(item);
  return <main className="sprint-report-question-page">
    <header className="module-compact-head"><button className="compact-back" type="button" onClick={onBack}>← Report</button><div className="compact-head-copy"><strong>Question {item.position}</strong><span>{pretty(item.category)} · {statusLabel(status)}{Number(item.timeSeconds)>0?` · ${formatQuestionTime(Number(item.timeSeconds))}`:""}</span></div><span/></header>
    <section className="sprint-review-question-card">
      <div className="question-eyebrow"><span>{pretty(item.category)}</span><span>Q {item.position}/{count}</span></div>
      <h1>{item.question}</h1>
      <div className="sprint-review-options">{item.options.map(option=>{
        const isCorrect=option.key===item.correctKey;const isSelected=option.key===item.selectedKey;
        const state=isCorrect&&isSelected?"selected-correct":isCorrect?"correct":isSelected?"selected-wrong":"";
        return <div key={option.key} className={state}><span>{option.key}</span><b>{option.text}</b>{isCorrect&&isSelected?<em>Your answer · Correct</em>:isCorrect?<em>Correct answer</em>:isSelected?<em>Your answer</em>:null}</div>
      })}</div>
    </section>
    <section className="sprint-review-answer-row"><div className={status}><span>Your answer</span><b>{optionText(item.options,item.selectedKey)||"Unanswered"}</b></div><div className="correct"><span>Correct answer</span><b>{optionText(item.options,item.correctKey)||item.correctKey||"—"}</b></div></section>
    {item.explanation&&<section className="sprint-review-explanation"><strong>Explanation</strong><p>{item.explanation}</p></section>}
    {diagnosis&&<section className={`sprint-review-diagnosis ${diagnosisTone(diagnosis.diagnosis)}`}><div><strong>{diagnosis.diagnosis}</strong><span>{diagnosis.action}</span></div>{diagnosis.confusedWith&&<small>Confused with: {diagnosis.confusedWith}</small>}{diagnosis.rationale&&<p>{diagnosis.rationale}</p>}</section>}
    <nav className="sprint-review-nav"><button type="button" disabled={index===0} onClick={onPrev}>← Previous</button><button type="button" className="back-report" onClick={onBack}>Back to Report</button><button type="button" disabled={index===count-1} onClick={onNext}>Next →</button></nav>
  </main>;
}

function ReportMetric({tone,label,value}:{tone:string;label:string;value:string|number}){return <div className={`sprint-report-metric ${tone}`}><span>{label}</span><strong>{value}</strong></div>}
function diagnosisFor(item:SprintItem,map:Map<number,Diagnosis>){const saved=map.get(item.position);if(saved)return saved;if(!item.diagnosis)return undefined;return {position:item.position,diagnosis:item.diagnosis,action:item.action||"Review",confusedWith:item.confusedWith||undefined}}
function itemStatus(item:SprintItem){if(!item.selectedKey)return "unanswered";return item.selectedKey===item.correctKey?"correct":"wrong"}
function statusLabel(status:string){return status==="correct"?"Correct":status==="wrong"?"Wrong":"Unanswered"}
function diagnosisTone(name:string){return /careless|misread|time pressure/i.test(name)?"execution":/confusion|distractor/i.test(name)?"confusion":/knowledge|rule/i.test(name)?"learning":"neutral"}
function labelMode(mode:string){return modeLabel[mode as Mode]||pretty(mode)}
function modeMaxMarks(mode:string,count?:number){const fallback=mode==="standard"?25:mode==="mistakes"?10:15;return (count??fallback)*2}
function formatScore(value:number){const n=Number(value||0);return n.toFixed(Number.isInteger(n)?0:1)}
function formatTime(seconds:number){const safe=Math.max(0,Math.round(Number(seconds)||0));return `${String(Math.floor(safe/60)).padStart(2,"0")}:${String(safe%60).padStart(2,"0")}`}
function formatQuestionTime(seconds:number){const safe=Math.max(0,Math.round(seconds||0));return safe>=60?`${Math.floor(safe/60)}m ${safe%60}s`:`${safe}s`}
function optionText(options:SprintOption[]|undefined,key:string|null|undefined){if(!key)return "";const found=options?.find(x=>x.key===key);return found?`${found.key}. ${found.text}`:key}
function pretty(value:string){return String(value||"").replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase())}
function indiaDayKey(value:Date){return new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).format(value)}
function reportDayLabel(value:string){const date=new Date(value);const now=new Date();if(indiaDayKey(date)===indiaDayKey(now))return "Today";const yesterday=new Date(now.getTime()-86400000);if(indiaDayKey(date)===indiaDayKey(yesterday))return "Yesterday";return new Intl.DateTimeFormat("en-IN",{timeZone:"Asia/Kolkata",day:"numeric",month:"short"}).format(date)}
function reportClock(value:string){return new Intl.DateTimeFormat("en-IN",{timeZone:"Asia/Kolkata",hour:"numeric",minute:"2-digit",hour12:true}).format(new Date(value))}

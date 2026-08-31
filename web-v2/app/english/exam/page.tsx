"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, localProductionSafetyMode, rpc, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Readiness={lastSprint:number|null;fiveSprintAverage:number|null;best:number|null;lowest:number|null;accuracy:number|null;timeSeconds:number|null;goalStreak:number;knownButMissed:number;targetedMissed:number;preventableMarksLost:number};
type Weakness={category:string;wrong:number};
type Trap={trap:string;count:number};
type Recent={sessionId:string;mode:string;score:number;maxMarks?:number;questionCount?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;completedAt:string};
type ExamData={ok:boolean;targetDate:string;daysLeft:number;goalMarks:number;standard:{questions:number;minutes:number;marks:number;wrongPenalty:number;readingComprehension:boolean};readiness:Readiness;weaknesses:Weakness[];traps:Trap[];recentSprints:Recent[];targetedFromSprints:{needLearning:number;recovered:number};todayPlan:{targetedRevision:number;fastTrackReady:number;sprintQuestions:number;weaknessDrill:string}};
type SprintOption={key:string;text:string};
type SprintItem={position:number;category:string;questionType:string;question:string;options:SprintOption[];selectedKey?:string|null;correctKey?:string;explanation?:string;sourceType?:string;canonicalQuestionId?:string|null};
type SprintResult={score:number;maxMarks?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;analysis?:{items?:Diagnosis[]}};
type SprintSession={ok:boolean;sessionId:string;mode:string;status:string;startedAt:string;questionCount:number;durationLimitSeconds:number;items:SprintItem[];result?:SprintResult|null};
type Diagnosis={position:number;diagnosis:string;action:string;confusedWith?:string;rationale?:string};
type Answer={position:number;selectedKey:string;timeSeconds:number};
type Mode="standard"|"weakness"|"trap"|"mistakes";

const modeMeta:Record<Mode,{label:string;sub:string;count:number}>={
 standard:{label:"SSC Standard",sub:"Balanced exam simulation",count:25},
 weakness:{label:"Weakness Sprint",sub:"Fresh transfer from current genuine weaknesses",count:15},
 trap:{label:"Trap Sprint",sub:"Adversarial distractors around recurring traps",count:15},
 mistakes:{label:"Previous Mistakes",sub:"Fresh variants of earlier Sprint misses",count:10},
};

export default function ExamPreparationPage(){
 const ready=useAuthGuard();
 const[data,setData]=useState<ExamData|null>(null);
 const[session,setSession]=useState<SprintSession|null>(null);
 const[creating,setCreating]=useState<Mode|null>(null);
 const[error,setError]=useState("");
 const[more,setMore]=useState(false);
 const refresh=useCallback(async()=>{const {data:out,error:e}=await supabaseBrowser().rpc("english_get_exam_preparation");if(e)throw e;setData(out as ExamData);},[]);
 useEffect(()=>{if(ready)refresh().catch((e:any)=>setError(e.message||String(e)));},[ready,refresh]);
 async function start(mode:Mode){
  if(localProductionSafetyMode()){setError("Sprint creation is disabled in Local Safe because this localhost is connected to production data.");return;}
  setCreating(mode);setError("");
  try{
   const {data:out,error:fnError}=await supabaseBrowser().functions.invoke<SprintSession>("english-ssc-sprint",{body:{action:"create",mode}});
   if(fnError)throw fnError;
   if(!out?.ok)throw new Error((out as any)?.error||"Could not create Sprint");
   setSession(out);
  }catch(e:any){setError(learnerErrorMessage(e,"Could not create the SSC Sprint right now."));}
  finally{setCreating(null)}
 }
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(session)return <SprintRunner initial={session} onExit={()=>{setSession(null);void refresh()}}/>;
 const r=data?.readiness;
 return <section className="exam-page">
  <div className="exam-head"><Link className="btn ghost" href="/english">← Home</Link><div><span className="eyebrow">Final performance layer</span><h1>Exam Preparation</h1><p>{data?`${data.daysLeft} days left · ${data.goalMarks}+ repeatability goal`:"SSC CGL sprint intelligence"}</p></div></div>
  {error&&<div className="error-box">{error}</div>}
  <section className="exam-primary"><div><span className="eyebrow">SSC Exam Sprint</span><h2>25 Questions · 15 Minutes · 50 Marks</h2><p>−0.50 per wrong · no Reading Comprehension · results only after submission.</p></div><button className="btn primary" disabled={!!creating} onClick={()=>void start("standard")}>{creating==="standard"?"Generating…":"Start"}</button></section>
  <section className="exam-readiness"><div className="section-title-line"><h2>Readiness</h2><span className="pill">45+ · SSC Standard only</span></div><div className="exam-metrics"><Metric label="Last Sprint" value={score(r?.lastSprint)}/><Metric label="5-Sprint Avg" value={score(r?.fiveSprintAverage)}/><Metric label="45+ Streak" value={r?.goalStreak??0}/><Metric label="Accuracy" value={r?.accuracy==null?"—":`${r.accuracy}%`}/><Metric label="Best" value={score(r?.best)}/><Metric label="Preventable Lost" value={r?.preventableMarksLost==null?"—":`${r.preventableMarksLost} marks`}/></div><div className="exam-readiness-note"><span>Known-but-missed <b>{r?.knownButMissed??0}</b></span><span>Targeted-missed <b>{r?.targetedMissed??0}</b></span><span>Avg time <b>{formatTime(r?.timeSeconds||0)}</b></span></div></section>
  <section className="exam-grid-two"><article className="exam-panel"><div className="section-title-line"><h2>My Exam Weaknesses</h2><span className="pill">Recent</span></div>{data?.weaknesses?.length?<div className="exam-list">{data.weaknesses.map(x=><div key={x.category}><span>{x.category}</span><b>{x.wrong} misses</b></div>)}</div>:<p className="muted">Complete a Sprint to build exam-condition weakness evidence.</p>}</article><article className="exam-panel"><div className="section-title-line"><h2>Targeted From Sprints</h2></div><div className="exam-targeted"><Metric label="Need Learning" value={data?.targetedFromSprints?.needLearning??0}/><Metric label="Recovered" value={data?.targetedFromSprints?.recovered??0}/></div></article></section>
  <section className="exam-panel"><div className="section-title-line"><h2>Recent Sprints</h2><span className="muted">Last 5 · all modes</span></div>{data?.recentSprints?.length?<div className="exam-history">{data.recentSprints.map(x=><div key={x.sessionId}><span><b>{modeMeta[(x.mode as Mode)]?.label||x.mode}</b><small>{new Date(x.completedAt).toLocaleDateString("en-IN")} · {formatTime(x.durationSeconds)}</small></span><span><b>{x.score} / {x.maxMarks??modeMaxMarks(x.mode,x.questionCount)}</b><small>{x.correct}C · {x.wrong}W · {x.unanswered}U</small></span></div>)}</div>:<p className="muted">No completed SSC Sprints yet.</p>}</section>
  <section className="exam-panel"><div className="section-title-line"><h2>GPT Exam Coach</h2><button className="btn ghost mini" onClick={()=>setMore(x=>!x)}>{more?"Less":"More Practice"}</button></div><div className="exam-coach-actions"><button className="btn soft" disabled={!!creating} onClick={()=>void start("weakness")}>Attack My Weaknesses</button><button className="btn soft" disabled={!!creating} onClick={()=>void start("trap")}>Practice My Traps</button>{more&&<button className="btn soft" disabled={!!creating} onClick={()=>void start("mistakes")}>Previous Mistakes</button>}</div>{data?.traps?.length?<div className="exam-traps">{data.traps.map(x=><span className="pill" key={x.trap}>{x.trap} · {x.count}</span>)}</div>:null}</section>
  <section className="exam-plan"><span className="eyebrow">Today’s Exam Plan</span><div className="exam-plan-list"><div><b>Targeted Revision</b><span>{data?.todayPlan?.targetedRevision??0} active signals</span></div><div><b>Fast Track</b><span>{data?.todayPlan?.fastTrackReady??0} ready</span></div><div><b>SSC Sprint</b><span>25Q · 15 min</span></div><div><b>Weakness Drill</b><span>{data?.todayPlan?.weaknessDrill||"Current weak areas"}</span></div></div><p>Guidance only — not a compulsory task scheduler.</p></section>
 </section>;
}

function SprintRunner({initial,onExit}:{initial:SprintSession;onExit:()=>void}){
 const[session,setSession]=useState(initial);
 const[idx,setIdx]=useState(0);
 const[answers,setAnswers]=useState<Record<number,Answer>>({});
 const[seconds,setSeconds]=useState(initial.durationLimitSeconds||900);
 const[submitting,setSubmitting]=useState(false);
 const[analyzing,setAnalyzing]=useState(false);
 const[diagnosis,setDiagnosis]=useState<Diagnosis[]>([]);
 const[error,setError]=useState("");
 const itemStarted=useRef(Date.now());
 const finishedRef=useRef(false);
 const historyGuardId=useRef("");
 const suppressBack=useRef(false);
 const leavingRef=useRef(false);
 const q=session.items[idx];
 const answer=q?answers[q.position]:undefined;

 function armSprintBackGuard(){
  if(typeof window==="undefined")return;
  const guard=historyGuardId.current;
  if(!guard||window.history.state?.englishSprintGuard===guard)return;
  window.history.pushState({...window.history.state,englishSprintGuard:guard},"",window.location.href);
 }
 const releaseSprintBackGuard=useCallback(async()=>{
  if(typeof window==="undefined")return;
  const guard=historyGuardId.current;
  if(!guard||window.history.state?.englishSprintGuard!==guard)return;
  await new Promise<void>(resolve=>{
   let done=false;
   const finishRelease=()=>{if(done)return;done=true;resolve();};
   suppressBack.current=true;
   window.addEventListener("popstate",finishRelease,{once:true});
   window.history.back();
   window.setTimeout(finishRelease,180);
  });
  if(window.history.state?.englishSprintGuard===guard){
   const next={...window.history.state};delete next.englishSprintGuard;window.history.replaceState(next,"",window.location.href);
  }
 },[]);

 useEffect(()=>{
  if(session.status==="completed")return;
  const guard=`english-sprint-${session.sessionId}-${Date.now()}`;
  historyGuardId.current=guard;
  armSprintBackGuard();
  const onBack=()=>{
   if(suppressBack.current){suppressBack.current=false;return;}
   if(finishedRef.current||leavingRef.current){armSprintBackGuard();return;}
   if(!window.confirm("Leave this Sprint? Unsubmitted answers will not be scored.")){armSprintBackGuard();return;}
   leavingRef.current=true;
   void rpc("english_abandon_sprint",{p_session_id:session.sessionId}).catch(()=>{}).finally(onExit);
  };
  const onBeforeUnload=(event:BeforeUnloadEvent)=>{
   if(finishedRef.current||leavingRef.current)return;
   event.preventDefault();event.returnValue="";
  };
  window.addEventListener("popstate",onBack);
  window.addEventListener("beforeunload",onBeforeUnload);
  return()=>{window.removeEventListener("popstate",onBack);window.removeEventListener("beforeunload",onBeforeUnload);};
 },[session.sessionId,session.status,onExit]);

 useEffect(()=>{if(session.status==="completed")return;const id=window.setInterval(()=>setSeconds(s=>Math.max(0,s-1)),1000);return()=>window.clearInterval(id);},[session.status]);

 const finish=useCallback(async()=>{
  if(finishedRef.current||submitting||session.status==="completed")return;
  finishedRef.current=true;setSubmitting(true);setError("");
  try{
   const payload=session.items.map(x=>answers[x.position]||{position:x.position,selectedKey:"",timeSeconds:0});
   const elapsed=Math.min(900,(initial.durationLimitSeconds||900)-seconds);
   const out=await rpc<SprintSession>("english_finish_sprint",{p_session_id:session.sessionId,p_answers:payload,p_duration_seconds:elapsed});
   await releaseSprintBackGuard();
   setSession(out);setAnalyzing(true);
   try{
    const {data:analysis,error:analysisError}=await supabaseBrowser().functions.invoke<any>("english-ssc-sprint",{body:{action:"analyze",sessionId:session.sessionId}});
    if(analysisError)throw analysisError;
    setDiagnosis(Array.isArray(analysis?.analysis)?analysis.analysis:[]);
    const {data:refreshed,error:refreshError}=await supabaseBrowser().rpc("english_get_sprint_session",{p_session_id:session.sessionId});
    if(refreshError)throw refreshError;
    setSession(refreshed as SprintSession);
   }catch(e:any){setError(`Score saved. GPT mistake analysis could not finish: ${e.message||e}`);}
   finally{setAnalyzing(false)}
  }catch(e:any){finishedRef.current=false;setError(learnerErrorMessage(e,"Could not submit this Sprint."));}
  finally{setSubmitting(false)}
 },[answers,initial.durationLimitSeconds,releaseSprintBackGuard,seconds,session,submitting]);

 useEffect(()=>{if(seconds===0&&session.status!=="completed"&&!finishedRef.current)void finish();},[seconds,session.status,finish]);

 function select(key:string){if(!q||session.status==="completed"||submitting)return;const spent=Math.min(180,(Date.now()-itemStarted.current)/1000);setAnswers(x=>({...x,[q.position]:{position:q.position,selectedKey:key,timeSeconds:spent}}));}
 function move(next:number){if(next<0||next>=session.items.length||submitting)return;setIdx(next);itemStarted.current=Date.now();window.scrollTo({top:0,behavior:"auto"});}
 async function exitSprint(){
  if(finishedRef.current||leavingRef.current||!window.confirm("Leave this Sprint? Unsubmitted answers will not be scored."))return;
  leavingRef.current=true;
  try{await rpc("english_abandon_sprint",{p_session_id:session.sessionId});}catch{}
  await releaseSprintBackGuard();
  onExit();
 }

 if(session.status==="completed")return <SprintResultView session={session} diagnosis={diagnosis.length?diagnosis:session.result?.analysis?.items||[]} analyzing={analyzing} error={error} onExit={onExit}/>;
 return <main className="sprint-runner"><div className="sprint-top"><button className="btn ghost" disabled={submitting} onClick={()=>void exitSprint()}>← Exit</button><div><b>{modeMeta[(session.mode as Mode)]?.label||"SSC Sprint"}</b><span>{idx+1} / {session.items.length}</span></div><time className={seconds<=60?"urgent":""}>{formatTime(seconds)}</time></div><div className="sprint-progress"><i style={{width:`${(Object.keys(answers).length/session.items.length)*100}%`}}/></div>{error&&<div className="error-box">{error}</div>}<section className="sprint-card"><div className="sprint-question-meta"><span>{q?.category||"English"}</span><span>Question {q?.position}</span></div><h2>{q?.question}</h2><div className="sprint-options">{q?.options?.map(o=><button key={o.key} className={`option ${answer?.selectedKey===o.key?"selected":""}`} disabled={submitting} onClick={()=>select(o.key)}><span className="option-key">{o.key}</span><span>{o.text}</span></button>)}</div></section><div className="sprint-palette">{session.items.map((x,i)=><button key={x.position} className={`${i===idx?"current":""} ${answers[x.position]?"answered":""}`} disabled={submitting} onClick={()=>move(i)}>{x.position}</button>)}</div><div className="sprint-nav"><button className="btn ghost" disabled={idx===0||submitting} onClick={()=>move(idx-1)}>← Previous</button>{idx<session.items.length-1?<button className="btn primary" disabled={submitting} onClick={()=>move(idx+1)}>Next →</button>:<button className="btn primary" disabled={submitting} onClick={()=>void finish()}>{submitting?"Submitting…":"Submit Sprint"}</button>}</div></main>;
}

function SprintResultView({session,diagnosis,analyzing,error,onExit}:{session:SprintSession;diagnosis:Diagnosis[];analyzing:boolean;error:string;onExit:()=>void}){
 const result=session.result;
 const diag=new Map(diagnosis.map(x=>[x.position,x]));
 const maxMarks=result?.maxMarks??session.questionCount*2;
 return <section className="sprint-result"><div className="sprint-result-head"><button className="btn ghost" onClick={onExit}>← Exam Preparation</button><div><span className="eyebrow">Sprint complete · {modeMeta[(session.mode as Mode)]?.label||session.mode}</span><h1>{result?.score??0} / {maxMarks}</h1><p>{result?.correct??0} correct · {result?.wrong??0} wrong · {result?.unanswered??0} unanswered · {formatTime(result?.durationSeconds||0)}</p></div></div>{error&&<div className="error-box">{error}</div>}<section className="exam-metrics"><Metric label="Score" value={`${result?.score??0} / ${maxMarks}`}/><Metric label="Accuracy" value={`${result?.accuracy??0}%`}/><Metric label="Correct" value={result?.correct??0}/><Metric label="Wrong" value={result?.wrong??0}/></section>{analyzing&&<div className="exam-panel"><b>GPT is classifying the misses into knowledge vs execution errors…</b></div>}<div className="sprint-review">{session.items.map(x=>{const d=diag.get(x.position);const selected=optionText(x.options,x.selectedKey);const correct=optionText(x.options,x.correctKey);return <article key={x.position} className="sprint-review-item"><div className="sprint-review-title"><span>Q{x.position} · {x.category}</span>{d&&<span className="pill">{d.diagnosis}</span>}</div><h3>{x.question}</h3><div className="sprint-answer-key"><span>Your answer</span><b>{selected}</b><span>Correct answer</span><b>{correct}</b></div>{x.explanation&&<p>{x.explanation}</p>}{d&&<div className="sprint-diagnosis"><b>Action: {d.action}</b>{d.confusedWith&&<span>Confused: {d.confusedWith}</span>}{d.rationale&&<span>{d.rationale}</span>}</div>}<small>Source: {x.sourceType||"Sprint"}{x.canonicalQuestionId?" · linked canonical concept":" · ephemeral Sprint item"}</small></article>})}</div></section>;
}

function Metric({label,value}:{label:string;value:string|number}){return <div><span>{label}</span><b>{value}</b></div>}
function score(value:number|null|undefined){return value==null?"—":`${value} / 50`}
function modeMaxMarks(mode:string,questionCount?:number){const count=questionCount??modeMeta[mode as Mode]?.count??0;return count*2;}
function optionText(options:SprintOption[],key?:string|null){if(!key)return "Unanswered";const option=options.find(x=>String(x.key).toUpperCase()===String(key).toUpperCase());return option?`${option.key}. ${option.text}`:String(key);}
function formatTime(value:number){const s=Math.max(0,Math.round(value||0));return `${String(Math.floor(s/60)).padStart(2,"0")}:${String(s%60).padStart(2,"0")}`}

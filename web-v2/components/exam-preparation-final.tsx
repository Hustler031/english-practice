"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, localProductionSafetyMode, rpc, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Readiness={lastSprint:number|null;fiveSprintAverage:number|null;best:number|null;lowest:number|null;accuracy:number|null;timeSeconds:number|null;goalStreak:number;knownButMissed:number;targetedMissed:number;preventableMarksLost:number};
type Weakness={category:string;wrong:number};
type Trap={trap:string;count:number};
type Recent={sessionId:string;mode:string;score:number;maxMarks?:number;questionCount?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;completedAt:string};
type ExamData={ok:boolean;targetDate:string;daysLeft:number;goalMarks:number;standard:{questions:number;minutes:number;marks:number;wrongPenalty:number;readingComprehension:boolean};readiness:Readiness;weaknesses:Weakness[];traps:Trap[];recentSprints:Recent[];targetedFromSprints:{needLearning:number;recovered:number};todayPlan:{targetedRevision:number;fastTrackReady:number;sprintQuestions:number;weaknessDrill:string}};
type SprintOption={key:string;text:string};
type SprintItem={position:number;category:string;questionType:string;question:string;options:SprintOption[];selectedKey?:string|null;visited?:boolean;markedForReview?:boolean;timeSeconds?:number;correctKey?:string;explanation?:string;sourceType?:string;canonicalQuestionId?:string|null};
type SprintResult={score:number;maxMarks?:number;correct:number;wrong:number;unanswered:number;accuracy:number;durationSeconds:number;analysis?:{items?:Diagnosis[]}};
type SprintSession={ok:boolean;active?:boolean;sessionId:string;mode:string;status:string;startedAt:string;pausedAt?:string|null;questionCount:number;durationLimitSeconds:number;remainingSeconds?:number;currentPosition?:number;items:SprintItem[];result?:SprintResult|null};
type Diagnosis={position:number;diagnosis:string;action:string;confusedWith?:string;rationale?:string};
type Answer={position:number;selectedKey:string;timeSeconds:number};
type Mode="standard"|"weakness"|"trap"|"mistakes";

type RuntimeSnapshot={answers:Record<number,Answer>;visited:Set<number>;review:Set<number>;idx:number;seconds:number};

const modeMeta:Record<Mode,{label:string;sub:string;count:number}>={
  standard:{label:"SSC Standard",sub:"Balanced exam simulation",count:25},
  weakness:{label:"Weakness Sprint",sub:"Fresh transfer from current weaknesses",count:15},
  trap:{label:"Trap Sprint",sub:"Close distractors around recurring traps",count:15},
  mistakes:{label:"Previous Mistakes",sub:"Fresh variants of earlier misses",count:10},
};

export default function ExamPreparationFinal(){
  const ready=useAuthGuard();
  const[data,setData]=useState<ExamData|null>(null);
  const[active,setActive]=useState<SprintSession|null>(null);
  const[session,setSession]=useState<SprintSession|null>(null);
  const[creating,setCreating]=useState<Mode|null>(null);
  const[error,setError]=useState("");
  const[infoOpen,setInfoOpen]=useState(false);
  const[more,setMore]=useState(false);

  const refresh=useCallback(async()=>{
    const [exam,activeSprint]=await Promise.all([
      supabaseBrowser().rpc("english_get_exam_preparation"),
      supabaseBrowser().rpc("english_get_active_sprint"),
    ]);
    if(exam.error)throw exam.error;
    if(activeSprint.error)throw activeSprint.error;
    setData(exam.data as ExamData);
    const current=activeSprint.data as SprintSession|undefined;
    setActive(current?.active?current:null);
  },[]);

  useEffect(()=>{if(ready)refresh().catch((e:any)=>setError(e.message||String(e)));},[ready,refresh]);

  async function start(mode:Mode){
    if(localProductionSafetyMode()){setError("Sprint creation is disabled in Local Safe because localhost is connected to production learning data.");return;}
    if(active){await resumeActive(active);return;}
    setCreating(mode);setError("");
    try{
      const {data:out,error:fnError}=await supabaseBrowser().functions.invoke<SprintSession>("english-ssc-sprint",{body:{action:"create",mode}});
      if(fnError)throw new Error(await edgeErrorMessage(fnError,"Could not create the SSC Sprint right now."));
      if(!out?.ok)throw new Error((out as any)?.error||"Could not create Sprint");
      setSession(out);
      setActive(out);
    }catch(e:any){setError(e?.message||learnerErrorMessage(e,"Could not create the SSC Sprint right now."));}
    finally{setCreating(null)}
  }

  async function resumeActive(current:SprintSession){
    setError("");
    try{
      const out=current.status==="paused"
        ?await rpc<SprintSession>("english_resume_sprint",{p_session_id:current.sessionId})
        :await rpc<SprintSession>("english_get_sprint_session",{p_session_id:current.sessionId});
      if(!out?.ok)throw new Error((out as any)?.error||"Could not resume Sprint");
      setSession(out);setActive(out);
    }catch(e:any){setError(learnerErrorMessage(e,"Could not resume the saved Sprint."));}
  }

  if(!ready)return <EnglishLoading text="Checking session…"/>;
  if(session)return <SprintRunner initial={session} onExit={()=>{setSession(null);void refresh()}}/>;

  const r=data?.readiness;
  const activeMeta=active?modeMeta[(active.mode as Mode)]||modeMeta.standard:null;
  return <section className="exam-clean-page">
    <header className="module-compact-head">
      <Link className="compact-back" href="/english">← Home</Link>
      <div className="compact-head-copy"><strong>Exam Preparation</strong><span>{data?`${data.daysLeft} days left · ${data.goalMarks}+ goal`:"SSC exam mode"}</span></div>
      <button className="compact-info" type="button" aria-label="Exam Preparation details" onClick={()=>setInfoOpen(true)}>i</button>
    </header>

    {error&&<div className="compact-error" role="alert">{error}</div>}

    {active&&<section className="resume-sprint-strip">
      <div><span>Saved Sprint</span><strong>{activeMeta?.label}</strong><small>Q {active.currentPosition||1}/{active.questionCount} · {formatTime(active.remainingSeconds??active.durationLimitSeconds??900)} remaining{active.status==="paused"?" · paused":""}</small></div>
      <button className="btn primary" type="button" onClick={()=>void resumeActive(active)}>Resume</button>
    </section>}

    <section className="exam-launch-card">
      <div className="exam-launch-title"><span>SSC STANDARD</span><h1>25 Questions · 15 Minutes</h1><p>50 marks · −0.50 wrong · no Reading Comprehension</p></div>
      <button className="exam-start-button" type="button" disabled={!!creating||!!active} onClick={()=>void start("standard")}>{active?"Resume saved Sprint":creating==="standard"?"Generating…":"Start Sprint"}</button>
    </section>

    <section className="exam-more-row">
      <div className="section-inline-title"><strong>More Practice</strong><button type="button" onClick={()=>setMore(x=>!x)}>{more?"Less":"More"}</button></div>
      <div className="exam-practice-actions">
        <button type="button" disabled={!!creating||!!active} onClick={()=>void start("weakness")}>Weakness</button>
        <button type="button" disabled={!!creating||!!active} onClick={()=>void start("trap")}>My Traps</button>
        {more&&<button type="button" disabled={!!creating||!!active} onClick={()=>void start("mistakes")}>Previous Mistakes</button>}
      </div>
    </section>

    <section className="readiness-strip" aria-label="SSC Standard readiness">
      <MiniMetric label="Last" value={score(r?.lastSprint)}/>
      <MiniMetric label="5-Sprint Avg" value={score(r?.fiveSprintAverage)}/>
      <MiniMetric label="45+ Streak" value={r?.goalStreak??0}/>
    </section>

    <p className="exam-clean-note">Readiness counts SSC Standard Sprints only. Full analysis is under <b>i</b>.</p>

    {infoOpen&&<ExamInfo data={data} onClose={()=>setInfoOpen(false)}/>} 
  </section>;
}

function ExamInfo({data,onClose}:{data:ExamData|null;onClose:()=>void}){
  const r=data?.readiness;
  return <div className="clean-modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)onClose()}}>
    <section className="clean-modal" role="dialog" aria-modal="true" aria-label="Exam Preparation details">
      <header><div><strong>Exam Intelligence</strong><span>Details stay out of the main study flow.</span></div><button type="button" aria-label="Close" onClick={onClose}>×</button></header>
      <div className="info-metric-grid">
        <MiniMetric label="Last Sprint" value={score(r?.lastSprint)}/><MiniMetric label="5-Sprint Avg" value={score(r?.fiveSprintAverage)}/><MiniMetric label="Best" value={score(r?.best)}/><MiniMetric label="Accuracy" value={r?.accuracy==null?"—":`${r.accuracy}%`}/><MiniMetric label="45+ Streak" value={r?.goalStreak??0}/><MiniMetric label="Preventable Lost" value={r?.preventableMarksLost==null?"—":`${r.preventableMarksLost} marks`}/>
      </div>
      <InfoSection title="Current Weaknesses">{data?.weaknesses?.length?<div className="simple-list">{data.weaknesses.map(x=><div key={x.category}><span>{pretty(x.category)}</span><b>{x.wrong} misses</b></div>)}</div>:<p>No Sprint weakness evidence yet.</p>}</InfoSection>
      <InfoSection title="Targeted from Sprints"><div className="inline-stat-pair"><span>Need learning <b>{data?.targetedFromSprints?.needLearning??0}</b></span><span>Recovered <b>{data?.targetedFromSprints?.recovered??0}</b></span></div></InfoSection>
      <InfoSection title="Recent Sprints">{data?.recentSprints?.length?<div className="simple-list">{data.recentSprints.map(x=><div key={x.sessionId}><span>{modeMeta[(x.mode as Mode)]?.label||x.mode}<small>{new Date(x.completedAt).toLocaleDateString("en-IN")} · {formatTime(x.durationSeconds)}</small></span><b>{x.score}/{x.maxMarks??modeMaxMarks(x.mode,x.questionCount)}</b></div>)}</div>:<p>No completed Sprints yet.</p>}</InfoSection>
      <InfoSection title="Today’s Plan"><div className="simple-list"><div><span>Targeted Revision</span><b>{data?.todayPlan?.targetedRevision??0}</b></div><div><span>Fast Track ready</span><b>{data?.todayPlan?.fastTrackReady??0}</b></div><div><span>Weakness focus</span><b>{data?.todayPlan?.weaknessDrill||"Current weak areas"}</b></div></div></InfoSection>
    </section>
  </div>;
}

function InfoSection({title,children}:{title:string;children:React.ReactNode}){return <section className="info-section"><h3>{title}</h3>{children}</section>}

function SprintRunner({initial,onExit}:{initial:SprintSession;onExit:()=>void}){
  const initialPosition=clampPosition(initial.currentPosition||1,initial.items.length);
  const[session,setSession]=useState(initial);
  const[idx,setIdx]=useState(Math.max(0,initial.items.findIndex(x=>x.position===initialPosition)));
  const[answers,setAnswers]=useState<Record<number,Answer>>(()=>answersFrom(initial.items));
  const[visited,setVisited]=useState<Set<number>>(()=>visitedFrom(initial.items,initialPosition));
  const[review,setReview]=useState<Set<number>>(()=>reviewFrom(initial.items));
  const[seconds,setSeconds]=useState(initial.remainingSeconds??initial.durationLimitSeconds??900);
  const[mapOpen,setMapOpen]=useState(false);
  const[submitting,setSubmitting]=useState(false);
  const[pausing,setPausing]=useState(false);
  const[analyzing,setAnalyzing]=useState(false);
  const[diagnosis,setDiagnosis]=useState<Diagnosis[]>([]);
  const[error,setError]=useState("");
  const itemStarted=useRef(Date.now());
  const finishedRef=useRef(false);
  const leavingRef=useRef(false);
  const historyGuardId=useRef("");
  const suppressBack=useRef(false);
  const saveTimer=useRef<number|null>(null);
  const persistChain=useRef<Promise<unknown>>(Promise.resolve());
  const runtimeRef=useRef<RuntimeSnapshot>({answers,visited,review,idx,seconds});
  const q=session.items[idx];
  const answer=q?answers[q.position]:undefined;

  useEffect(()=>{runtimeRef.current={answers,visited,review,idx,seconds};},[answers,visited,review,idx,seconds]);
  useEffect(()=>{document.body.classList.add("english-sprint-mode");return()=>document.body.classList.remove("english-sprint-mode");},[]);

  const persistSnapshot=useCallback((snapshot:RuntimeSnapshot)=>{
    const items=runtimePayload(session.items,snapshot.answers,snapshot.visited,snapshot.review);
    const position=session.items[snapshot.idx]?.position||1;
    const task=()=>rpc("english_save_sprint_progress",{p_session_id:session.sessionId,p_items:items,p_current_position:position,p_remaining_seconds:snapshot.seconds});
    const queued=persistChain.current.catch(()=>undefined).then(task);
    persistChain.current=queued.catch(()=>undefined);
    return queued;
  },[session.items,session.sessionId]);

  const queuePersist=useCallback((snapshot:RuntimeSnapshot)=>{
    if(saveTimer.current)window.clearTimeout(saveTimer.current);
    saveTimer.current=window.setTimeout(()=>{saveTimer.current=null;void persistSnapshot(snapshot).catch(()=>{});},420);
  },[persistSnapshot]);

  const flushProgress=useCallback(async(snapshot=runtimeRef.current)=>{
    if(saveTimer.current){window.clearTimeout(saveTimer.current);saveTimer.current=null;}
    await persistChain.current.catch(()=>undefined);
    await persistSnapshot(snapshot);
  },[persistSnapshot]);

  function armSprintBackGuard(){
    if(typeof window==="undefined"||session.status!=="in_progress")return;
    const guard=historyGuardId.current;
    if(!guard||window.history.state?.englishSprintGuard===guard)return;
    window.history.pushState({...window.history.state,englishSprintGuard:guard},"",window.location.href);
  }

  const releaseSprintBackGuard=useCallback(async()=>{
    if(typeof window==="undefined")return;
    const guard=historyGuardId.current;
    if(!guard||window.history.state?.englishSprintGuard!==guard)return;
    await new Promise<void>(resolve=>{
      let done=false;const finish=()=>{if(done)return;done=true;resolve()};
      suppressBack.current=true;window.addEventListener("popstate",finish,{once:true});window.history.back();window.setTimeout(finish,180);
    });
    if(window.history.state?.englishSprintGuard===guard){const next={...window.history.state};delete next.englishSprintGuard;window.history.replaceState(next,"",window.location.href)}
  },[]);

  const pauseWithSnapshot=useCallback(async(leaveAfter=false)=>{
    if(pausing||submitting||session.status!=="in_progress")return;
    setPausing(true);setError("");
    try{
      const snapshot=runtimeRef.current;
      if(saveTimer.current){window.clearTimeout(saveTimer.current);saveTimer.current=null;}
      await persistChain.current.catch(()=>undefined);
      const out=await rpc<SprintSession>("english_pause_sprint",{p_session_id:session.sessionId,p_items:runtimePayload(session.items,snapshot.answers,snapshot.visited,snapshot.review),p_current_position:session.items[snapshot.idx]?.position||1,p_remaining_seconds:snapshot.seconds});
      await releaseSprintBackGuard();
      setSession(out);setSeconds(out.remainingSeconds??snapshot.seconds);
      if(leaveAfter)onExit();
    }catch(e:any){setError(learnerErrorMessage(e,"Could not pause and save this Sprint."));}
    finally{setPausing(false)}
  },[onExit,pausing,releaseSprintBackGuard,session,submitting]);

  useEffect(()=>{
    if(session.status!=="in_progress")return;
    const guard=`english-sprint-${session.sessionId}-${Date.now()}`;historyGuardId.current=guard;armSprintBackGuard();
    const onBack=()=>{
      if(suppressBack.current){suppressBack.current=false;return;}
      if(finishedRef.current||leavingRef.current){armSprintBackGuard();return;}
      if(!window.confirm("Pause this Sprint and leave? Your progress will be saved.")){armSprintBackGuard();return;}
      leavingRef.current=true;void pauseWithSnapshot(true).finally(()=>{leavingRef.current=false});
    };
    const onBeforeUnload=(event:BeforeUnloadEvent)=>{if(finishedRef.current||leavingRef.current)return;event.preventDefault();event.returnValue=""};
    window.addEventListener("popstate",onBack);window.addEventListener("beforeunload",onBeforeUnload);
    return()=>{window.removeEventListener("popstate",onBack);window.removeEventListener("beforeunload",onBeforeUnload)};
  },[pauseWithSnapshot,session.sessionId,session.status]);

  useEffect(()=>{if(session.status!=="in_progress")return;const id=window.setInterval(()=>setSeconds(s=>Math.max(0,s-1)),1000);return()=>window.clearInterval(id)},[session.status]);

  const finish=useCallback(async()=>{
    if(finishedRef.current||submitting||session.status!=="in_progress")return;
    finishedRef.current=true;setSubmitting(true);setMapOpen(false);setError("");
    try{
      const snapshot=runtimeRef.current;
      if(saveTimer.current){window.clearTimeout(saveTimer.current);saveTimer.current=null;}
      await persistChain.current.catch(()=>undefined);
      const payload=session.items.map(x=>snapshot.answers[x.position]||{position:x.position,selectedKey:"",timeSeconds:0});
      const elapsed=Math.min(900,(initial.durationLimitSeconds||900)-snapshot.seconds);
      const out=await rpc<SprintSession>("english_finish_sprint",{p_session_id:session.sessionId,p_answers:payload,p_duration_seconds:elapsed});
      await releaseSprintBackGuard();setSession(out);setAnalyzing(true);
      try{
        const {data:analysis,error:analysisError}=await supabaseBrowser().functions.invoke<any>("english-ssc-sprint",{body:{action:"analyze",sessionId:session.sessionId}});
        if(analysisError)throw new Error(await edgeErrorMessage(analysisError,"GPT mistake analysis could not finish."));
        setDiagnosis(Array.isArray(analysis?.analysis)?analysis.analysis:[]);
        const refreshed=await rpc<SprintSession>("english_get_sprint_session",{p_session_id:session.sessionId});setSession(refreshed);
      }catch(e:any){setError(`Score saved. ${e?.message||"GPT mistake analysis could not finish."}`)}
      finally{setAnalyzing(false)}
    }catch(e:any){finishedRef.current=false;setError(learnerErrorMessage(e,"Could not submit this Sprint."))}
    finally{setSubmitting(false)}
  },[initial.durationLimitSeconds,releaseSprintBackGuard,session,submitting]);

  useEffect(()=>{if(seconds===0&&session.status==="in_progress"&&!finishedRef.current)void finish()},[seconds,session.status,finish]);

  function select(key:string){
    if(!q||session.status!=="in_progress"||submitting)return;
    const nextAnswers={...answers,[q.position]:{position:q.position,selectedKey:key,timeSeconds:Math.min(180,(Date.now()-itemStarted.current)/1000)}};
    const nextVisited=new Set(visited);nextVisited.add(q.position);
    setAnswers(nextAnswers);setVisited(nextVisited);
    queuePersist({answers:nextAnswers,visited:nextVisited,review,idx,seconds});
  }

  function clearResponse(){
    if(!q||session.status!=="in_progress")return;
    const nextAnswers={...answers};delete nextAnswers[q.position];
    const nextVisited=new Set(visited);nextVisited.add(q.position);
    setAnswers(nextAnswers);setVisited(nextVisited);queuePersist({answers:nextAnswers,visited:nextVisited,review,idx,seconds});
  }

  function toggleReview(){
    if(!q||session.status!=="in_progress")return;
    const nextReview=new Set(review);nextReview.has(q.position)?nextReview.delete(q.position):nextReview.add(q.position);
    const nextVisited=new Set(visited);nextVisited.add(q.position);
    setReview(nextReview);setVisited(nextVisited);queuePersist({answers,visited:nextVisited,review:nextReview,idx,seconds});
  }

  function move(next:number){
    if(next<0||next>=session.items.length||submitting||session.status!=="in_progress")return;
    const nextVisited=new Set(visited);nextVisited.add(session.items[next].position);setVisited(nextVisited);setIdx(next);itemStarted.current=Date.now();window.scrollTo({top:0,behavior:"auto"});queuePersist({answers,visited:nextVisited,review,idx:next,seconds});
  }

  async function resumePaused(){
    setError("");
    try{const out=await rpc<SprintSession>("english_resume_sprint",{p_session_id:session.sessionId});hydrate(out)}catch(e:any){setError(learnerErrorMessage(e,"Could not resume this Sprint."))}
  }

  function hydrate(next:SprintSession){
    const pos=clampPosition(next.currentPosition||1,next.items.length);setSession(next);setSeconds(next.remainingSeconds??next.durationLimitSeconds??900);setAnswers(answersFrom(next.items));setVisited(visitedFrom(next.items,pos));setReview(reviewFrom(next.items));setIdx(Math.max(0,next.items.findIndex(x=>x.position===pos)));itemStarted.current=Date.now();
  }

  async function abandon(){
    if(leavingRef.current||!window.confirm("Abandon this Sprint? Saved answers will remain in history but this attempt will not be scored."))return;
    leavingRef.current=true;
    try{await rpc("english_abandon_sprint",{p_session_id:session.sessionId})}catch{}
    await releaseSprintBackGuard();onExit();
  }

  if(session.status==="completed")return <SprintResultView session={session} diagnosis={diagnosis.length?diagnosis:session.result?.analysis?.items||[]} analyzing={analyzing} error={error} onExit={onExit}/>;

  if(session.status==="paused")return <main className="sprint-runner sprint-paused-screen"><section className="pause-panel"><span className="pause-icon">Ⅱ</span><h1>Sprint Paused</h1><p>{formatTime(seconds)} remaining</p><small>Your answers, visited questions, review marks and position are saved.</small><button className="btn primary" type="button" onClick={()=>void resumePaused()}>Resume Sprint</button><button className="btn ghost" type="button" onClick={onExit}>Leave & Resume Later</button><button className="pause-abandon" type="button" onClick={()=>void abandon()}>Abandon attempt</button>{error&&<div className="compact-error">{error}</div>}</section></main>;

  const answeredCount=Object.values(answers).filter(x=>!!x.selectedKey).length;
  const visitedUnanswered=[...visited].filter(p=>!answers[p]?.selectedKey&&!review.has(p)).length;
  const notVisited=Math.max(0,session.items.length-visited.size);
  return <main className="sprint-runner sprint-clean-runner">
    <header className="sprint-command-bar">
      <button className="sprint-exit" type="button" disabled={submitting||pausing} onClick={()=>void abandon()}>Exit</button>
      <div className="sprint-command-title"><strong>{modeMeta[(session.mode as Mode)]?.label||"SSC Sprint"}</strong><span>Q {idx+1}/{session.items.length}</span></div>
      <div className="sprint-command-actions"><button type="button" className="sprint-icon-button" disabled={submitting||pausing} onClick={()=>void pauseWithSnapshot(false)} aria-label="Pause Sprint" title="Pause and save">Ⅱ</button><time className={seconds<=60?"urgent":""}>{formatTime(seconds)}</time><button type="button" className="sprint-icon-button map-button" onClick={()=>setMapOpen(true)} aria-label="Open question map" title="Question map">▦</button></div>
    </header>
    <div className="sprint-thin-progress"><i style={{width:`${(answeredCount/session.items.length)*100}%`}}/></div>
    {error&&<div className="compact-error" role="alert">{error}</div>}

    <section className="sprint-question-clean">
      <div className="question-eyebrow"><span>{pretty(q?.category||"English")}</span><span>Question {q?.position}</span></div>
      <h1>{q?.question}</h1>
      <div className="sprint-options-clean">{q?.options?.map(o=><button type="button" key={o.key} className={answer?.selectedKey===o.key?"selected":""} disabled={submitting} onClick={()=>select(o.key)}><span>{o.key}</span><b>{o.text}</b></button>)}</div>
      {answer?.selectedKey&&<button type="button" className="clear-response" onClick={clearResponse}>Clear response</button>}
    </section>

    <nav className="sprint-bottom-actions" aria-label="Sprint question controls">
      <button type="button" className="previous" disabled={idx===0||submitting} onClick={()=>move(idx-1)}>← Previous</button>
      <button type="button" className={review.has(q?.position||0)?"review active":"review"} disabled={submitting} onClick={toggleReview}>{review.has(q?.position||0)?"★ Marked":"☆ Mark for Review"}</button>
      {idx<session.items.length-1?<button type="button" className="save-next" disabled={submitting} onClick={()=>move(idx+1)}>Save & Next →</button>:<button type="button" className="save-next" disabled={submitting} onClick={()=>setMapOpen(true)}>Review Test →</button>}
    </nav>

    {mapOpen&&<QuestionMap session={session} idx={idx} answers={answers} visited={visited} review={review} answered={answeredCount} visitedUnanswered={visitedUnanswered} notVisited={notVisited} submitting={submitting} onJump={position=>{const next=session.items.findIndex(x=>x.position===position);if(next>=0)move(next);setMapOpen(false)}} onClose={()=>setMapOpen(false)} onSubmit={()=>{const unanswered=session.items.length-answeredCount;if(unanswered>0&&!window.confirm(`Submit with ${unanswered} unanswered question${unanswered===1?"":"s"}?`))return;void finish()}}/>}
  </main>;
}

function QuestionMap({session,idx,answers,visited,review,answered,visitedUnanswered,notVisited,submitting,onJump,onClose,onSubmit}:{session:SprintSession;idx:number;answers:Record<number,Answer>;visited:Set<number>;review:Set<number>;answered:number;visitedUnanswered:number;notVisited:number;submitting:boolean;onJump:(position:number)=>void;onClose:()=>void;onSubmit:()=>void}){
  return <div className="question-map-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)onClose()}}><aside className="question-map-drawer" role="dialog" aria-modal="true" aria-label="Question map"><header><div><strong>Question Map</strong><span>Jump, review and submit</span></div><button type="button" onClick={onClose} aria-label="Close question map">×</button></header><div className="question-map-legend"><span><i className="answered"/>Answered</span><span><i className="visited"/>Visited</span><span><i className="review"/>Review</span><span><i className="unvisited"/>Not visited</span></div><div className="question-map-grid">{session.items.map((item,n)=>{const isReview=review.has(item.position);const isAnswered=!!answers[item.position]?.selectedKey;const isVisited=visited.has(item.position);const state=isReview?"review":isAnswered?"answered":isVisited?"visited":"unvisited";return <button type="button" key={item.position} className={`${state} ${n===idx?"current":""} ${isReview&&isAnswered?"review-answered":""}`} onClick={()=>onJump(item.position)} aria-label={`Question ${item.position}, ${state}`}>{item.position}</button>})}</div><div className="question-map-counts"><span>Answered <b>{answered}</b></span><span>Visited <b>{visitedUnanswered}</b></span><span>Review <b>{review.size}</b></span><span>Not visited <b>{notVisited}</b></span></div><button className="submit-sprint-button" type="button" disabled={submitting} onClick={onSubmit}>{submitting?"Submitting…":"Submit Sprint"}</button></aside></div>;
}

function SprintResultView({session,diagnosis,analyzing,error,onExit}:{session:SprintSession;diagnosis:Diagnosis[];analyzing:boolean;error:string;onExit:()=>void}){
  const result=session.result;const maxMarks=result?.maxMarks??session.questionCount*2;const diagnosisMap=new Map(diagnosis.map(x=>[x.position,x]));
  return <main className="sprint-result-clean"><header className="module-compact-head"><button className="compact-back" type="button" onClick={onExit}>← Exam Prep</button><div className="compact-head-copy"><strong>Sprint Result</strong><span>{modeMeta[(session.mode as Mode)]?.label||session.mode}</span></div><span/></header><section className="result-score-hero"><span>Score</span><strong>{result?.score??0}<small>/{maxMarks}</small></strong><p>{(result?.score??0)>=45&&session.mode==="standard"?"45+ target reached":"Review the misses, then move on."}</p></section><div className="result-mini-grid"><MiniMetric label="Correct" value={result?.correct??0}/><MiniMetric label="Wrong" value={result?.wrong??0}/><MiniMetric label="Unanswered" value={result?.unanswered??0}/><MiniMetric label="Accuracy" value={`${result?.accuracy??0}%`}/></div>{analyzing&&<p className="analysis-loading">GPT is classifying the misses…</p>}{error&&<div className="compact-error">{error}</div>}<section className="result-review-list"><h2>Review</h2>{session.items.map(x=>{const d=diagnosisMap.get(x.position);return <article key={x.position} className={x.selectedKey===x.correctKey?"correct":"missed"}><div className="result-question-head"><span>Q{x.position} · {pretty(x.category)}</span><b>{x.selectedKey===x.correctKey?"Correct":"Review"}</b></div><h3>{x.question}</h3><div className="answer-review"><p><span>Your answer</span><b>{optionText(x.options,x.selectedKey)||"Unanswered"}</b></p><p><span>Correct answer</span><b>{optionText(x.options,x.correctKey)||x.correctKey||"—"}</b></p></div>{x.explanation&&<p className="result-explanation">{x.explanation}</p>}{d&&<div className="diagnosis-line"><b>{d.diagnosis}</b><span>{d.action}</span>{d.confusedWith&&<small>{d.confusedWith}</small>}{d.rationale&&<p>{d.rationale}</p>}</div>}</article>})}</section><button className="btn primary result-done" type="button" onClick={onExit}>Done</button></main>;
}

function MiniMetric({label,value}:{label:string;value:string|number}){return <div className="mini-metric"><span>{label}</span><strong>{value}</strong></div>}

function answersFrom(items:SprintItem[]){const out:Record<number,Answer>={};for(const x of items)if(x.selectedKey)out[x.position]={position:x.position,selectedKey:x.selectedKey,timeSeconds:Number(x.timeSeconds||0)};return out}
function visitedFrom(items:SprintItem[],current:number){const out=new Set<number>(items.filter(x=>x.visited||x.selectedKey).map(x=>x.position));if(current)out.add(current);return out}
function reviewFrom(items:SprintItem[]){return new Set<number>(items.filter(x=>x.markedForReview).map(x=>x.position))}
function runtimePayload(items:SprintItem[],answers:Record<number,Answer>,visited:Set<number>,review:Set<number>){return items.map(x=>({position:x.position,selectedKey:answers[x.position]?.selectedKey||null,timeSeconds:answers[x.position]?.timeSeconds||0,visited:visited.has(x.position),markedForReview:review.has(x.position)}))}
function clampPosition(position:number,count:number){return Math.min(Math.max(1,position||1),Math.max(1,count))}
function score(v:number|null|undefined){return v==null?"—":Number(v).toFixed(Number.isInteger(Number(v))?0:1)}
function formatTime(seconds:number){const safe=Math.max(0,Math.round(seconds||0));return `${String(Math.floor(safe/60)).padStart(2,"0")}:${String(safe%60).padStart(2,"0")}`}
function modeMaxMarks(mode:string,count?:number){return (count??modeMeta[(mode as Mode)]?.count??25)*2}
function optionText(options:SprintOption[]|undefined,key:string|null|undefined){if(!key)return "";const found=options?.find(x=>x.key===key);return found?`${found.key}. ${found.text}`:key}
function pretty(value:string){return value.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase())}
async function edgeErrorMessage(error:any,fallback:string){
  const response=error?.context;
  if(response&&typeof response.clone==="function"){
    try{const body=await response.clone().json();if(body?.error)return String(body.error);if(body?.message)return String(body.message)}catch{}
    try{const text=await response.clone().text();if(text?.trim())return text.trim()}catch{}
  }
  return learnerErrorMessage(error,fallback);
}

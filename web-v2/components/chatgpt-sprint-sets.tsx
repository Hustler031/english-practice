"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import ExamPreparationFinal from "@/components/exam-preparation-final";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import styles from "./chatgpt-sprint-sets.module.css";

type SetState={
  ok:boolean;active?:boolean;sessionId?:string|null;status?:string;setNo?:number|null;
  criticStatus?:string|null;criticAttempts?:number;criticError?:string|null;criticScore?:number|null;
  createdAt?:string|null;preparedBy?:string|null;error?:string;
};
type Readiness={lastSprint:number|null;fiveSprintAverage:number|null;goalStreak:number};
type ExamData={ok:boolean;daysLeft:number;goalMarks:number;readiness:Readiness};

export default function ChatgptSprintSets(){
  const ready=useAuthGuard();
  const[state,setState]=useState<SetState|null>(null);
  const[data,setData]=useState<ExamData|null>(null);
  const[error,setError]=useState("");

  const refresh=useCallback(async()=>{
    const [stateResult,exam]=await Promise.all([
      supabaseBrowser().rpc("english_get_chatgpt_sprint_state"),
      supabaseBrowser().rpc("english_get_exam_preparation"),
    ]);
    if(stateResult.error)throw stateResult.error;
    if(exam.error)throw exam.error;
    setState(stateResult.data as SetState);setData(exam.data as ExamData);setError("");
  },[]);

  useEffect(()=>{if(ready)void refresh().catch(e=>setError(learnerErrorMessage(e,"Could not load Sprint sets.")))},[ready,refresh]);
  useEffect(()=>{
    if(!ready)return;
    const id=window.setInterval(()=>void refresh().catch(()=>{}),3000);
    return()=>window.clearInterval(id);
  },[ready,refresh]);

  if(!ready)return <EnglishLoading text="Checking Sprint sets…"/>;

  // Once Luna has passed a set, reuse the mature existing Sprint runner/lifecycle.
  // The wrapper hides the retired app-side generation controls; only Start/Resume
  // for the already-approved set remains available.
  if(state?.active&&state.sessionId){
    return <div className={styles.activeShell} data-status={state.status||"ready"}>
      <div className={styles.setBanner}>
        <span>{state.status==="ready"?"LUNA PASSED":"ACTIVE SET"}</span>
        <strong>Set {state.setNo??"—"}</strong>
        <small>{state.status==="ready"?"25-question SSC set is approved · tap Start Now below":state.status==="paused"?"Saved attempt · resume when ready":"Sprint in progress"}</small>
      </div>
      <ExamPreparationFinal/>
    </div>;
  }

  const r=data?.readiness;
  const pending=state?.status==="critic_pending";
  const rejected=state?.status==="critic_failed";
  return <section className="exam-clean-page">
    <header className="module-compact-head">
      <Link className="compact-back" href="/english">← Home</Link>
      <div className="compact-head-copy"><strong>Exam Sprint</strong><span>{data?`${data.daysLeft} days left · ${data.goalMarks}+ goal`:"SSC CGL set mode"}</span></div>
      <span/>
    </header>

    {error&&<div className="compact-error" role="alert">{error}</div>}

    {pending&&<section className="resume-sprint-strip">
      <div><span>FINAL QUALITY GATE</span><strong>Luna is checking the full 25-question set</strong><small>Historical repeats, semantic duplicates, answer validity, SSC level, difficulty and distractors are checked together.</small></div>
      <button className="btn primary" type="button" disabled>Reviewing…</button>
    </section>}

    {rejected&&<div className="compact-error" role="alert">
      Luna rejected the last draft{state.criticScore!=null?` (${Number(state.criticScore).toFixed(0)}/100)`:""}. {state.criticError||"Prepare a cleaner set."}
    </div>}

    <section className="exam-launch-card">
      <div className="exam-launch-title">
        <span>CHATGPT → SELF-CRITIC → LUNA</span>
        <h1>25 Questions · 15 Minutes</h1>
        <p>50 marks · −0.50 wrong · no Reading Comprehension</p>
      </div>
      <div className={styles.chatInstruction}>
        <strong>{pending?"Set is being reviewed":rejected?"Create a replacement set":"Create the next set in ChatGPT"}</strong>
        <span>Type <b>create sprint</b> in ChatGPT. The app never generates the question set itself.</span>
      </div>
    </section>

    <section className="readiness-strip" aria-label="SSC Standard readiness">
      <MiniMetric label="Last" value={score(r?.lastSprint)}/>
      <MiniMetric label="5-Sprint Avg" value={score(r?.fiveSprintAverage)}/>
      <MiniMetric label="45+ Streak" value={r?.goalStreak??0}/>
    </section>

    <p className="exam-clean-note">A set becomes startable only after both ChatGPT self-review and the independent Luna full-set gate pass.</p>
  </section>;
}

function MiniMetric({label,value}:{label:string;value:string|number}){return <div className="mini-metric"><span>{label}</span><strong>{value}</strong></div>}
function score(v:number|null|undefined){return v==null?"—":Number(v).toFixed(Number.isInteger(Number(v))?0:1)}

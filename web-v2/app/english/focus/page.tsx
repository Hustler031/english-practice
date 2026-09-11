"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { flushPendingAnswers, learnerErrorMessage, localProductionSafetyMode, pendingAnswerSaves, rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type LaneKey = "repair" | "coverage" | "fast_track";
type RunningKey = LaneKey | "review_due";
type LaneProgress = { target:number; nominalTarget:number; completed:number; remaining:number; done:boolean };
type FocusSummary = {
  ok:boolean;
  today:string;
  batchDate:string;
  carryover:boolean;
  status:"active"|"completed";
  total:number;
  completed:number;
  remaining:number;
  nominalTarget:number;
  lanes:{ repair:LaneProgress; coverage:LaneProgress; fastTrack:LaneProgress };
};
type ReviewDueSummary = {
  ok:boolean;
  date:string;
  phase:string;
  snapshotReady:boolean;
  dueQuestionCount:number;
  dueAtStart:number;
  satisfied:number;
  satisfiedElsewhere:number;
  needsRepair:number;
  lowConfidence:number;
  remaining:number;
  actionable?:number;
  routingChanged:boolean;
  countsTowardDailyFocus:boolean;
  practiceEnabled?:boolean;
};

type Question = { id:string; question:string; options:{key:string;text:string}[] };

const lanes:{key:LaneKey;summaryKey:keyof FocusSummary["lanes"];icon:string;title:string;subtitle:string;module:string;fastTrack:boolean;accent:string}[] = [
  { key:"repair", summaryKey:"repair", icon:"◎", title:"Repair Intelligence", subtitle:"Weak · Persistent Weak · Starred · My Saved", module:"dailyfocusrepair", fastTrack:false, accent:"accent-starred" },
  { key:"coverage", summaryKey:"coverage", icon:"▦", title:"Bank Coverage", subtitle:"20 pending siblings from seen concepts · 50 new canonical concepts", module:"bankcoverage", fastTrack:false, accent:"accent-bank" },
  { key:"fast_track", summaryKey:"fastTrack", icon:"⚡", title:"Fast-Track Mastery", subtitle:"Existing Central Intelligence Fast Track queue", module:"fasttrack", fastTrack:true, accent:"accent-phrasal" },
];

async function settlePendingAnswers(maxMs=1600){
  flushPendingAnswers();
  const deadline=Date.now()+maxMs;
  while(pendingAnswerSaves()>0&&Date.now()<deadline){
    await new Promise(resolve=>window.setTimeout(resolve,75));
  }
}

export default function DailyFocusPage(){
  const ready=useAuthGuard();
  const[summary,setSummary]=useState<FocusSummary|null>(null);
  const[reviewDue,setReviewDue]=useState<ReviewDueSummary|null>(null);
  const[running,setRunning]=useState<RunningKey|null>(null);
  const[error,setError]=useState("");
  const localSafe=localProductionSafetyMode();

  const refresh=useCallback(async()=>{
    const data=await rpc<FocusSummary>("english_get_daily_focus_summary");
    setSummary(data);
    setError("");
    return data;
  },[]);
  const refreshReview=useCallback(async()=>{
    const data=await rpc<ReviewDueSummary>("english_get_review_due_today");
    setReviewDue(data);
    return data;
  },[]);

  useEffect(()=>{
    if(!ready)return;
    const unsubscribe=subscribeRpcFresh<ReviewDueSummary>("english_get_review_due_today",undefined,setReviewDue);
    const onDurable=()=>{void refresh();void refreshReview();};
    window.addEventListener("ep:answer-durable",onDurable);
    void Promise.all([refresh(),refreshReview()]).catch((e:any)=>setError(learnerErrorMessage(e,"Daily Focus is taking longer than usual. Please retry.")));
    return()=>{unsubscribe();window.removeEventListener("ep:answer-durable",onDurable);};
  },[ready,refresh,refreshReview]);

  const load=useCallback(async()=>{
    if(!running)return [];
    if(running==="review_due"){
      await settlePendingAnswers();
      return rpc<Question[]>("english_get_review_due_lane",{p_nonce:`${Date.now()}-${Math.random().toString(36).slice(2,8)}`});
    }
    return rpc<Question[]>("english_get_daily_focus_lane",{p_lane:running});
  },[running]);

  if(!ready)return <EnglishLoading text="Checking session…"/>;

  if(running&&summary){
    if(running==="review_due"){
      const action=reviewDue?.actionable??((reviewDue?.needsRepair||0)+(reviewDue?.lowConfidence||0)+(reviewDue?.remaining||0));
      return <QuizRunner
        title={`Review Due Today · ${Math.max(0,action)} remaining`}
        backHref="/english/focus"
        load={load}
        module="reviewduetoday"
        emptyText="Today’s scheduled reviews are already covered."
        onExit={()=>{setRunning(null);void refresh();void refreshReview();}}
      />;
    }
    const config=lanes.find(x=>x.key===running)!;
    const lane=summary.lanes[config.summaryKey];
    return <QuizRunner
      title={`${config.title} · ${lane.completed}/${lane.target}`}
      backHref="/english/focus"
      load={load}
      module={config.module}
      fastTrackMode={config.fastTrack}
      emptyText="This Daily Focus lane is already complete or has no eligible questions."
      onExit={()=>{setRunning(null);void refresh();void refreshReview();}}
    />;
  }

  const total=summary?.total||170;
  const completed=summary?.completed||0;
  const percent=total?Math.min(100,Math.round((completed/total)*100)):0;
  const allDone=!!summary&&summary.status==="completed";
  const reviewActionable=reviewDue?.actionable??((reviewDue?.needsRepair||0)+(reviewDue?.lowConfidence||0)+(reviewDue?.remaining||0));
  const reviewCovered=reviewDue?.satisfied||0;
  const reviewDone=!!reviewDue?.snapshotReady&&reviewActionable===0;
  const reviewSubtitle=!reviewDue?.snapshotReady
    ?"Exact midnight snapshot is not ready yet"
    :reviewDone
      ?`All ${reviewDue.dueAtStart} scheduled reviews covered today`
      :`${reviewCovered} covered${reviewDue.satisfiedElsewhere?` · ${reviewDue.satisfiedElsewhere} elsewhere`:""} · ${reviewActionable} left · separate from 170`;

  return <section className="route-page">
    <div className="route-head">
      <Link className="btn ghost" href="/english">← Home</Link>
      <div><span className="eyebrow">Central Intelligence · mandatory routing</span><h1>Daily Focus</h1><p>One frozen 170-question mission plus today’s dynamic scheduled-review coverage obligation.</p></div>
    </div>

    {error&&<div className="error-box">{error}</div>}

    <section className="daily-active-card">
      <div className="daily-active-top">
        <div className="daily-active-copy"><span className="eyebrow">{summary?.carryover?"Carry-over batch":"Today’s Focus"}</span><h1>{allDone?"Daily Focus complete":"Mandatory focus work"}</h1><p>{summary?.carryover?`Finish ${summary.batchDate} before a fresh batch unlocks.`:"Repair, expose the canonical bank, then clear Fast Track. Review Due Today remains a separate dynamic coverage obligation."}</p></div>
        <div className="daily-active-side"><strong>{summary?`${completed} / ${total}`:"—"}</strong>{allDone&&<span className="today-badge">✓ Done</span>}</div>
      </div>
      <div className="progress-track daily-active-progress"><i style={{width:`${percent}%`}}/></div>
    </section>

    <section className="section-block">
      <div className="section-title-line"><h2>Today’s focus lanes</h2><span className="row-status">{summary?.batchDate||"Syncing"}</span></div>
      <div className="study-list">
        {lanes.map(config=>{
          const lane=summary?.lanes[config.summaryKey];
          const done=!!lane?.done;
          return <button type="button" className={`study-row home-quick-row ${config.accent}`} key={config.key} disabled={!summary||done||localSafe} onClick={()=>{if(!done)setRunning(config.key);}}>
            <span className="row-icon">{done?"✓":config.icon}</span>
            <span className="row-copy"><b>{config.title}</b><small>{done?"Completed — this batch will not restart":config.subtitle}</small></span>
            <span className="row-status">{lane?`${lane.completed} / ${lane.target}`:"…"}</span>
            <i>{done?"✓":"›"}</i>
          </button>;
        })}
        <button type="button" className="study-row home-quick-row accent-bank" disabled={!reviewDue?.snapshotReady||reviewDone||localSafe||reviewDue?.practiceEnabled===false} onClick={()=>{if(!reviewDone)setRunning("review_due");}}>
          <span className="row-icon">{reviewDone?"✓":"↻"}</span>
          <span className="row-copy"><b>Review Due Today</b><small>{reviewSubtitle}</small></span>
          <span className="row-status">{reviewDue?.snapshotReady?(reviewDone?"Done":`${reviewActionable} left`):"…"}</span>
          <i>{reviewDone?"✓":"›"}</i>
        </button>
      </div>
      {localSafe&&<p className="route-safe-note">Local Safe is active: Daily Focus and Review Due Today answer writes are disabled against production data.</p>}
    </section>

    <section className="route-start">
      <h2>Routing contract</h2>
      <p>Repair reuses Weak/PW, Starred Intelligence and My Saved Intelligence. Bank Coverage is Central Intelligence-owned: 20 questions come from unattempted siblings inside canonical concepts you have already seen, while 50 come from genuinely new canonical concepts with category-balanced routing. Fast-Track reuses the existing Fast Track route. Review Due Today is concept-deduped but scheduled by the original question/word clock; it does not count toward the 170 denominator. Any durable attempt made inside Review Due Today covers that concept’s obligation for today, whether the answer is correct or wrong; the answer quality still feeds Central Intelligence and the normal next-review scheduler. A wrong answer in another module does not cover Review Due Today while cross-credit is disabled. The same canonical concept cannot appear twice in one Daily Focus batch.</p>
    </section>
  </section>;
}

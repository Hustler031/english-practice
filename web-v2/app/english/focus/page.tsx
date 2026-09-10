"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, localProductionSafetyMode, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type LaneKey = "repair" | "coverage" | "fast_track";
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

type Question = { id:string; question:string; options:{key:string;text:string}[] };

const lanes:{key:LaneKey;summaryKey:keyof FocusSummary["lanes"];icon:string;title:string;subtitle:string;module:string;fastTrack:boolean;accent:string}[] = [
  { key:"repair", summaryKey:"repair", icon:"◎", title:"Repair Intelligence", subtitle:"Weak · Persistent Weak · Starred · My Saved", module:"dailyfocusrepair", fastTrack:false, accent:"accent-starred" },
  { key:"coverage", summaryKey:"coverage", icon:"▦", title:"Bank Coverage", subtitle:"20 previously seen · 30 new canonical concepts", module:"bankcoverage", fastTrack:false, accent:"accent-bank" },
  { key:"fast_track", summaryKey:"fastTrack", icon:"⚡", title:"Fast-Track Mastery", subtitle:"Existing Central Intelligence Fast Track queue", module:"fasttrack", fastTrack:true, accent:"accent-phrasal" },
];

export default function DailyFocusPage(){
  const ready=useAuthGuard();
  const[summary,setSummary]=useState<FocusSummary|null>(null);
  const[running,setRunning]=useState<LaneKey|null>(null);
  const[error,setError]=useState("");
  const localSafe=localProductionSafetyMode();

  const refresh=useCallback(async()=>{
    const data=await rpc<FocusSummary>("english_get_daily_focus_summary");
    setSummary(data);
    setError("");
    return data;
  },[]);

  useEffect(()=>{if(ready)void refresh().catch((e:any)=>setError(learnerErrorMessage(e,"Daily Focus is taking longer than usual. Please retry.")));},[ready,refresh]);

  const load=useCallback(async()=>{
    if(!running)return [];
    return rpc<Question[]>("english_get_daily_focus_lane",{p_lane:running});
  },[running]);

  if(!ready)return <EnglishLoading text="Checking session…"/>;

  if(running&&summary){
    const config=lanes.find(x=>x.key===running)!;
    const lane=summary.lanes[config.summaryKey];
    return <QuizRunner
      title={`${config.title} · ${lane.completed}/${lane.target}`}
      backHref="/english/focus"
      load={load}
      module={config.module}
      fastTrackMode={config.fastTrack}
      emptyText="This Daily Focus lane is already complete or has no eligible questions."
      onExit={()=>{setRunning(null);void refresh();}}
    />;
  }

  const total=summary?.total||150;
  const completed=summary?.completed||0;
  const percent=total?Math.min(100,Math.round((completed/total)*100)):0;
  const allDone=!!summary&&summary.status==="completed";

  return <section className="route-page">
    <div className="route-head">
      <Link className="btn ghost" href="/english">← Home</Link>
      <div><span className="eyebrow">Central Intelligence · mandatory routing</span><h1>Daily Focus</h1><p>One frozen mission. Finish the active batch before another Daily Focus batch can unlock.</p></div>
    </div>

    {error&&<div className="error-box">{error}</div>}

    <section className="daily-active-card">
      <div className="daily-active-top">
        <div className="daily-active-copy"><span className="eyebrow">{summary?.carryover?"Carry-over batch":"Today’s Focus"}</span><h1>{allDone?"Daily Focus complete":"Mandatory focus work"}</h1><p>{summary?.carryover?`Finish ${summary.batchDate} before a fresh batch unlocks.`:"Repair, expose the canonical bank, then clear Fast Track."}</p></div>
        <div className="daily-active-side"><strong>{summary?`${completed} / ${total}`:"—"}</strong>{allDone&&<span className="today-badge">✓ Done</span>}</div>
      </div>
      <div className="progress-track daily-active-progress"><i style={{width:`${percent}%`}}/></div>
    </section>

    <section className="section-block">
      <div className="section-title-line"><h2>Today’s mandatory lanes</h2><span className="row-status">{summary?.batchDate||"Syncing"}</span></div>
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
      </div>
      {localSafe&&<p className="route-safe-note">Local Safe is active: Daily Focus answer writes are disabled against production data.</p>}
    </section>

    <section className="route-start">
      <h2>Routing contract</h2>
      <p>Repair reuses Weak/PW, Starred Intelligence and My Saved Intelligence. Bank Coverage is Central Intelligence-owned and reserves 20 familiar incomplete concepts plus 30 genuinely new canonical concepts. Fast-Track reuses the existing Fast Track route. The same canonical concept cannot appear twice in one Daily Focus batch.</p>
    </section>
  </section>;
}

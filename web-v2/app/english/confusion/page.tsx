"use client";

import Link from "next/link";
import { useCallback,useEffect,useMemo,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Stats={published:number;completed:number;pending:number;mastered:number;focus:number;weak:number;difficult:number;new:number};
type History={day:number;date:string;label:string;published:number;completed:number;pending:number;mastered:number;focus:number;weak:number;difficult:number;new:number};
type Hub={currentDay:number;currentDate:string|null;stats:Stats;categoryCounts:Record<string,number>;history:History[]};
type Scope={fromDate?:string;toDate?:string};
type Pick={mode:string;label:string;count:number;scope:Scope};
type BrowseRow={id:string;word?:string;question?:string;category?:string;pairCluster?:string;batchDate?:string;dayNumber?:number;status?:string;mastered?:boolean};
type Group={key:string;label:string;rows:History[];fromDate:string;toDate:string;stats:Stats};

const CATEGORY_ORDER=["Confusable Words","Phrasal Verb Contrast","Look-alike / Spelling","Homophone / Homonym","Usage / Collocation"];

export default function DailyConfusionHub(){
 const ready=useAuthGuard();
 const[hub,setHub]=useState<Hub|null>(null);
 const[pick,setPick]=useState<Pick|null>(null);
 const[browse,setBrowse]=useState<{title:string;rows:BrowseRow[]}|null>(null);
 const[browseLoading,setBrowseLoading]=useState(false);
 const[openBlocks,setOpenBlocks]=useState<Set<string>>(new Set());
 const[error,setError]=useState("");

 const loadHub=useCallback(async()=>{
  try{setHub(await rpc<Hub>("english_get_confusion_hub"));setError("")}
  catch(e:any){setError(learnerErrorMessage(e,"Could not load Daily Confusion history."))}
 },[]);
 useEffect(()=>{if(ready)void loadHub()},[ready,loadHub]);

 const loadPick=useCallback(()=>{
  if(!pick)return Promise.resolve([]);
  return rpc<any[]>("english_get_confusion_revision_batch",{
   p_mode:pick.mode,p_count:pick.count,p_from_date:pick.scope.fromDate??null,p_to_date:pick.scope.toDate??null
  });
 },[pick]);
 const hierarchy=useMemo(()=>buildHierarchy(hub?.history||[],hub?.currentDay||0),[hub]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/confusion" load={loadPick} module="confusion" onFinish={loadHub} onExit={()=>{setPick(null);void loadHub()}}/>;

 const run=(scope:Scope,mode:string,count:number,label:string)=>setPick({mode,count,label,scope});
 const openBrowse=async(scope:Scope,label:string)=>{
  setBrowseLoading(true);setBrowse({title:label,rows:[]});setError("");
  try{const rows=await rpc<BrowseRow[]>("english_get_confusion_revision_batch",{p_mode:"all",p_count:500,p_from_date:scope.fromDate??null,p_to_date:scope.toDate??null});setBrowse({title:label,rows})}
  catch(e:any){setBrowse(null);setError(learnerErrorMessage(e,"Could not load Daily Confusion questions."))}
  finally{setBrowseLoading(false)}
 };
 const toggle=(key:string)=>setOpenBlocks(s=>{const n=new Set(s);n.has(key)?n.delete(key):n.add(key);return n});

 if(browse)return <section className="starred-parity-page">
  <div className="sr-browse-head"><button className="btn ghost" onClick={()=>setBrowse(null)}>← Daily Confusion</button><div><h1>{browse.title}</h1><p>{browseLoading?"Loading…":`${browse.rows.length} questions`}</p></div></div>
  <div className="sr-browse">{browse.rows.map((x,i)=><article className="sr-browse-item" key={`${x.id}-${x.batchDate}-${i}`}><b>{i+1}. {x.word||x.question||x.id}</b>{x.word&&x.question?<div>{x.question}</div>:null}<small>Day {x.dayNumber||"—"}{x.category?` · ${x.category}`:""}{x.pairCluster?` · ${x.pairCluster}`:""}</small></article>)}</div>
 </section>;

 const s=hub?.stats||emptyStats();
 const allScope:Scope={};
 const categoryCopy=CATEGORY_ORDER.map(name=>`${Number(hub?.categoryCounts?.[name]||0)} ${shortCategory(name)}`).join(" · ");
 return <section className="starred-parity-page">
  <div className="starred-subhead"><Link className="btn ghost starred-back" href="/english">← Back</Link><div><h1>⇄ Daily Confusion 15</h1><p>Focused revision of confusables, phrasal contrasts, look-alikes, homophones and usage traps.</p></div></div>
  {error&&<div className="error-box">{error}</div>}
  <section className="sr-summary">
   <h2>All Daily Confusion</h2>
   <StatsLine stats={s}/>
   {categoryCopy?<p className="muted" style={{margin:"7px 0 12px",fontSize:11,lineHeight:1.45}}>{categoryCopy}</p>:null}
   <Actions stats={s} scope={allScope} openBrowse={openBrowse} run={run}/>
   <button className="btn primary sr-smart-button" disabled={!s.focus} onClick={()=>run(allScope,"smart",20,"Daily Confusion · Smart Revision")}>🧠 Smart Revision</button>
  </section>

  <h2 className="sr-section-title">Day-wise Focus</h2>
  <div className="sr-groups">
   <DayGroups rows={hierarchy.current} openBlocks={openBlocks} toggle={toggle} openBrowse={openBrowse} run={run}/>
   {hierarchy.groups.map(g=>{const open=openBlocks.has(g.key),scope={fromDate:g.fromDate,toDate:g.toDate};return <section className="sr-group" key={g.key}><button className="sr-group-head" onClick={()=>toggle(g.key)}><div><b>{g.label}</b><StatsLine stats={g.stats}/></div><span className="sr-chevron">{open?"⌄":"›"}</span></button>{open?<div className="sr-group-panel"><Actions stats={g.stats} scope={scope} openBrowse={openBrowse} run={run}/><div className="sr-days"><DayGroups rows={g.rows} openBlocks={openBlocks} toggle={toggle} openBrowse={openBrowse} run={run}/></div></div>:null}</section>})}
  </div>
  {!hub?.history?.length&&!error?<div className="empty-state"><h3>No Daily Confusion history yet.</h3><p className="muted">Your scheduled 15-question sets will appear here day by day.</p></div>:null}
 </section>;
}

function StatsLine({stats}:{stats:Stats}){return <div className="sr-stats"><span><b>{stats.published}</b> Published</span><span><b>{stats.completed}</b> Completed</span><span><b>{stats.pending}</b> Pending</span></div>}

function Actions({stats,scope,openBrowse,run}:{stats:Stats;scope:Scope;openBrowse:(scope:Scope,label:string)=>void;run:(scope:Scope,mode:string,count:number,label:string)=>void}){
 const total=Math.max(1,stats.published);
 return <div className="sr-actions">
  <button className="btn soft mini" disabled={!stats.published} onClick={()=>void openBrowse(scope,"Daily Confusion Questions")}>View All</button>
  <button className="btn soft mini" disabled={!stats.published} onClick={()=>run(scope,"all",Math.min(50,total),"Daily Confusion · Practice All")}>Practice All</button>
  <button className="btn soft mini" disabled={!stats.new} onClick={()=>run(scope,"new",Math.min(30,Math.max(1,stats.new)),"Daily Confusion · Practice New")}>Practice New</button>
  <button className="btn soft mini" disabled={!stats.weak} onClick={()=>run(scope,"weak",Math.min(30,Math.max(1,stats.weak)),"Daily Confusion · Weak")}>Weak</button>
  <button className="btn soft mini" disabled={!stats.difficult} onClick={()=>run(scope,"difficult",Math.min(30,Math.max(1,stats.difficult)),"Daily Confusion · Difficult")}>Difficult</button>
  <button className="btn soft mini" disabled={!stats.mastered} onClick={()=>run(scope,"mastered",Math.min(30,Math.max(1,stats.mastered)),"Daily Confusion · Mastered")}>Mastered</button>
 </div>;
}

function DayGroups({rows,openBlocks,toggle,openBrowse,run}:{rows:History[];openBlocks:Set<string>;toggle:(key:string)=>void;openBrowse:(scope:Scope,label:string)=>void;run:(scope:Scope,mode:string,count:number,label:string)=>void}){
 return <>{rows.map(h=>{const key=`confusion-day-${h.day}`,open=openBlocks.has(key),scope={fromDate:h.date,toDate:h.date};return <section className="sr-group" key={key}><button className="sr-group-head" onClick={()=>toggle(key)}><div><b>Day {h.day}</b><StatsLine stats={historyStats(h)}/></div><span className="sr-chevron">{open?"⌄":"›"}</span></button>{open?<div className="sr-group-panel"><div className="muted" style={{fontSize:11,marginBottom:9}}>{formatDate(h.date)} · {h.mastered} Mastered · {h.weak} Weak · {h.difficult} Difficult</div><Actions stats={historyStats(h)} scope={scope} openBrowse={openBrowse} run={run}/></div>:null}</section>})}</>;
}

function historyStats(h:History):Stats{return {published:h.published,completed:h.completed,pending:h.pending,mastered:h.mastered,focus:h.focus,weak:h.weak,difficult:h.difficult,new:h.new}}
function emptyStats():Stats{return {published:0,completed:0,pending:0,mastered:0,focus:0,weak:0,difficult:0,new:0}}
function sumStats(rows:History[]):Stats{return rows.reduce((n,h)=>{n.published+=h.published;n.completed+=h.completed;n.pending+=h.pending;n.mastered+=h.mastered;n.focus+=h.focus;n.weak+=h.weak;n.difficult+=h.difficult;n.new+=h.new;return n},emptyStats())}
function buildHierarchy(history:History[],reportedCurrentDay:number){
 const sorted=[...history].sort((a,b)=>b.day-a.day);const currentDay=Math.max(1,Number(reportedCurrentDay||sorted[0]?.day||1));
 const currentMonth=Math.floor((currentDay-1)/30)+1,currentMonthStart=(currentMonth-1)*30+1,currentBlockStart=Math.floor((currentDay-1)/10)*10+1;
 const current=sorted.filter(h=>h.day>=currentBlockStart&&h.day<=currentDay);const groups:Group[]=[];
 for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=start+9,rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`confusion-block-${start}`,label:`Days ${start}–${end}`,rows,fromDate:rows[rows.length-1].date,toDate:rows[0].date,stats:sumStats(rows)})}
 for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30,rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`confusion-month-${month}`,label:`Month ${month} · Days ${start}–${end}`,rows,fromDate:rows[rows.length-1].date,toDate:rows[0].date,stats:sumStats(rows)})}
 return {current,groups};
}
function formatDate(value:string){const d=new Date(`${value}T00:00:00+05:30`);return Number.isNaN(d.getTime())?value:new Intl.DateTimeFormat("en-IN",{day:"numeric",month:"short",year:"numeric",timeZone:"Asia/Kolkata"}).format(d)}
function shortCategory(name:string){if(name==="Confusable Words")return"Confusable";if(name==="Phrasal Verb Contrast")return"Phrasal";if(name==="Look-alike / Spelling")return"Look-alike";if(name==="Homophone / Homonym")return"Homophone";return"Usage"}

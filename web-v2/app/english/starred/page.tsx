"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Stats={active:number;revised:number;neverRevised:number;revisedOnce:number;revisedMultiple:number;longOverdue:number;due:number;weak:number;persistentWeak:number;fragile:number;difficult:number;strong:number;learning:number;starred:number;mastered:number;focus:number;manualDifficult:number};
type History={day:number;label:string;count:number;starred:number;mastered:number;focus:number;difficult:number};
type Hub={currentDay?:number;stats:Stats;available:{smart:number;notRevised:number;due:number;weak:number;difficult:number;longest:number;all:number};sizes:number[];history:History[]};
type Scope={fromDay:number;toDay:number};
type Pick={mode:string;label:string;count:number;fromDay?:number;toDay?:number};
type Pending={mode:string;label:string;scope:Scope};
type HistoryGroup={key:string;label:string;rows:History[];fromDay:number;toDay:number;stats:ManualStats;type:"block"|"month"};
type ManualStats={starred:number;mastered:number;focus:number;difficult:number};
type BrowseRow={id?:string;question_id?:string;word?:string;question?:string;starredDay?:number;mastered?:boolean;status?:string;source?:string};
const smartModes=[["🧠","Smart Mix","smart"],["🆕","Not Revised","notRevised"],["⏰","Due Now","due"],["🔴","Weak Focus","weak"],["⚡","Difficult","difficult"],["🔄","Longest Not Revised","longest"]] as const;
const allScope:Scope={fromDay:1,toDay:999999};

export default function StarredPage(){
 const ready=useAuthGuard();
 const [hub,setHub]=useState<Hub|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pending,setPending]=useState<Pending|null>(null);
 const [error,setError]=useState("");
 const [smartSize,setSmartSize]=useState(20);
 const [smart,setSmart]=useState(false);
 const [openBlocks,setOpenBlocks]=useState<Set<string>>(new Set());
 const [browse,setBrowse]=useState<{title:string;rows:BrowseRow[]}|null>(null);
 const [browseLoading,setBrowseLoading]=useState(false);
 useEffect(()=>{if(ready)rpc<Hub>("english_get_starred_hub",{p_from_day:null,p_to_day:null}).then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>pick?rpc<any[]>("english_get_starred_batch",{p_mode:pick.mode,p_count:pick.count,p_from_day:pick.fromDay??null,p_to_day:pick.toDay??null}):Promise.resolve([]),[pick]);
 const hierarchy=useMemo(()=>buildHierarchy(hub?.history||[],hub?.currentDay),[hub]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/starred" load={load} module="starredRevision" onExit={()=>setPick(null)}/>;
 const s=hub?.stats,a=hub?.available,coverage=s?.active?Math.round(s.revised*1000/s.active)/10:0;
 const toggleBlock=(key:string)=>setOpenBlocks(x=>{const n=new Set(x);n.has(key)?n.delete(key):n.add(key);return n;});
 const runManual=(scope:Scope,mode:string,count:number,label:string)=>setPick({mode,label,count,fromDay:scope.fromDay,toDay:scope.toDay});
 const openBrowse=async(scope:Scope,mode:"all"|"mastered",label:string)=>{setBrowseLoading(true);setBrowse({title:label,rows:[]});try{const rows=await rpc<BrowseRow[]>("english_get_starred_manual_items",{p_mode:mode,p_from_day:scope.fromDay,p_to_day:scope.toDay});setBrowse({title:label,rows});}catch(e:any){setError(e.message||String(e));setBrowse(null);}finally{setBrowseLoading(false)}};
 if(browse)return <section className="starred-parity-page"><div className="sr-browse-head"><button className="btn ghost" onClick={()=>setBrowse(null)}>← Starred Revision</button><div><h1>{browse.title}</h1><p>{browseLoading?"Loading…":`${browse.rows.length} questions`}</p></div></div><div className="sr-browse">{browse.rows.map((x,i)=><article className="sr-browse-item" key={`${x.question_id||x.id||i}-${i}`}><b>{i+1}. {x.word||x.question||x.question_id||x.id}</b>{x.word&&x.question?<div>{x.question}</div>:null}<small>Day {x.starredDay||"—"}{x.mastered?" · Mastered":" · Focus"}{x.status?` · ${x.status}`:""}</small></article>)}</div></section>;
 return <section className="starred-parity-page">
  {!smart?<>
   <div className="starred-subhead"><Link className="btn ghost starred-back" href="/english/revision">← Back</Link><div><h1>⭐ Starred Revision</h1><p>Focused revision of questions you starred across every quiz.</p></div></div>
   {error&&<div className="error-box">{error}</div>}
   <section className="sr-summary"><h2>All Starred Revision</h2><StatsLine stats={{starred:s?.starred??s?.active??0,mastered:s?.mastered??0,focus:s?.focus??s?.active??0,difficult:s?.manualDifficult??s?.difficult??0}}/><ManualActions stats={{starred:s?.starred??s?.active??0,mastered:s?.mastered??0,focus:s?.focus??s?.active??0,difficult:s?.manualDifficult??s?.difficult??0}} scope={allScope} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><button className="btn primary sr-smart-button" onClick={()=>setSmart(true)}>🧠 Smart Revision</button></section>
   <h2 className="sr-section-title">Day-wise Focus</h2>
   <div className="sr-groups"><DayGroups rows={hierarchy.current} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><HistoryGroups groups={hierarchy.groups} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div>
  </>:<>
   <div className="starred-subhead"><button className="btn ghost starred-back" onClick={()=>setSmart(false)}>← Starred</button><div><h1>🧠 Starred Intelligence</h1><p>Adaptive selection while preserving your manual Star intent.</p></div></div>
   <section className="revision-panel"><div className="revision-panel-head"><div><h2>Recommended Now</h2><p>Learning priority + coverage rotation.</p></div></div><div className="revision-metrics"><span><b>{s?.neverRevised??"—"}</b>Never Revised</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.weak??"—"}</b>Weak</span><span><b>{s?.difficult??"—"}</b>Difficult</span></div><div className="sr-smart-sizes">{[10,20,30,50].map(n=><button className={`btn ghost ${smartSize===n?"warn":""}`} key={n} onClick={()=>setSmartSize(n)}>{n}</button>)}</div></section>
   <section className="section-block starred-intelligence-folds">
    <details className="intel-fold" open><summary><span>Starred Coverage</span><b>{s?`${s.revised} / ${s.active}`:"—"}</b></summary><div className="intel-fold-body"><div className="progress-track green"><i style={{width:`${coverage}%`}}/></div><p>{coverage.toFixed(1)}% revised · {s?.revisedOnce??0} once · {s?.revisedMultiple??0} multiple</p></div></details>
    <details className="intel-fold"><summary><span>Learning Health</span><b>{s?.persistentWeak??0} persistent weak</b></summary><div className="intel-grid"><span><b>{s?.persistentWeak??"—"}</b>Persistent Weak</span><span><b>{s?.weak??"—"}</b>Weak total</span><span><b>{s?.fragile??"—"}</b>Fragile</span><span><b>{s?.due??"—"}</b>Due</span><span><b>{s?.difficult??"—"}</b>Difficult</span><span><b>{s?.strong??"—"}</b>Strong</span><span><b>{s?.learning??"—"}</b>Learning / New</span></div></details>
    <details className="intel-fold" open><summary><span>Smart Practice</span><b>{smartSize} questions</b></summary><div className="intel-fold-body"><div className="action-matrix">{smartModes.map(([icon,label,mode])=><button key={mode} className="feature-card" disabled={!a||Number(a[mode as keyof typeof a]||0)===0} onClick={()=>setPick({mode:mode.toLowerCase(),label:`Starred · ${label}`,count:smartSize})}><b>{icon}</b><span>{label}</span></button>)}</div></div></details>
    <details className="intel-fold"><summary><span>Rotation Health</span><b>{s?.neverRevised??0} not revised</b></summary><div className="intel-grid"><span><b>{s?.neverRevised??"—"}</b>Never Revised</span><span><b>{s?.revisedOnce??"—"}</b>Revised Once</span><span><b>{s?.revisedMultiple??"—"}</b>Revised Multiple</span><span><b>{s?.longOverdue??"—"}</b>Long Overdue</span></div></details>
    <details className="intel-fold"><summary><span>Day-wise Intelligence</span><b>Day {hub?.currentDay??"—"}</b></summary><div className="intel-fold-body"><div className="sr-groups"><DayGroups rows={hierarchy.current} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><HistoryGroups groups={hierarchy.groups} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div></div></details>
   </section>
  </>}
  {pending?<div className="sheet-backdrop" onClick={()=>setPending(null)}><div className="sheet" onClick={e=>e.stopPropagation()}><h3>{pending.label}</h3><div className="count-buttons">{[10,20,50,100].map(n=><button key={n} onClick={()=>{const p=pending;setPending(null);runManual(p.scope,p.mode,n,`Starred Revision · ${p.label}`)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPending(null)}>Cancel</button></div></div>:null}
 </section>;
}

function manualStats(h:History):ManualStats{return {starred:Number(h.starred??h.count??0),mastered:Number(h.mastered??0),focus:Number(h.focus??h.count??0),difficult:Number(h.difficult??0)}}
function StatsLine({stats}:{stats:ManualStats}){return <div className="sr-stats"><span><b>{stats.starred}</b> Starred</span><span><b>{stats.mastered}</b> Mastered</span><span><b>{stats.focus}</b> Focus</span></div>}
function ManualActions({scope,stats,openBrowse,runManual,setPending}:{scope:Scope;stats:ManualStats;openBrowse:(scope:Scope,mode:"all"|"mastered",label:string)=>void;runManual:(scope:Scope,mode:string,count:number,label:string)=>void;setPending:(p:Pending)=>void}){return <div className="sr-actions"><button className="btn soft mini" disabled={!stats.starred} onClick={()=>openBrowse(scope,"all","Starred Questions")}>View All</button><button className="btn soft mini" disabled={!stats.focus} onClick={()=>runManual(scope,"all",50,"Starred Revision")}>Practice All</button><button className="btn soft mini" disabled={!stats.focus} onClick={()=>setPending({scope,mode:"notrevised",label:"Practice New Starred"})}>Practice New</button><button className="btn soft mini" disabled={!stats.focus} onClick={()=>setPending({scope,mode:"weak",label:"Weak Starred"})}>Weak</button><button className="btn soft mini" disabled={!stats.difficult} onClick={()=>runManual(scope,"difficult",50,"Starred Revision · Difficult")}>Difficult</button><button className="btn soft mini" disabled={!stats.mastered} onClick={()=>openBrowse(scope,"mastered","Mastered from Starred")}>Mastered</button></div>}
function DayGroups({rows,openBlocks,toggleBlock,openBrowse,runManual,setPending}:{rows:History[];openBlocks:Set<string>;toggleBlock:(key:string)=>void;openBrowse:(scope:Scope,mode:"all"|"mastered",label:string)=>void;runManual:(scope:Scope,mode:string,count:number,label:string)=>void;setPending:(p:Pending)=>void}){return <>{rows.map(h=>{const key=`day-${h.day}`,open=openBlocks.has(key),scope={fromDay:h.day,toDay:h.day},stats=manualStats(h);return <section className="sr-group" key={key}><button className="sr-group-head" onClick={()=>toggleBlock(key)}><div><b>{h.label}</b><StatsLine stats={stats}/></div><span className="sr-chevron">{open?"⌄":"›"}</span></button>{open?<div className="sr-group-panel"><ManualActions scope={scope} stats={stats} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div>:null}</section>})}</>}
function HistoryGroups({groups,openBlocks,toggleBlock,openBrowse,runManual,setPending}:{groups:HistoryGroup[];openBlocks:Set<string>;toggleBlock:(key:string)=>void;openBrowse:(scope:Scope,mode:"all"|"mastered",label:string)=>void;runManual:(scope:Scope,mode:string,count:number,label:string)=>void;setPending:(p:Pending)=>void}){return <>{groups.map(g=>{const open=openBlocks.has(g.key),scope={fromDay:g.fromDay,toDay:g.toDay};return <section className="sr-group" key={g.key}><button className="sr-group-head" onClick={()=>toggleBlock(g.key)}><div><b>{g.label}</b><StatsLine stats={g.stats}/></div><span className="sr-chevron">{open?"⌄":"›"}</span></button>{open?<div className="sr-group-panel"><ManualActions scope={scope} stats={g.stats} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><div className="sr-days"><DayGroups rows={g.rows} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div></div>:null}</section>})}</>}
function sumStats(rows:History[]):ManualStats{return rows.reduce((n,h)=>{const s=manualStats(h);n.starred+=s.starred;n.mastered+=s.mastered;n.focus+=s.focus;n.difficult+=s.difficult;return n},{starred:0,mastered:0,focus:0,difficult:0})}
function buildHierarchy(history:History[],reportedCurrentDay?:number){
 const sorted=[...history].sort((a,b)=>b.day-a.day);const maxDay=sorted[0]?.day||1;const currentDay=Math.max(1,Number(reportedCurrentDay||maxDay));const currentMonth=Math.floor((currentDay-1)/30)+1;const currentMonthStart=(currentMonth-1)*30+1;const currentBlockStart=Math.floor((currentDay-1)/10)*10+1;
 const current=sorted.filter(h=>h.day>=currentBlockStart&&h.day<=currentDay);const groups:HistoryGroup[]=[];
 for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=start+9;const rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`block-${start}`,label:`Days ${start}–${end}`,rows,fromDay:start,toDay:end,stats:sumStats(rows),type:"block"});}
 for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30;const rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`month-${month}`,label:`Month ${month} · Days ${start}–${end}`,rows,fromDay:start,toDay:end,stats:sumStats(rows),type:"month"});}
 return {currentDay,current,groups};
}

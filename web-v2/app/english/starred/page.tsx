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
type ScopeOption={key:string;label:string;all:boolean;fromDay?:number;toDay?:number};
type Pick={mode:string;label:string;count:number;fromDay?:number;toDay?:number};
type Pending={mode:string;label:string;scope:Scope};
type HistoryGroup={key:string;label:string;rows:History[];fromDay:number;toDay:number;stats:ManualStats;type:"block"|"month"};
type ManualStats={starred:number;mastered:number;focus:number;difficult:number};
type BrowseRow={id?:string;question_id?:string;word?:string;question?:string;starredDay?:number;mastered?:boolean;status?:string;source?:string};
type RotationStats={weakExact:number;learningExact:number;newCount:number;dueWeak:number;days7Plus:number;days14Plus:number;recent24h:number};
type Guidance={rotationPriority:string;focus:string;recommendation:string;dueWeak:number;due:number;neverRevised:number;days7Plus:number;days14Plus:number};
type SmartComposition={total:number;persistentWeak:number;weakFragile:number;due:number;difficult:number;learning:number;coverageRotation:number};
type SmartPlan={count:number;composition:SmartComposition};
const smartModes=[
 ["🧠","Smart Mix","Learning priority + coverage rotation","smart"],
 ["🆕","Not Revised","Zero genuine Starred Revision attempts","notRevised"],
 ["⏰","Due Now","Central spaced-review clock is due","due"],
 ["🔴","Weak Focus","Persistent Weak → Weak → Fragile","weak"],
 ["⚡","Difficult","Manual Central Difficult only","difficult"],
 ["🔄","Longest Not Revised","Never revised first, then oldest Starred attempt","longest"],
] as const;
const allScope:Scope={fromDay:1,toDay:999999};

export default function StarredPage(){
 const ready=useAuthGuard();
 const [hub,setHub]=useState<Hub|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pending,setPending]=useState<Pending|null>(null);
 const [error,setError]=useState("");
 const [smartSize,setSmartSize]=useState(20);
 const [smart,setSmart]=useState(false);
 const [smartScopeKey,setSmartScopeKey]=useState("all");
 const [smartHub,setSmartHub]=useState<Hub|null>(null);
 const [rotation,setRotation]=useState<RotationStats|null>(null);
 const [guidance,setGuidance]=useState<Guidance|null>(null);
 const [smartPlan,setSmartPlan]=useState<SmartPlan|null>(null);
 const [smartLoading,setSmartLoading]=useState(false);
 const [smartInfo,setSmartInfo]=useState<string|null>(null);
 const [openBlocks,setOpenBlocks]=useState<Set<string>>(new Set());
 const [browse,setBrowse]=useState<{title:string;rows:BrowseRow[]}|null>(null);
 const [browseLoading,setBrowseLoading]=useState(false);

 useEffect(()=>{if(ready)rpc<Hub>("english_get_starred_hub",{p_from_day:null,p_to_day:null}).then(setHub).catch((e:any)=>setError(e.message));},[ready]);
 const scopeOptions=useMemo(()=>buildScopeOptions(hub?.history||[],hub?.currentDay),[hub]);
 const smartScope=scopeOptions.find(x=>x.key===smartScopeKey)||scopeOptions[0]||{key:"all",label:"All Starred",all:true};
 const scopeArgs=useMemo(()=>smartScope.all?{p_from_day:null,p_to_day:null}:{p_from_day:smartScope.fromDay??null,p_to_day:smartScope.toDay??null},[smartScope]);

 useEffect(()=>{
  if(!ready||!smart)return;
  let alive=true;setSmartLoading(true);setSmartPlan(null);
  Promise.all([
   rpc<Hub>("english_get_starred_hub",scopeArgs),
   rpc<RotationStats>("english_get_starred_rotation_stats",scopeArgs),
   rpc<Guidance>("english_get_starred_guidance",scopeArgs),
  ]).then(([h,r,g])=>{if(alive){setSmartHub(h);setRotation(r);setGuidance(g)}}).catch((e:any)=>{if(alive)setError(e.message||String(e))}).finally(()=>{if(alive)setSmartLoading(false)});
  return()=>{alive=false};
 },[ready,smart,scopeArgs]);

 useEffect(()=>{
  if(!ready||!smart)return;
  let alive=true;setSmartPlan(null);
  rpc<any[]>("english_get_starred_batch",{p_mode:"smart",p_count:smartSize,...scopeArgs}).then(rows=>{if(alive)setSmartPlan(planFromRows(rows))}).catch((e:any)=>{if(alive)setError(e.message||String(e))});
  return()=>{alive=false};
 },[ready,smart,smartSize,scopeArgs]);

 const load=useCallback(()=>pick?rpc<any[]>("english_get_starred_batch",{p_mode:pick.mode,p_count:pick.count,p_from_day:pick.fromDay??null,p_to_day:pick.toDay??null}):Promise.resolve([]),[pick]);
 const hierarchy=useMemo(()=>buildHierarchy(hub?.history||[],hub?.currentDay),[hub]);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/starred" load={load} module="starredRevision" onExit={()=>setPick(null)}/>;
 const s=hub?.stats;
 const toggleBlock=(key:string)=>setOpenBlocks(x=>{const n=new Set(x);n.has(key)?n.delete(key):n.add(key);return n;});
 const runManual=(scope:Scope,mode:string,count:number,label:string)=>setPick({mode,label,count,fromDay:scope.fromDay,toDay:scope.toDay});
 const openBrowse=async(scope:Scope,mode:"all"|"mastered",label:string)=>{setBrowseLoading(true);setBrowse({title:label,rows:[]});try{const rows=await rpc<BrowseRow[]>("english_get_starred_manual_items",{p_mode:mode,p_from_day:scope.fromDay,p_to_day:scope.toDay});setBrowse({title:label,rows});}catch(e:any){setError(e.message||String(e));setBrowse(null);}finally{setBrowseLoading(false)}};
 if(browse)return <section className="starred-parity-page"><div className="sr-browse-head"><button className="btn ghost" onClick={()=>setBrowse(null)}>← Starred Revision</button><div><h1>{browse.title}</h1><p>{browseLoading?"Loading…":`${browse.rows.length} questions`}</p></div></div><div className="sr-browse">{browse.rows.map((x,i)=><article className="sr-browse-item" key={`${x.question_id||x.id||i}-${i}`}><b>{i+1}. {x.word||x.question||x.question_id||x.id}</b>{x.word&&x.question?<div>{x.question}</div>:null}<small>Day {x.starredDay||"—"}{x.mastered?" · Mastered":" · Focus"}{x.status?` · ${x.status}`:""}</small></article>)}</div></section>;

 const ss=smartHub?.stats||hub?.stats;
 const sa=smartHub?.available||hub?.available;
 const sizeChoices=smartHub?.sizes?.length?smartHub.sizes:hub?.sizes?.length?hub.sizes:[10,20,30,50];
 const active=Number(ss?.active||0),revised=Number(ss?.revised||0),coverage=active?Math.round(revised*1000/active)/10:0;
 const weakExact=rotation?.weakExact??Math.max(0,Number(ss?.weak||0)-Number(ss?.persistentWeak||0)-Number(ss?.fragile||0));
 const learningExact=rotation?.learningExact??Number(ss?.learning||0),newCount=rotation?.newCount??0,dueWeak=rotation?.dueWeak??0;
 const fallbackPriority=getRotationPriority(active,Number(ss?.neverRevised||0),Number(rotation?.days14Plus??ss?.longOverdue??0),Number(rotation?.days7Plus||0));
 const rotationPriority=guidance?.rotationPriority||fallbackPriority;
 const focus=guidance?.focus||getFocus(dueWeak,Number(ss?.due||0),rotationPriority);
 const recommendation=guidance?.recommendation||getRecommendation(dueWeak,Number(ss?.due||0),Number(ss?.neverRevised||0),rotationPriority);
 const startSmart=(mode:string,label:string)=>setPick({mode:mode.toLowerCase(),label:`Starred · ${label}`,count:smartSize,fromDay:smartScope.all?undefined:smartScope.fromDay,toDay:smartScope.all?undefined:smartScope.toDay});

 return <section className="starred-parity-page">
  {!smart?<>
   <div className="starred-subhead"><Link className="btn ghost starred-back" href="/english/revision">← Back</Link><div><h1>⭐ Starred Revision</h1><p>Focused revision of questions you starred across every quiz.</p></div></div>
   {error&&<div className="error-box">{error}</div>}
   <section className="sr-summary"><h2>All Starred Revision</h2><StatsLine stats={{starred:s?.starred??s?.active??0,mastered:s?.mastered??0,focus:s?.focus??s?.active??0,difficult:s?.manualDifficult??s?.difficult??0}}/><ManualActions stats={{starred:s?.starred??s?.active??0,mastered:s?.mastered??0,focus:s?.focus??s?.active??0,difficult:s?.manualDifficult??s?.difficult??0}} scope={allScope} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><button className="btn primary sr-smart-button" onClick={()=>{setSmartScopeKey("all");setSmart(true)}}>🧠 Smart Revision</button></section>
   <h2 className="sr-section-title">Day-wise Focus</h2>
   <div className="sr-groups"><DayGroups rows={hierarchy.current} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><HistoryGroups groups={hierarchy.groups} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div>
  </>:<>
   <div className="starred-subhead"><button className="btn ghost starred-back" onClick={()=>setSmart(false)}>← Starred</button><div><h1>🧠 Starred Intelligence</h1><p>Adaptive revision inside your current Central Starred bank only.</p></div></div>
   {error&&<div className="error-box">{error}</div>}
   <section className="si-recommended">
    <div className="si-title-row"><div><h2>Recommended Now — {smartPlan?.count??0}</h2><p><b>Focus:</b> {focus}</p></div><span className="tag">{smartScope.label}</span><InfoButton label="Why this Smart set?" onClick={()=>setSmartInfo("recommended")}/></div>
    <div className="si-counts">{smartPlan?<CompositionChips c={smartPlan.composition}/>:<span className="si-chip">Preparing recommendation…</span>}</div>
    <div className="si-size-row">{sizeChoices.map(n=><button key={n} className={`btn ghost mini ${smartSize===n?"active":""}`} onClick={()=>setSmartSize(n)}>{n}</button>)}</div>
    <button className="btn primary full-width" disabled={!smartPlan?.count||smartLoading} onClick={()=>startSmart("smart","Recommended")}>Start Recommended {smartPlan?.count??0}</button>
   </section>

   <section className="si-folds">
    <details className="si-fold"><summary><div><b>Starred Coverage ›</b><span>{revised} / {active} · {coverage.toFixed(1)}%</span></div><InfoButton label="About Starred Coverage" onClick={()=>setSmartInfo("coverage")}/><i>›</i></summary><div className="si-fold-body"><div className="si-meter"><i style={{width:`${coverage}%`}}/></div><div className="si-grid"><Mini n={active} label="Active Starred"/><Mini n={revised} label="Revised"/><Mini n={Number(ss?.neverRevised||0)} label="Never Revised"/><Mini n={Number(ss?.revisedOnce||0)} label="Revised Once"/><Mini n={Number(ss?.revisedMultiple||0)} label="Revised Multiple"/><Mini n={Number(ss?.longOverdue||0)} label="Long Overdue"/></div></div></details>

    <details className="si-fold"><summary><div><b>Learning Health ›</b><span>{Number(ss?.persistentWeak||0)} PW · {weakExact} Weak · {Number(ss?.fragile||0)} Fragile · {Number(ss?.due||0)} Due</span></div><InfoButton label="About Learning Health" onClick={()=>setSmartInfo("health")}/><i>›</i></summary><div className="si-fold-body"><div className="si-grid"><Mini n={Number(ss?.persistentWeak||0)} label="🔴 Persistent Weak"/><Mini n={weakExact} label="🟠 Weak"/><Mini n={Number(ss?.fragile||0)} label="🟡 Fragile"/><Mini n={Number(ss?.due||0)} label="⏰ Due"/><Mini n={Number(ss?.difficult||0)} label="⚡ Difficult"/><Mini n={Number(ss?.strong||0)} label="🟢 Strong"/><Mini n={learningExact+newCount} label="Learning / New"/></div></div></details>

    <details className="si-fold"><summary><div><b>Smart Practice ›</b><span>6 intelligent modes</span></div><InfoButton label="About Smart Practice modes" onClick={()=>setSmartInfo("practice")}/><i>›</i></summary><div className="si-fold-body">{smartModes.map(([icon,label,desc,mode])=>{const available=Number(sa?.[mode as keyof typeof sa]||0);return <div className="si-mode" key={mode}><div><b>{icon} {label}</b><span>{desc} · {available} eligible</span></div><button className="btn soft mini" disabled={!available} onClick={()=>startSmart(mode,label)}>Start {available?Math.min(smartSize,available):""}</button></div>})}</div></details>

    <details className="si-fold"><summary><div><b>Rotation Health ›</b><span>{Number(ss?.neverRevised||0)} Never Revised · Priority {rotationPriority}</span></div><InfoButton label="About rotation and cooldown" onClick={()=>setSmartInfo("rotation")}/><i>›</i></summary><div className="si-fold-body"><div className="si-grid"><Mini n={Number(ss?.neverRevised||0)} label="Never Revised"/><Mini n={Number(rotation?.days7Plus||0)} label="Not revised 7+ days"/><Mini n={Number(rotation?.days14Plus??ss?.longOverdue??0)} label="Not revised 14+ days"/><Mini n={Number(rotation?.recent24h||0)} label="Recent 24h Smart cooldown"/></div></div></details>

    <details className="si-fold"><summary><div><b>Day-wise Intelligence ›</b><span>{smartScope.label}</span></div><InfoButton label="About Starred scope filtering" onClick={()=>setSmartInfo("scope")}/><i>›</i></summary><div className="si-fold-body si-scope"><select value={smartScopeKey} onChange={e=>setSmartScopeKey(e.target.value)}>{scopeOptions.map(x=><option key={x.key} value={x.key}>{x.label}</option>)}</select></div></details>
   </section>
  </>}

  {pending?<div className="sheet-backdrop" onClick={()=>setPending(null)}><div className="sheet" onClick={e=>e.stopPropagation()}><h3>{pending.label}</h3><div className="count-buttons">{Array.from(new Set([...sizeChoices,100])).map(n=><button key={n} onClick={()=>{const p=pending;setPending(null);runManual(p.scope,p.mode,n,`Starred Revision · ${p.label}`)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPending(null)}>Cancel</button></div></div>:null}
  {smartInfo?<div className="sheet-backdrop" onClick={()=>setSmartInfo(null)}><div className="sheet" onClick={e=>e.stopPropagation()}><div className="row between"><h3 style={{margin:0}}>{infoCopy(smartInfo,recommendation).title}</h3><button className="btn ghost mini" onClick={()=>setSmartInfo(null)}>Close</button></div><p className="si-info-copy">{infoCopy(smartInfo,recommendation).body}</p></div></div>:null}
 </section>;
}

function InfoButton({label,onClick}:{label:string;onClick:()=>void}){return <button className="btn ghost mini si-info-btn" aria-label={label} onClick={e=>{e.preventDefault();e.stopPropagation();onClick()}}>ⓘ</button>}
function Mini({n,label}:{n:number;label:string}){return <div className="si-mini"><b>{n}</b><small>{label}</small></div>}
function planFromRows(rows:any[]):SmartPlan{const c:SmartComposition={total:rows.length,persistentWeak:0,weakFragile:0,due:0,difficult:0,learning:0,coverageRotation:0};for(const q of rows){const r=String(q?.starredSelectionReason||"Coverage Rotation");if(r==="Persistent Weak")c.persistentWeak++;else if(r==="Weak"||r==="Fragile")c.weakFragile++;else if(r==="Due Recall"||r==="Difficult + Due")c.due++;else if(r==="Difficult")c.difficult++;else if(r==="Learning")c.learning++;else c.coverageRotation++}return {count:rows.length,composition:c}}
function CompositionChips({c}:{c:SmartComposition}){const items:[[string,number],[string,number],[string,number],[string,number],[string,number],[string,number]]=[["Persistent Weak",c.persistentWeak],["Weak / Fragile",c.weakFragile],["Due",c.due],["Difficult",c.difficult],["Learning",c.learning],["Rotation",c.coverageRotation]];const visible=items.filter(x=>x[1]>0);return <>{visible.length?visible.map(([label,n])=><span className="si-chip" key={label}>{n} {label}</span>):<span className="si-chip">No eligible questions</span>}</>}
function getRotationPriority(active:number,never:number,days14:number,days7:number){if(never>=Math.max(5,Math.ceil(active*.25))||days14>=Math.max(5,Math.ceil(active*.2)))return "High";if(never||days7)return "Moderate";return "Healthy"}
function getFocus(dueWeak:number,due:number,priority:string){if(dueWeak>=8)return "Due weak recall";if(due>=8)return "Overdue retention";if(priority==="High")return "Coverage rotation";return "Balanced retention + rotation"}
function getRecommendation(dueWeak:number,due:number,never:number,priority:string){if(dueWeak>=8)return `Smart Mix prioritises due Weak / Fragile recall${never?` while protecting first exposure for ${never} Never Revised Starred questions`:""}.`;if(due>=8)return `The current Smart set emphasises spaced retention${never?` while rotating through ${never} Never Revised Starred questions`:""}.`;if(priority==="High")return "The rotation backlog is currently the stronger need, so coverage rotation receives priority.";if(never>0)return `${never} current Starred questions have never been revised through Starred Revision; Smart Mix protects that coverage.`;return "Most active Starred questions already have Starred Revision exposure, so Smart Mix balances due retention with longest-not-revised rotation."}
function infoCopy(kind:string,recommendation:string){const map:Record<string,{title:string;body:string}>={recommended:{title:"Recommended Now",body:recommendation},coverage:{title:"Starred Coverage",body:"Coverage counts only questions that are still actively Starred. A question becomes Revised only after a genuine Starred Revision attempt; ordinary Daily or topic attempts do not count."},health:{title:"Learning Health",body:"Persistent Weak, Weak, Fragile, Strong and Learning/New come from the central durable learning state. Due uses the central spaced-review clock. Difficult is the manual central Difficult flag."},practice:{title:"Smart Practice",body:"Smart Mix balances learning priority with coverage rotation. Not Revised uses zero Starred Revision attempts. Due Now follows the central due clock. Weak Focus uses Persistent Weak → Weak → Fragile. Difficult uses the manual Difficult flag. Longest Not Revised prefers never-revised and then oldest Starred Revision exposure."},rotation:{title:"Rotation Health",body:"Rotation protects Starred questions from being forgotten or repeatedly skipped. Never Revised, 7+ days, 14+ days and the recent 24-hour cooldown are tracked separately."},scope:{title:"Day-wise Intelligence",body:"Changing scope recalculates the same intelligence only inside the selected Starred day or historical block. Manual Star intent remains authoritative."}};return map[kind]||map.recommended}
function manualStats(h:History):ManualStats{return {starred:Number(h.starred??h.count??0),mastered:Number(h.mastered??0),focus:Number(h.focus??h.count??0),difficult:Number(h.difficult??0)}}
function StatsLine({stats}:{stats:ManualStats}){return <div className="sr-stats"><span><b>{stats.starred}</b> Starred</span><span><b>{stats.mastered}</b> Mastered</span><span><b>{stats.focus}</b> Focus</span></div>}
function ManualActions({scope,stats,openBrowse,runManual,setPending}:{scope:Scope;stats:ManualStats;openBrowse:(scope:Scope,mode:"all"|"mastered",label:string)=>void;runManual:(scope:Scope,mode:string,count:number,label:string)=>void;setPending:(p:Pending)=>void}){return <div className="sr-actions"><button className="btn soft mini" disabled={!stats.starred} onClick={()=>openBrowse(scope,"all","Starred Questions")}>View All</button><button className="btn soft mini" disabled={!stats.focus} onClick={()=>runManual(scope,"all",50,"Starred Revision")}>Practice All</button><button className="btn soft mini" disabled={!stats.focus} onClick={()=>setPending({scope,mode:"notrevised",label:"Practice New Starred"})}>Practice New</button><button className="btn soft mini" disabled={!stats.focus} onClick={()=>setPending({scope,mode:"weak",label:"Weak Starred"})}>Weak</button><button className="btn soft mini" disabled={!stats.difficult} onClick={()=>runManual(scope,"difficult",50,"Starred Revision · Difficult")}>Difficult</button><button className="btn soft mini" disabled={!stats.mastered} onClick={()=>openBrowse(scope,"mastered","Mastered from Starred")}>Mastered</button></div>}
function DayGroups({rows,openBlocks,toggleBlock,openBrowse,runManual,setPending}:{rows:History[];openBlocks:Set<string>;toggleBlock:(key:string)=>void;openBrowse:(scope:Scope,mode:"all"|"mastered",label:string)=>void;runManual:(scope:Scope,mode:string,count:number,label:string)=>void;setPending:(p:Pending)=>void}){return <>{rows.map(h=>{const key=`day-${h.day}`,open=openBlocks.has(key),scope={fromDay:h.day,toDay:h.day},stats=manualStats(h);return <section className="sr-group" key={key}><button className="sr-group-head" onClick={()=>toggleBlock(key)}><div><b>{h.label}</b><StatsLine stats={stats}/></div><span className="sr-chevron">{open?"⌄":"›"}</span></button>{open?<div className="sr-group-panel"><ManualActions scope={scope} stats={stats} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div>:null}</section>})}</>}
function HistoryGroups({groups,openBlocks,toggleBlock,openBrowse,runManual,setPending}:{groups:HistoryGroup[];openBlocks:Set<string>;toggleBlock:(key:string)=>void;openBrowse:(scope:Scope,mode:"all"|"mastered",label:string)=>void;runManual:(scope:Scope,mode:string,count:number,label:string)=>void;setPending:(p:Pending)=>void}){return <>{groups.map(g=>{const open=openBlocks.has(g.key),scope={fromDay:g.fromDay,toDay:g.toDay};return <section className="sr-group" key={g.key}><button className="sr-group-head" onClick={()=>toggleBlock(g.key)}><div><b>{g.label}</b><StatsLine stats={g.stats}/></div><span className="sr-chevron">{open?"⌄":"›"}</span></button>{open?<div className="sr-group-panel"><ManualActions scope={scope} stats={g.stats} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/><div className="sr-days"><DayGroups rows={g.rows} openBlocks={openBlocks} toggleBlock={toggleBlock} openBrowse={openBrowse} runManual={runManual} setPending={setPending}/></div></div>:null}</section>})}</>}
function sumStats(rows:History[]):ManualStats{return rows.reduce((n,h)=>{const s=manualStats(h);n.starred+=s.starred;n.mastered+=s.mastered;n.focus+=s.focus;n.difficult+=s.difficult;return n},{starred:0,mastered:0,focus:0,difficult:0})}
function buildHierarchy(history:History[],reportedCurrentDay?:number){const sorted=[...history].sort((a,b)=>b.day-a.day);const maxDay=sorted[0]?.day||1;const currentDay=Math.max(1,Number(reportedCurrentDay||maxDay));const currentMonth=Math.floor((currentDay-1)/30)+1;const currentMonthStart=(currentMonth-1)*30+1;const currentBlockStart=Math.floor((currentDay-1)/10)*10+1;const current=sorted.filter(h=>h.day>=currentBlockStart&&h.day<=currentDay);const groups:HistoryGroup[]=[];for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=start+9;const rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`block-${start}`,label:`Days ${start}–${end}`,rows,fromDay:start,toDay:end,stats:sumStats(rows),type:"block"})}for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30;const rows=sorted.filter(h=>h.day>=start&&h.day<=end);if(rows.length)groups.push({key:`month-${month}`,label:`Month ${month} · Days ${start}–${end}`,rows,fromDay:start,toDay:end,stats:sumStats(rows),type:"month"})}return {currentDay,current,groups}}
function buildScopeOptions(history:History[],reportedCurrentDay?:number):ScopeOption[]{const sorted=[...history].sort((a,b)=>b.day-a.day);const currentDay=Math.max(1,Number(reportedCurrentDay||sorted[0]?.day||1));const opts:ScopeOption[]=[{key:"all",label:"All Starred",all:true}];const currentMonth=Math.floor((currentDay-1)/30)+1,currentMonthStart=(currentMonth-1)*30+1,currentBlockStart=Math.floor((currentDay-1)/10)*10+1;for(let d=currentDay;d>=currentBlockStart;d--)if(sorted.some(x=>x.day===d))opts.push({key:`day-${d}`,label:`Day ${d}`,all:false,fromDay:d,toDay:d});for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=Math.min(start+9,currentDay);if(sorted.some(x=>x.day>=start&&x.day<=end))opts.push({key:`block-${start}`,label:`Days ${start}–${end}`,all:false,fromDay:start,toDay:end})}for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30;if(sorted.some(x=>x.day>=start&&x.day<=end))opts.push({key:`month-${month}`,label:`Month ${month} · Days ${start}–${end}`,all:false,fromDay:start,toDay:end})}return opts}

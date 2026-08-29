"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { EnglishLoading } from "@/components/english-frame";
import "./mywords-parity.css";

type Saved={id:string;word:string;meaning:string;context:string;status:string;practiceQuestionId:string;gptStatus:string;captureType:string;resolvedType:string;created:string;partOfSpeech?:string;synonyms?:string;antonyms?:string;example?:string;explanation?:string;question?:string;optionA?:string;optionB?:string;optionC?:string;optionD?:string;correctOption?:string};
type Stats={saved:number;eligible:number;controlledNew:number;neverRevised:number;due:number;weak:number;difficult:number;starred:number;mastered:number};
type History={date:string|null;day?:number;label:string;saved:number;eligible:number;controlledNew:number;due:number;weak:number;difficult:number;mastered:number};
type Hub={currentDay?:number;stats:Stats;available:{smart:number;weak:number;difficult:number;starred:number;random:number;all:number};sizes:number[];history:History[]};
type Pick={mode:string;label:string;date?:string|null;count:number};
const types=["AUTO","V","SM","OWS","PV","IP"];
const modes=[["🧠","Smart Revision","smart"],["🔥","Weak","weak"],["⚡","Difficult","difficult"],["⭐","Starred","starred"],["🎲","Random","random"],["▶","Practice All","all"]] as const;
function shortDate(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});}
function savedStatus(item:Saved){if(String(item.practiceQuestionId||"").trim())return "In Practice";const g=String(item.gptStatus||"").trim().toLowerCase();if(g==="ready")return "Ready";if(/review|error|fail|invalid/.test(g))return "Needs Review";return "Pending";}

export default function SavedPage(){
 const ready=useAuthGuard(),router=useRouter();
 const [hub,setHub]=useState<Hub|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pendingMode,setPendingMode]=useState<string|null>(null);
 const [manage,setManage]=useState(false);
 const [rows,setRows]=useState<Saved[]>([]);
 const [detail,setDetail]=useState<Saved|null>(null);
 const [editing,setEditing]=useState<string|null>(null);
 const [error,setError]=useState("");

 async function refreshHub(){setHub(await rpc<Hub>("english_get_saved_revision_hub"));}
 async function refreshRows(){setRows(await rpc<Saved[]>("english_get_saved_items"));}
 useEffect(()=>{if(!ready)return;const offHub=subscribeRpcFresh<Hub>("english_get_saved_revision_hub",undefined,setHub);const offRows=subscribeRpcFresh<Saved[]>("english_get_saved_items",undefined,setRows);refreshHub().catch((e:any)=>setError(e.message));return()=>{offHub();offRows();};},[ready]);
 const load=useCallback(()=>{if(!pick)return Promise.resolve([]);if(pick.date)return rpc<any[]>("english_get_saved_history_batch",{p_date:pick.date,p_mode:pick.mode,p_count:pick.count});return rpc<any[]>("english_get_saved_revision_batch",{p_mode:pick.mode,p_count:pick.count});},[pick]);
 async function openManage(){setManage(true);setDetail(null);if(!rows.length)try{await refreshRows();}catch(e:any){setError(e.message);}}
 async function changeType(id:string,next:string){setRows(a=>a.map(x=>x.id===id?{...x,captureType:next}:x));try{await rpc("english_set_saved_item_type",{p_saved_id:id,p_capture_type:next});await refreshRows();}catch(e:any){setError(e.message);await refreshRows();}}
 const history=useMemo(()=>[...(hub?.history||[])].map(h=>({...h,day:Number(h.day||0)})).filter(h=>h.date&&h.day).sort((a,b)=>b.day-a.day),[hub]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/saved" load={load} module="mySavedRevision" onExit={()=>setPick(null)}/>;
 if(detail)return <SavedDetail item={detail} onBack={()=>setDetail(null)}/>;
 if(manage)return <ManageSaved rows={rows} error={error} editing={editing} setEditing={setEditing} onBack={()=>{setManage(false);setEditing(null)}} onOpen={setDetail} onType={changeType}/>;

 const s=hub?.stats,a=hub?.available,sizeChoices=hub?.sizes?.length?hub.sizes:[10,20,30,50];
 const runMode=(mode:string,count:number)=>setPick({mode,label:`My Saved · ${modes.find(x=>x[2]===mode)?.[1]||mode}`,count});
 const smartAvailable=Number(a?.smart||0),smartCount=Math.max(1,Math.min(20,smartAvailable||20));
 const latestHistory=history[0],olderHistory=history.slice(1);
 const historyActions=(h:History&{day:number})=><div className="sms-history-actions"><button className="btn ghost mini" onClick={()=>h.date&&setPick({mode:"all",date:h.date,label:`My Saved · Day ${h.day}`,count:100})}>View</button><button className="btn soft mini" disabled={!h.eligible} onClick={()=>h.date&&setPick({mode:"all",date:h.date,label:`My Saved · Day ${h.day}`,count:100})}>Practice</button><button className="btn soft mini focus-weak" disabled={!h.weak} onClick={()=>h.date&&setPick({mode:"weak",date:h.date,label:`My Saved · Day ${h.day} · Weak`,count:20})}>Weak</button></div>;

 return <div className="saved-parity-page saved-priority-page">
  <section className="saved-subhead saved-subhead-actions"><button className="btn ghost saved-back" onClick={()=>router.push("/english/revision")}>← Back</button><div><h1>My Saved Words</h1><p>Personal revision powered by your central learning history.</p></div><button className="btn ghost mini saved-manage-button" onClick={()=>void openManage()}>Manage</button></section>
  {error&&<div className="error-box">{error}</div>}

  <section className="sms-card saved-smart-card">
   <div className="saved-smart-main"><div><span className="saved-smart-kicker">Smart Revision</span><div className="saved-due-number"><strong>{s?.due??"—"}</strong><span>Due now</span></div></div><button className="btn primary saved-smart-cta" disabled={!smartAvailable} onClick={()=>runMode("smart",smartCount)}>Start Smart Revision</button></div>
   <div className="saved-stat-strip"><span><b>{s?.saved??0}</b> Saved</span><span><b>{s?.controlledNew??0}</b> New</span><span className="is-due"><b>{s?.due??0}</b> Due</span><span><b>{s?.mastered??0}</b> Mastered</span></div>
   <div className="saved-lane-label">Focus lanes</div>
   <div className="saved-focus-lanes"><button className="btn soft mini focus-weak" disabled={!a?.weak} onClick={()=>setPendingMode("weak")}>Weak <b>{a?.weak||0}</b></button><button className="btn soft mini focus-difficult" disabled={!a?.difficult} onClick={()=>setPendingMode("difficult")}>Difficult <b>{a?.difficult||0}</b></button><button className="btn soft mini focus-starred" disabled={!a?.starred} onClick={()=>setPendingMode("starred")}>Starred <b>{a?.starred||0}</b></button></div>
   <div className="saved-browse-actions"><span>Browse</span><button className="btn ghost mini" disabled={!a?.random} onClick={()=>setPendingMode("random")}>Random</button><button className="btn ghost mini" disabled={!a?.all} onClick={()=>runMode("all",100)}>Practice All</button></div>
  </section>

  <h2 className="saved-history-title">Saved History</h2>
  <div className="saved-history-list">{latestHistory?<article className="sms-history sms-history-latest"><div className="sms-history-head"><div><b>Day {latestHistory.day}</b><div>{latestHistory.saved} saved · {latestHistory.eligible} active · {latestHistory.weak} weak · {latestHistory.mastered} mastered</div></div><span>Latest</span></div>{historyActions(latestHistory)}</article>:<div className="empty-copy">No enriched saved words are in practice yet.</div>}{olderHistory.map(h=><details className="sms-history-day-fold" key={h.date||h.day}><summary><span><b>Day {h.day}</b><small>{h.saved} saved · {h.eligible} active · {h.weak} weak</small></span><i>›</i></summary><div>{historyActions(h)}</div></details>)}</div>

  {pendingMode&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPendingMode(null)}}><section className="add-word-sheet"><div className="sheet-heading"><div><strong>{pendingMode==="smart"?"Smart Revision":`${pendingMode[0].toUpperCase()+pendingMode.slice(1)} · choose questions`}</strong></div></div><div className="saved-count-buttons">{sizeChoices.map(n=><button className="btn soft" key={n} onClick={()=>{runMode(pendingMode,n);setPendingMode(null)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPendingMode(null)}>Cancel</button></section></div>}
 </div>;
}

function ManageSaved({rows,error,editing,setEditing,onBack,onOpen,onType}:{rows:Saved[];error:string;editing:string|null;setEditing:(id:string|null)=>void;onBack:()=>void;onOpen:(item:Saved)=>void;onType:(id:string,next:string)=>void}){
 return <div className="saved-parity-page saved-manage-page">
  <section className="saved-subhead"><button className="btn ghost saved-back" onClick={onBack}>← Back</button><div><h1>My Words</h1><p>Every word you save appears here automatically.</p></div></section>
  {error&&<div className="error-box">{error}</div>}
  <div className="mywords-final-list">{rows.map(item=><article className="mywords-final-row" key={item.id} onClick={()=>onOpen(item)} role="button" tabIndex={0} onKeyDown={e=>{if(e.key==="Enter"||e.key===" ")onOpen(item)}}><div><b>{item.word}</b><div className={`mywords-final-status status-${savedStatus(item).toLowerCase().replace(/\s+/g,"-")}`}>{savedStatus(item)} · {shortDate(item.created)}</div>{editing===item.id&&<div className="capture-types myword-types" onClick={e=>e.stopPropagation()}>{types.map(next=><button key={next} className={`capture-type ${item.captureType===next?"selected":""}`} onClick={()=>void onType(item.id,next)}>{next==="IP"?"I/P":next}</button>)}</div>}</div><button className="btn ghost mini" onClick={e=>{e.stopPropagation();setEditing(editing===item.id?null:item.id)}}>Edit</button></article>)}</div>
 </div>;
}

function SavedDetail({item,onBack}:{item:Saved;onBack:()=>void}){
 const options:Array<[string,string|undefined]>=[["A",item.optionA],["B",item.optionB],["C",item.optionC],["D",item.optionD]];const correct=String(item.correctOption||"").trim().toUpperCase().replace(/[^A-D].*$/,"").charAt(0);
 const block=(label:string,value?:string)=>!String(value||"").trim()?null:<div className="myword-detail-block"><small>{label}</small><div>{value}</div></div>;
 return <div className="saved-parity-page saved-detail-page">
  <section className="saved-subhead mywords-detail-head"><button className="btn ghost saved-back" onClick={onBack}>← My Words</button><div><h1>{item.word}</h1><p>GPT enrichment · {savedStatus(item)}</p></div></section>
  <article className="myword-detail-card">
   <div><div className="myword-detail-word">{item.word}</div>{(item.partOfSpeech||item.resolvedType)&&<div className="myword-detail-type">{item.partOfSpeech||item.resolvedType}</div>}</div>
   {block("Meaning",item.meaning||item.context)}
   {item.question&&<div className="myword-detail-block"><small>Practice question</small><div className="myword-detail-question">{item.question}</div><div className="myword-detail-options">{options.map(([key,text])=>text?<div key={key} className={`myword-detail-option ${correct===key?"correct":""}`}><b>{key}.</b> {text}</div>:null)}</div></div>}
   {block("Explanation",item.explanation)}
   {block("Example",item.example)}
   {block("Synonyms",item.synonyms)}
   {block("Antonyms",item.antonyms)}
   {block("Context",item.context)}
  </article>
 </div>;
}

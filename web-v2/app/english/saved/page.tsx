"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { EnglishLoading } from "@/components/english-frame";
import "./mywords-parity.css";

type Saved={id:string;word:string;meaning:string;context:string;status:string;practiceQuestionId:string;gptStatus:string;captureType:string;resolvedType:string;created:string;partOfSpeech?:string;synonyms?:string;antonyms?:string;example?:string;explanation?:string;question?:string;optionA?:string;optionB?:string;optionC?:string;optionD?:string;correctOption?:string};
type Stats={saved:number;eligible:number;controlledNew:number;neverRevised:number;due:number;weak:number;difficult:number;starred:number;mastered:number};
type History={date:string|null;label:string;saved:number;eligible:number;controlledNew:number;due:number;weak:number;difficult:number;mastered:number};
type Hub={stats:Stats;available:{smart:number;weak:number;difficult:number;starred:number;random:number;all:number};sizes:number[];history:History[]};
type Pick={mode:string;label:string;date?:string|null;count:number};
const types=["AUTO","V","SM","OWS","PV","IP"];
const modes=[["🧠","Smart Revision","smart"],["🔥","Weak","weak"],["⚡","Difficult","difficult"],["⭐","Starred","starred"],["🎲","Random","random"],["▶","Practice All","all"]] as const;
const DAY1=Date.UTC(2026,7,14);
function dayNumber(date:string|null){if(!date)return 0;const d=new Date(date);if(Number.isNaN(d.getTime()))return 0;return Math.max(1,Math.floor((Date.UTC(d.getUTCFullYear(),d.getUTCMonth(),d.getUTCDate())-DAY1)/86400000)+1)}
function shortDate(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});}

export default function SavedPage(){
 const ready=useAuthGuard(),router=useRouter();const [hub,setHub]=useState<Hub|null>(null);const [pick,setPick]=useState<Pick|null>(null);const [pendingMode,setPendingMode]=useState<string|null>(null);const [manage,setManage]=useState(false);const [rows,setRows]=useState<Saved[]>([]);const [detail,setDetail]=useState<Saved|null>(null);const [editing,setEditing]=useState<string|null>(null);const [error,setError]=useState("");
 async function refreshHub(){setHub(await rpc<Hub>("english_get_saved_revision_hub"));}
 async function refreshRows(){setRows(await rpc<Saved[]>("english_get_saved_items"));}
 useEffect(()=>{if(ready)refreshHub().catch((e:any)=>setError(e.message));},[ready]);
 const load=useCallback(()=>{if(!pick)return Promise.resolve([]);if(pick.date)return rpc<any[]>("english_get_saved_history_batch",{p_date:pick.date,p_mode:pick.mode,p_count:pick.count});return rpc<any[]>("english_get_saved_revision_batch",{p_mode:pick.mode,p_count:pick.count});},[pick]);
 async function openManage(){setManage(true);setDetail(null);if(!rows.length)try{await refreshRows();}catch(e:any){setError(e.message);}}
 async function changeType(id:string,next:string){setRows(a=>a.map(x=>x.id===id?{...x,captureType:next}:x));try{await rpc("english_set_saved_item_type",{p_saved_id:id,p_capture_type:next});await refreshRows();}catch(e:any){setError(e.message);await refreshRows();}}
 const history=useMemo(()=>[...(hub?.history||[])].map(h=>({...h,day:dayNumber(h.date)})).filter(h=>h.date&&h.day).sort((a,b)=>b.day-a.day),[hub]);
 const currentDay=Math.max(1,Math.floor((Date.now()-DAY1)/86400000)+1),blockStart=Math.floor((currentDay-1)/10)*10+1;
 const currentRows=history.filter(h=>h.day>=blockStart&&h.day<=blockStart+9),older=history.filter(h=>h.day<blockStart),olderBlocks=Array.from(new Set(older.map(h=>Math.floor((h.day-1)/10)*10+1))).sort((a,b)=>b-a);
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref="/english/saved" load={load} module="mySavedRevision" onExit={()=>setPick(null)}/>;
 if(detail)return <SavedDetail item={detail} onBack={()=>setDetail(null)}/>;
 if(manage)return <ManageSaved rows={rows} error={error} editing={editing} setEditing={setEditing} onBack={()=>{setManage(false);setEditing(null)}} onOpen={setDetail} onType={changeType}/>;
 const s=hub?.stats,a=hub?.available;
 const runMode=(mode:string,count:number)=>setPick({mode,label:`My Saved · ${modes.find(x=>x[2]===mode)?.[1]||mode}`,count});
 const historyCard=(h:History&{day:number})=><div className="sms-history" key={h.date}><div className="sms-history-head"><div><b>Day {h.day}</b><div>{h.saved} saved · {h.eligible} active · {h.weak} weak · {h.mastered} mastered</div></div><span>›</span></div><div className="sms-history-actions"><button className="btn ghost mini" onClick={()=>h.date&&setPick({mode:"all",date:h.date,label:`My Saved · Day ${h.day}`,count:100})}>View</button><button className="btn soft mini" disabled={!h.eligible} onClick={()=>h.date&&setPick({mode:"all",date:h.date,label:`My Saved · Day ${h.day}`,count:100})}>Practice</button><button className="btn soft mini" disabled={!h.weak} onClick={()=>h.date&&setPick({mode:"weak",date:h.date,label:`My Saved · Day ${h.day} · Weak`,count:20})}>Weak</button></div></div>;
 return <div className="saved-parity-page">
  <section className="saved-subhead"><button className="btn ghost saved-back" onClick={()=>router.push("/english/revision")}>← Back</button><div><h1>My Saved Words</h1><p>Personal revision powered by your central learning history.</p></div></section>
  <div className="saved-manage-line"><button className="btn ghost mini" onClick={()=>void openManage()}>Manage Saved Words</button></div>
  {error&&<div className="error-box">{error}</div>}
  <section className="sms-card"><div className="sms-card-head"><div><b>🧠 Smart Revision</b><p>Central intelligence + stronger coverage rotation for words you personally saved.</p></div><span className="pill">{s?.eligible??0} active</span></div><div className="sms-metrics"><div><b>{s?.saved??0}</b><small>Saved</small></div><div><b>{s?.neverRevised??0}</b><small>Never Revised</small></div><div><b>{s?.due??0}</b><small>Due</small></div><div><b>{s?.mastered??0}</b><small>Mastered</small></div></div><div className="sms-actions">{modes.map(([icon,label,mode])=>{const n=Number(a?.[mode as keyof typeof a]||0);return <button key={mode} className="btn soft mini" disabled={!n} onClick={()=>mode==="all"?runMode("all",100):setPendingMode(mode)}>{icon}<br/>{label}{n?` (${n})`:""}</button>})}</div><div className="sms-cache-note">Cached first · refreshes silently in background</div></section>
  <h2 className="saved-history-title">Saved History</h2>
  <div className="saved-history-list">{currentRows.map(historyCard)}{olderBlocks.map(start=>{const block=older.filter(h=>h.day>=start&&h.day<=start+9);return <details className="sms-history-fold" key={start}><summary>Days {start}–{start+9}<span>›</span></summary><div>{block.map(historyCard)}</div></details>})}{!history.length&&<div className="empty-copy">No enriched saved words are in practice yet.</div>}</div>
  {pendingMode&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPendingMode(null)}}><section className="add-word-sheet"><div className="sheet-heading"><div><strong>{pendingMode==="smart"?"Smart Revision":`${pendingMode[0].toUpperCase()+pendingMode.slice(1)} · choose questions`}</strong></div></div><div className="saved-count-buttons">{[10,20,30,50].map(n=><button className="btn soft" key={n} onClick={()=>{runMode(pendingMode,n);setPendingMode(null)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPendingMode(null)}>Cancel</button></section></div>}
 </div>;
}

function ManageSaved({rows,error,editing,setEditing,onBack,onOpen,onType}:{rows:Saved[];error:string;editing:string|null;setEditing:(id:string|null)=>void;onBack:()=>void;onOpen:(item:Saved)=>void;onType:(id:string,next:string)=>void}){
 return <div className="saved-parity-page saved-manage-page">
  <section className="saved-subhead"><button className="btn ghost saved-back" onClick={onBack}>← Back</button><div><h1>My Words</h1><p>Every word you save appears here automatically.</p></div></section>
  {error&&<div className="error-box">{error}</div>}
  <div className="mywords-final-list">{rows.map(item=><article className="mywords-final-row" key={item.id} onClick={()=>onOpen(item)} role="button" tabIndex={0} onKeyDown={e=>{if(e.key==="Enter"||e.key===" ")onOpen(item)}}><div><b>{item.word}</b><div className="mywords-final-status">{/pending/i.test(item.gptStatus||"")?"Pending enrichment":"In Practice"} · {shortDate(item.created)}</div>{editing===item.id&&<div className="capture-types myword-types" onClick={e=>e.stopPropagation()}>{types.map(next=><button key={next} className={`capture-type ${item.captureType===next?"selected":""}`} onClick={()=>void onType(item.id,next)}>{next==="IP"?"I/P":next}</button>)}</div>}</div><button className="btn ghost mini" onClick={e=>{e.stopPropagation();setEditing(editing===item.id?null:item.id)}}>Edit</button></article>)}</div>
 </div>;
}

function SavedDetail({item,onBack}:{item:Saved;onBack:()=>void}){
 const options:[[string,string|undefined],[string,string|undefined],[string,string|undefined],[string,string|undefined]]=[["A",item.optionA],["B",item.optionB],["C",item.optionC],["D",item.optionD]];const correct=String(item.correctOption||"").trim().toUpperCase().replace(/[^A-D].*$/,"").charAt(0);
 const block=(label:string,value?:string)=>!String(value||"").trim()?null:<div className="myword-detail-block"><small>{label}</small><div>{value}</div></div>;
 return <div className="saved-parity-page saved-detail-page">
  <section className="saved-subhead mywords-detail-head"><button className="btn ghost saved-back" onClick={onBack}>← My Words</button><div><h1>{item.word}</h1><p>GPT enrichment · view only</p></div></section>
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

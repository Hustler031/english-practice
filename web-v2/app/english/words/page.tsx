"use client";
import { useEffect,useState } from "react";
import { useRouter } from "next/navigation";
import { EnglishLoading } from "@/components/english-frame";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import "../saved/mywords-parity.css";

type Saved={
  id:string;word:string;meaning:string;context:string;status:string;practiceQuestionId:string;gptStatus:string;
  captureType:string;resolvedType:string;created:string;partOfSpeech?:string;synonyms?:string;antonyms?:string;
  example?:string;explanation?:string;question?:string;optionA?:string;optionB?:string;optionC?:string;optionD?:string;
  correctOption?:string;enrichmentState?:string;enrichmentAttemptCount?:number;enrichmentLastError?:string;enrichmentNextAttempt?:string;
};
const types=["AUTO","V","SM","OWS","PV","IP","CU"];

function shortDate(value:string){const d=new Date(value);return Number.isNaN(d.getTime())?value:d.toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"})}
function bestCriticScore(error:string){const scores=[...String(error||"").matchAll(/critic_reject:(\d+)/gi)].map(m=>Number(m[1])).filter(Number.isFinite);return scores.length?Math.max(...scores):0}
function retryEta(value?:string){if(!value)return "retry in ~1 min";const at=new Date(value).getTime();if(!Number.isFinite(at))return "retry in ~1 min";const mins=Math.ceil((at-Date.now())/60000);return mins<=0?"retry queued":mins===1?"retry in ~1 min":`retry in ${mins} min`}
function enrichmentReason(item:Saved){
  const state=String(item.enrichmentState||"").toLowerCase();
  const error=String(item.enrichmentLastError||"");
  if(!/pending/i.test(item.gptStatus||"")&&state!=="failed")return "In Practice";
  if(state==="processing")return "Enriching now";
  const score=bestCriticScore(error);
  const providerErrors=(error.match(/provider_error/gi)||[]).length;
  let reason="Enrichment attempt failed";
  if(/429|quota|rate limit/i.test(error))reason="AI provider rate limit";
  else if(/503|high demand|overloaded/i.test(error))reason="AI provider high demand";
  else if(/timeout|timed out|AI_TIMEOUT/i.test(error))reason="AI provider timeout";
  else if(providerErrors>0&&score>0)reason=`AI provider issue + quality ${score}/85`;
  else if(score>0)reason=`Quality ${score}/85 · needs 85`;
  else if(providerErrors>0)reason="AI provider unavailable";
  else if(/code_reject/i.test(error))reason="Question format validation failed";
  else if(/without an item result/i.test(error))reason="Worker returned no item";
  if(state==="failed")return `Needs review · ${reason}`;
  if(state==="retrying")return `Retrying · ${reason} · ${retryEta(item.enrichmentNextAttempt)}`;
  return /pending/i.test(item.gptStatus||"")?"Pending enrichment":reason;
}

export default function WordsPage(){
  const ready=useAuthGuard(),router=useRouter();
  const[rows,setRows]=useState<Saved[]>([]);const[detail,setDetail]=useState<Saved|null>(null);const[editing,setEditing]=useState<string|null>(null);const[error,setError]=useState("");const[returnHref,setReturnHref]=useState("/english/library");
  useEffect(()=>{try{const r=new URLSearchParams(window.location.search).get("return");if(r?.startsWith("/english"))setReturnHref(r)}catch{}},[]);
  async function refresh(){setRows(await rpc<Saved[]>("english_get_saved_items"))}
  useEffect(()=>{if(ready)refresh().catch((e:any)=>setError(e.message))},[ready]);
  useEffect(()=>{
    const onFresh=(event:Event)=>{const detail=(event as CustomEvent<{name?:string;data?:Saved[]}>).detail;if(detail?.name==="english_get_saved_items"&&Array.isArray(detail.data))setRows(detail.data)};
    window.addEventListener("ep:v2-rpc-fresh",onFresh as EventListener);return()=>window.removeEventListener("ep:v2-rpc-fresh",onFresh as EventListener);
  },[]);
  const hasPending=rows.some(x=>/pending/i.test(x.gptStatus||"")||["processing","retrying"].includes(String(x.enrichmentState||"").toLowerCase()));
  useEffect(()=>{if(!ready||!hasPending)return;const timer=window.setInterval(()=>{void refresh().catch(()=>undefined)},30000);return()=>window.clearInterval(timer)},[ready,hasPending]);
  async function changeType(id:string,next:string){setRows(a=>a.map(x=>x.id===id?{...x,captureType:next}:x));try{await rpc("english_set_saved_item_type",{p_saved_id:id,p_capture_type:next});await refresh()}catch(e:any){setError(e.message);await refresh()}}
  if(!ready)return <EnglishLoading text="Checking session…"/>;
  if(detail)return <Detail item={detail} onBack={()=>setDetail(null)}/>;
  return <div className="saved-parity-page saved-manage-page"><section className="saved-subhead"><button className="btn ghost saved-back" onClick={()=>router.push(returnHref)}>← Back</button><div><h1>My Words</h1><p>Every word you save appears here automatically.</p></div></section>{error&&<div className="error-box">{error}</div>}<div className="mywords-final-list">{rows.map(item=><article className="mywords-final-row" key={item.id} onClick={()=>setDetail(item)} role="button" tabIndex={0} onKeyDown={e=>{if(e.key==="Enter"||e.key===" ")setDetail(item)}}><div><b>{item.word}</b><div className="mywords-final-status">{enrichmentReason(item)} · {shortDate(item.created)}</div>{editing===item.id&&<div className="capture-types myword-types" style={{display:"grid",gridTemplateColumns:"repeat(7,minmax(0,1fr))",gap:4}} onClick={e=>e.stopPropagation()}>{types.map(next=><button key={next} style={{minWidth:0,paddingInline:4}} className={`capture-type ${item.captureType===next?"selected":""}`} onClick={()=>void changeType(item.id,next)}>{next==="IP"?"I/P":next}</button>)}</div>}</div><button className="btn ghost mini" onClick={e=>{e.stopPropagation();setEditing(editing===item.id?null:item.id)}}>Edit</button></article>)}</div></div>
}
function Detail({item,onBack}:{item:Saved;onBack:()=>void}){const options:[[string,string|undefined],[string,string|undefined],[string,string|undefined],[string,string|undefined]]=[["A",item.optionA],["B",item.optionB],["C",item.optionC],["D",item.optionD]];const correct=String(item.correctOption||"").trim().toUpperCase().replace(/[^A-D].*$/,"").charAt(0);const block=(label:string,value?:string)=>!String(value||"").trim()?null:<div className="myword-detail-block"><small>{label}</small><div>{value}</div></div>;const pending=/pending/i.test(item.gptStatus||"")||["processing","retrying","failed"].includes(String(item.enrichmentState||"").toLowerCase());return <div className="saved-parity-page saved-detail-page"><section className="saved-subhead mywords-detail-head"><button className="btn ghost saved-back" onClick={onBack}>← My Words</button><div><h1>{item.word}</h1><p>GPT enrichment · view only</p></div></section><article className="myword-detail-card"><div><div className="myword-detail-word">{item.word}</div>{(item.partOfSpeech||item.resolvedType)&&<div className="myword-detail-type">{item.partOfSpeech||item.resolvedType}</div>}</div>{pending&&block("Enrichment status",enrichmentReason(item))}{block("Meaning",item.meaning||item.context)}{item.question&&<div className="myword-detail-block"><small>Practice question</small><div className="myword-detail-question">{item.question}</div><div className="myword-detail-options">{options.map(([key,text])=>text?<div key={key} className={`myword-detail-option ${correct===key?"correct":""}`}><b>{key}.</b> {text}</div>:null)}</div></div>}{block("Explanation",item.explanation)}{block("Example",item.example)}{block("Synonyms",item.synonyms)}{block("Antonyms",item.antonyms)}{block("Context",item.context)}</article></div>}

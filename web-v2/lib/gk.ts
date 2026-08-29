"use client";

import { supabaseBrowser } from "@/lib/supabase";

type Args = Record<string, unknown>;
type OutboxItem = { id: string; args: Args; tries: number; nextAt: number };
const CACHE_PREFIX = "revision:gk:v2:cache:";
const OUTBOX_KEY = "revision:gk:v2:answer-outbox";
const BACKOFF = [1000, 2500, 5000, 15000, 30000, 60000];
let flushing = false;
let wired = false;

function browser() { return typeof window !== "undefined"; }
function stable(args?: Args) { return JSON.stringify(Object.keys(args ?? {}).sort().reduce<Args>((o,k)=>{o[k]=(args ?? {})[k];return o;},{})); }
function key(name:string,args?:Args){ return `${CACHE_PREFIX}${name}:${stable(args)}`; }
function cacheable(name:string){ return name.startsWith("gk_get_"); }
function readCache<T>(name:string,args?:Args):T|undefined { if(!browser()) return; try { const raw=localStorage.getItem(key(name,args)); if(!raw)return; const e=JSON.parse(raw); if(Date.now()-Number(e.at||0)>12*60*60*1000)return; return e.data as T; } catch{return;} }
function writeCache(name:string,args:Args|undefined,data:unknown){ if(!browser())return; try{localStorage.setItem(key(name,args),JSON.stringify({at:Date.now(),data}));}catch{} }
function publish(name:string,args:Args|undefined,data:unknown){ if(!browser())return; window.dispatchEvent(new CustomEvent("revision:gk:fresh",{detail:{name,args:stable(args),data}})); }
async function network<T>(name:string,args?:Args):Promise<T>{ const {data,error}=await supabaseBrowser().rpc(name,args??{}); if(error)throw error; return data as T; }

function readOutbox():OutboxItem[]{ if(!browser())return[]; try{const x=JSON.parse(localStorage.getItem(OUTBOX_KEY)||"[]");return Array.isArray(x)?x:[];}catch{return[];} }
function writeOutbox(x:OutboxItem[]){ if(!browser())return; try{localStorage.setItem(OUTBOX_KEY,JSON.stringify(x));}catch{} }
function makeId(qid:string){ return `gk-v2-${qid}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`; }

export async function flushGkOutbox(){
  if(!browser()||flushing||!navigator.onLine)return;
  const rows=readOutbox(); if(!rows.length)return;
  const item=rows.find(x=>x.nextAt<=Date.now())??rows[0]; flushing=true;
  try{
    try{ await network("gk_submit_answer",item.args); writeOutbox(readOutbox().filter(x=>x.id!==item.id)); window.dispatchEvent(new CustomEvent("revision:gk:answer-synced",{detail:{id:item.id}})); }
    catch{ const next=readOutbox(); const hit=next.find(x=>x.id===item.id); if(hit){hit.tries++; hit.nextAt=Date.now()+BACKOFF[Math.min(hit.tries,BACKOFF.length-1)]; writeOutbox(next);} }
  } finally { flushing=false; if(readOutbox().length)setTimeout(()=>void flushGkOutbox(),500); }
}
function wire(){ if(!browser()||wired)return; wired=true; addEventListener("online",()=>void flushGkOutbox()); document.addEventListener("visibilitychange",()=>{if(!document.hidden)void flushGkOutbox();}); setInterval(()=>{if(readOutbox().length)void flushGkOutbox();},60000); void flushGkOutbox(); }

export async function gkRpc<T=unknown>(name:string,args?:Args):Promise<T>{
  wire();
  if(cacheable(name)){
    const cached=readCache<T>(name,args);
    if(cached!==undefined){ void network<T>(name,args).then(f=>{writeCache(name,args,f);publish(name,args,f);}).catch(()=>{}); return cached; }
    const fresh=await network<T>(name,args); writeCache(name,args,fresh); return fresh;
  }
  const result=await network<T>(name,args); return result;
}

export async function queueGkAnswer(input:{questionId:string;selectedOption:string;mode?:string;sessionId?:string|null;responseMs?:number|null;markedReview?:boolean}){
  wire(); const id=makeId(input.questionId);
  const args:Args={p_question_id:input.questionId,p_selected_option:input.selectedOption,p_marked_review:!!input.markedReview,p_attempt_id:id,p_mode:input.mode??"practice",p_session_id:input.sessionId??null,p_response_ms:input.responseMs??null};
  const rows=readOutbox(); rows.push({id,args,tries:0,nextAt:0}); writeOutbox(rows); void flushGkOutbox();
  return {ok:true,queued:true,attemptId:id};
}

export function subscribeGkFresh<T>(name:string,args:Args|undefined,fn:(data:T)=>void){ if(!browser())return()=>{}; const wanted=stable(args); const h=(e:Event)=>{const d=(e as CustomEvent).detail;if(d?.name===name&&d?.args===wanted)fn(d.data as T);}; addEventListener("revision:gk:fresh",h); return()=>removeEventListener("revision:gk:fresh",h); }
export function pendingGkAnswers(){ return readOutbox().length; }

"use client";

import { supabaseBrowser } from "@/lib/supabase";

export type MathsMetric = { total:number; attempted:number; unseen:number; coverage:number; wrong:number; difficult:number; starred:number; weak:number; hard:number; mastered:number };
export type MathsQuestion = {
  questionId:string; chapter:string; topic:string; subtopic:string; majorTopic?:string; prompt:string; answer:string;
  explanation:string; memoryCue:string; answerMode:"MCQ"|"REVEAL"; options:{key:string;text:string}[]; correctOption:string;
  variantType:string; starred:boolean; difficult:boolean; mastered:boolean; inConcept:boolean; diagram?:{type?:string;payload:unknown}|null;
  sourceFile?:string; sourcePage?:string;
};
export type MathsSession = {
  ok:boolean; localSafe?:boolean; sessionId:string; mode:string; title:string; currentIndex:number; completed:boolean; target:number;
  params?:Record<string,unknown>; questions:MathsQuestion[]; attempts?:Record<string,{result:string;selectedOption?:string;responseSec?:number;attemptId?:string}>;
  flags?:Record<string,{starred?:boolean;difficult?:boolean;mastered?:boolean;inConcept?:boolean}>; message?:string; dailyComplete?:boolean;
};

type RpcArgs=Record<string,unknown>;
type CacheEntry<T=unknown>={at:number;name:string;args:RpcArgs;data:T};
type PendingAnswer={id:string;args:RpcArgs;tries:number;nextAt:number;queuedAt:number};
type FreshDetail<T=unknown>={name:string;args:RpcArgs;data:T};

const CACHE_PREFIX="maths:v2:rpc-cache:";
const SESSION_PREFIX="maths:v2:session:";
const OUTBOX_KEY="maths:v2:answer-outbox:v1";
const CACHE_MAX_AGE=12*60*60*1000;
const BACKOFF=[1000,2500,5000,15000,30000,60000];
const PROD_HOST="hytehindbmjdwcfptsic.supabase.co";
let outboxRunning=false;
let wired=false;
let wakeTimer:ReturnType<typeof setTimeout>|null=null;

function browser(){return typeof window!=="undefined";}
function loopback(host:string){const x=host.toLowerCase();return x==="localhost"||x==="127.0.0.1"||x==="::1"||x==="[::1]";}
export function mathsLocalSafe(){
  if(!browser()||!loopback(window.location.hostname))return false;
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;if(!url)return false;
  try{return new URL(url).hostname.toLowerCase()===PROD_HOST;}catch{return false;}
}
function stable(args?:RpcArgs){const x=args??{};return Object.keys(x).sort().reduce<RpcArgs>((o,k)=>{o[k]=x[k];return o;},{});}
function stableText(args?:RpcArgs){return JSON.stringify(stable(args));}
function cacheKey(name:string,args?:RpcArgs){return `${CACHE_PREFIX}${name}:${stableText(args)}`;}
function cacheable(name:string){return name.startsWith("maths_get_");}
function readCache<T>(name:string,args?:RpcArgs):T|undefined{
  if(!browser())return undefined;try{const raw=localStorage.getItem(cacheKey(name,args));if(!raw)return undefined;const e=JSON.parse(raw) as CacheEntry<T>;if(!e||Date.now()-Number(e.at||0)>CACHE_MAX_AGE)return undefined;return e.data;}catch{return undefined;}
}
function writeCache<T>(name:string,args:RpcArgs|undefined,data:T){if(!browser())return;try{localStorage.setItem(cacheKey(name,args),JSON.stringify({at:Date.now(),name,args:stable(args),data} satisfies CacheEntry<T>));}catch{}}
function publish<T>(name:string,args:RpcArgs|undefined,data:T){if(!browser())return;try{window.dispatchEvent(new CustomEvent<FreshDetail<T>>("maths:v2-rpc-fresh",{detail:{name,args:stable(args),data}}));}catch{}}
function saveSession(session:MathsSession){if(!browser()||!session?.sessionId)return;try{localStorage.setItem(SESSION_PREFIX+session.sessionId,JSON.stringify(session));}catch{}}
function readSavedSession(id:string):MathsSession|null{if(!browser())return null;try{return JSON.parse(localStorage.getItem(SESSION_PREFIX+id)||"null");}catch{return null;}}
function patchSavedSession(id:string,mut:(s:MathsSession)=>MathsSession){const s=readSavedSession(id);if(!s)return null;const next=mut(s);saveSession(next);return next;}
function localFlagResult(name:string,args:RpcArgs){const id=String(args.p_question_id??"");const value=Boolean(args.p_value);for(let i=0;i<localStorage.length;i++){const key=localStorage.key(i);if(!key?.startsWith(SESSION_PREFIX))continue;try{const s=JSON.parse(localStorage.getItem(key)||"null") as MathsSession;if(!s?.questions?.some(q=>q.questionId===id))continue;const questions=s.questions.map(q=>q.questionId===id?{...q,...(name==="maths_set_starred"?{starred:value}:name==="maths_set_difficult"?{difficult:value}:name==="maths_set_mastered"?{mastered:value}:name==="maths_set_concept"?{inConcept:value}:{})}:q);saveSession({...s,questions});}catch{}}
  return {ok:true,dry_run:true,local_only:true,questionId:id,starred:name==="maths_set_starred"?value:undefined,difficult:name==="maths_set_difficult"?value:undefined,mastered:name==="maths_set_mastered"?value:undefined,inConcept:name==="maths_set_concept"?value:undefined};
}
function localMutation<T>(name:string,args:RpcArgs):T{
  if(name.startsWith("maths_set_"))return localFlagResult(name,args) as T;
  if(name==="maths_save_session_position"){
    const id=String(args.p_session_id??"");const index=Number(args.p_index??0);const s=patchSavedSession(id,x=>({...x,currentIndex:Math.max(0,Math.min(index,Math.max(0,x.questions.length-1)))}));return ({ok:true,dry_run:true,currentIndex:s?.currentIndex??index}) as T;
  }
  if(name==="maths_finish_session"){
    const id=String(args.p_session_id??"");patchSavedSession(id,x=>({...x,completed:true}));return ({ok:true,dry_run:true,completed:true}) as T;
  }
  if(name==="maths_save_note")return ({ok:true,dry_run:true,saved:true}) as T;
  return ({ok:true,dry_run:true,local_only:true}) as T;
}
async function networkRpc<T>(name:string,args?:RpcArgs):Promise<T>{const {data,error}=await supabaseBrowser().rpc(name,args??{});if(error)throw error;return data as T;}
function startRpc(name:string){return /^maths_start_/.test(name);}
async function localSafeStart<T>(name:string,args?:RpcArgs):Promise<T>{const data=await networkRpc<T>("maths_get_local_safe_start",{p_start_rpc:name,p_args:args??{}});if((data as MathsSession)?.sessionId)saveSession(data as MathsSession);return data;}

function readOutbox():PendingAnswer[]{if(!browser())return[];try{const x=JSON.parse(localStorage.getItem(OUTBOX_KEY)||"[]");return Array.isArray(x)?x:[];}catch{return[];}}
function writeOutbox(rows:PendingAnswer[]){if(!browser())return;try{localStorage.setItem(OUTBOX_KEY,JSON.stringify(rows));window.dispatchEvent(new Event("maths:v2-sync-change"));}catch{}}
function schedule(ms=0){if(!browser())return;if(wakeTimer)clearTimeout(wakeTimer);wakeTimer=setTimeout(()=>void flushMathsOutbox(),Math.max(0,ms));}
function optimisticFromSession(args:RpcArgs){const sid=String(args.p_session_id??"");const qid=String(args.p_question_id??"");const selected=String(args.p_selected_option??"").toUpperCase();const session=readSavedSession(sid);const q=session?.questions?.find(x=>x.questionId===qid);const reveal=q?.answerMode==="REVEAL";const result=reveal?"seen":selected&&selected===String(q?.correctOption??"").toUpperCase()?"correct":"wrong";const attemptId=String(args.p_client_attempt_key??"");if(session){const attempts={...(session.attempts??{}),[qid]:{result,selectedOption:selected,responseSec:Number(args.p_response_sec??0),attemptId}};saveSession({...session,attempts});}return {ok:true,queued:!mathsLocalSafe(),durable:mathsLocalSafe(),dry_run:mathsLocalSafe(),result,correct:result==="correct",correctOption:q?.correctOption??"",selectedOption:selected,attemptId};}
async function queueAnswer<T>(args:RpcArgs):Promise<T>{
  const sid=String(args.p_session_id??"");const qid=String(args.p_question_id??"");const key=String(args.p_client_attempt_key??"").trim()||`maths-v2-${sid}-${qid}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`;args={...args,p_client_attempt_key:key};
  const optimistic=optimisticFromSession(args) as T;if(mathsLocalSafe())return optimistic;
  const rows=readOutbox();if(!rows.some(x=>x.id===key))rows.push({id:key,args,tries:0,nextAt:0,queuedAt:Date.now()});writeOutbox(rows);schedule(0);return optimistic;
}
async function flushMathsOutbox(){
  if(!browser()||outboxRunning||!navigator.onLine||mathsLocalSafe())return;const rows=readOutbox();if(!rows.length)return;const now=Date.now();const item=rows.find(x=>x.nextAt<=now);if(!item){schedule(Math.min(60000,Math.max(500,Math.min(...rows.map(x=>x.nextAt))-now)));return;}outboxRunning=true;
  try{try{const result=await networkRpc("maths_submit_answer",item.args);writeOutbox(readOutbox().filter(x=>x.id!==item.id));window.dispatchEvent(new CustomEvent("maths:v2-answer-durable",{detail:{id:item.id,result}}));invalidateMathsCaches();}catch{const latest=readOutbox();const hit=latest.find(x=>x.id===item.id);if(hit){hit.tries++;hit.nextAt=Date.now()+BACKOFF[Math.min(BACKOFF.length-1,Math.max(0,hit.tries-1))];writeOutbox(latest);}}}finally{outboxRunning=false;if(readOutbox().length)schedule(250);}
}
function wire(){if(!browser()||wired)return;wired=true;window.addEventListener("online",()=>schedule(0));document.addEventListener("visibilitychange",()=>{if(!document.hidden)schedule(0);});window.setInterval(()=>{if(readOutbox().length)schedule(0);},60000);schedule(0);}
export function pendingMathsWrites(){return readOutbox().length;}
export function invalidateMathsCaches(){if(!browser())return;const keys:string[]=[];for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(k?.startsWith(CACHE_PREFIX))keys.push(k);}keys.forEach(k=>localStorage.removeItem(k));}

export async function mathsRpc<T=unknown>(name:string,args?:RpcArgs):Promise<T>{
  wire();
  if(mathsLocalSafe()&&startRpc(name))return localSafeStart<T>(name,args);
  if(name==="maths_submit_answer")return queueAnswer<T>({...args});
  if(mathsLocalSafe()&&!name.startsWith("maths_get_"))return localMutation<T>(name,args??{});
  if(cacheable(name)){
    const cached=readCache<T>(name,args);if(cached!==undefined){void networkRpc<T>(name,args).then(fresh=>{writeCache(name,args,fresh);publish(name,args,fresh);if(name==="maths_get_session"&&(fresh as MathsSession)?.sessionId)saveSession(fresh as MathsSession);}).catch(()=>{});return cached;}
    const fresh=await networkRpc<T>(name,args);writeCache(name,args,fresh);if(name==="maths_get_session"&&(fresh as MathsSession)?.sessionId)saveSession(fresh as MathsSession);return fresh;
  }
  const out=await networkRpc<T>(name,args);if(startRpc(name)&&(out as MathsSession)?.sessionId)saveSession(out as MathsSession);if(/^maths_(set_|save_|finish_)/.test(name))invalidateMathsCaches();return out;
}

export async function getMathsSession(sessionId:string):Promise<MathsSession>{
  if(mathsLocalSafe()&&sessionId.startsWith("local-")){const local=readSavedSession(sessionId);if(local)return local;throw new Error("Local Safe session is no longer available on this device.");}
  const fresh=await mathsRpc<MathsSession>("maths_get_session",{p_session_id:sessionId});const local=readSavedSession(sessionId);if(!local)return fresh;
  const attempts={...(fresh.attempts??{}),...(local.attempts??{})};const questions=fresh.questions.map(q=>{const l=local.questions.find(x=>x.questionId===q.questionId);return l?{...q,starred:l.starred,difficult:l.difficult,mastered:l.mastered,inConcept:l.inConcept}:q;});const merged={...fresh,attempts,questions};saveSession(merged);return merged;
}
export function rememberMathsSession(session:MathsSession){saveSession(session);}
export function subscribeMathsFresh<T>(name:string,args:RpcArgs|undefined,onFresh:(data:T)=>void){if(!browser())return()=>{};const wanted=stableText(args);const fn=(e:Event)=>{const d=(e as CustomEvent<FreshDetail<T>>).detail;if(d?.name===name&&stableText(d.args)===wanted)onFresh(d.data);};window.addEventListener("maths:v2-rpc-fresh",fn);return()=>window.removeEventListener("maths:v2-rpc-fresh",fn);}

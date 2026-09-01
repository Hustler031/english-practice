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
type CacheEntry<T=unknown>={at:number;ownerId:string;name:string;args:RpcArgs;data:T};
type PendingWrite={id:string;ownerId:string;name:string;args:RpcArgs;tries:number;nextAt:number;queuedAt:number;lastError?:string};
type FreshDetail<T=unknown>={name:string;args:RpcArgs;data:T};
type WarmRead=[name:string,args?:RpcArgs];

const CACHE_PREFIX="maths:v2:rpc-cache:";
const SESSION_PREFIX="maths:v2:session:";
const OUTBOX_PREFIX="maths:v2:write-outbox:v2:";
const LEGACY_OUTBOX_KEY="maths:v2:answer-outbox:v1";
const CACHE_MAX_AGE=12*60*60*1000;
const WARM_SKIP_AGE=90*1000;
const RPC_TIMEOUT_MS=15000;
const BACKOFF=[1000,2500,5000,15000,30000,60000];
const PROD_HOST="hytehindbmjdwcfptsic.supabase.co";
const CORE_WARM_GROUPS:WarmRead[][]=[
  [["maths_get_home_snapshot"],["maths_get_chapters_hub"],["maths_get_ondemand_hub"]],
  [["maths_get_library_hub"],["maths_get_progress"]],
  [["maths_get_mocks_hub"],["maths_get_formula_hub"],["maths_get_concepts_hub"],["maths_get_calculation_hub"]],
];
let outboxRunning=false;
let wired=false;
let wakeTimer:ReturnType<typeof setTimeout>|null=null;
let warmTimer:ReturnType<typeof setTimeout>|null=null;
let coreWarmRunning:Promise<void>|null=null;
let activeOwnerId="";
let ownerCheck:Promise<string>|null=null;
let cacheEpoch=0;
const readInflight=new Map<string,Promise<unknown>>();

function browser(){return typeof window!=="undefined";}
function loopback(host:string){const x=host.toLowerCase();return x==="localhost"||x==="127.0.0.1"||x==="::1"||x==="[::1]";}
export function mathsErrorMessage(error:unknown,fallback="Maths request failed. Please retry."){
  if(error instanceof Error)return error.message||fallback;
  if(typeof error==="string"&&error.trim())return error.trim();
  if(error&&typeof error==="object"){
    const row=error as Record<string,unknown>;
    const parts=[row.message,row.details,row.hint]
      .map(value=>typeof value==="string"?value.trim():"")
      .filter(Boolean);
    if(parts.length)return [...new Set(parts)].join(" · ");
  }
  return fallback;
}
export function mathsLocalSafe(){
  if(!browser()||!loopback(window.location.hostname))return false;
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;if(!url)return false;
  try{return new URL(url).hostname.toLowerCase()===PROD_HOST;}catch{return false;}
}
function stable(args?:RpcArgs){const x=args??{};return Object.keys(x).sort().reduce<RpcArgs>((o,k)=>{o[k]=x[k];return o;},{});}
function stableText(args?:RpcArgs){return JSON.stringify(stable(args));}
function cacheOwnerPrefix(){return `${CACHE_PREFIX}${activeOwnerId}:`;}
function sessionOwnerPrefix(){return `${SESSION_PREFIX}${activeOwnerId}:`;}
function outboxKey(){return `${OUTBOX_PREFIX}${activeOwnerId}`;}
function cacheKey(name:string,args?:RpcArgs){return `${cacheOwnerPrefix()}${name}:${stableText(args)}`;}
function cacheable(name:string){return name.startsWith("maths_get_");}
function clearLegacyUnscopedStorage(){
  if(!browser())return;const keys:string[]=[];
  for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(k===LEGACY_OUTBOX_KEY||k?.startsWith(CACHE_PREFIX)&&!k.startsWith(cacheOwnerPrefix())||k?.startsWith(SESSION_PREFIX)&&!/^maths:v2:session:[^:]+:/.test(k))keys.push(k);}
  keys.forEach(k=>localStorage.removeItem(k));
}
function setOwner(id:string){
  if(activeOwnerId===id)return;activeOwnerId=id;cacheEpoch++;readInflight.clear();clearLegacyUnscopedStorage();
  if(browser())window.dispatchEvent(new Event("maths:v2-owner-change"));
}
async function ensureOwner(){
  if(activeOwnerId)return activeOwnerId;if(ownerCheck)return ownerCheck;
  ownerCheck=(async()=>{const {data,error}=await supabaseBrowser().auth.getSession();if(error)throw new Error(mathsErrorMessage(error,"Could not verify Maths sign-in. Please refresh or sign in again."));const id=data.session?.user.id??"";if(!id)throw new Error("Maths session expired. Please sign in again.");setOwner(id);return id;})().finally(()=>{ownerCheck=null;});
  return ownerCheck;
}
function readCacheEntry<T>(name:string,args?:RpcArgs):CacheEntry<T>|undefined{
  if(!browser()||!activeOwnerId)return undefined;
  try{const raw=localStorage.getItem(cacheKey(name,args));if(!raw)return undefined;const e=JSON.parse(raw) as CacheEntry<T>;if(!e||e.ownerId!==activeOwnerId||Date.now()-Number(e.at||0)>CACHE_MAX_AGE)return undefined;return e;}catch{return undefined;}
}
function readCache<T>(name:string,args?:RpcArgs):T|undefined{return readCacheEntry<T>(name,args)?.data;}
function cacheAge(name:string,args?:RpcArgs){const e=readCacheEntry(name,args);return e?Math.max(0,Date.now()-Number(e.at||0)):Number.POSITIVE_INFINITY;}
function writeCache<T>(name:string,args:RpcArgs|undefined,data:T){if(!browser()||!activeOwnerId)return;try{localStorage.setItem(cacheKey(name,args),JSON.stringify({at:Date.now(),ownerId:activeOwnerId,name,args:stable(args),data} satisfies CacheEntry<T>));}catch{}}
function publish<T>(name:string,args:RpcArgs|undefined,data:T){if(!browser())return;try{window.dispatchEvent(new CustomEvent<FreshDetail<T>>("maths:v2-rpc-fresh",{detail:{name,args:stable(args),data}}));}catch{}}
function saveSession(session:MathsSession){if(!browser()||!activeOwnerId||!session?.sessionId)return;try{localStorage.setItem(sessionOwnerPrefix()+session.sessionId,JSON.stringify(session));}catch{}}
function readSavedSession(id:string):MathsSession|null{if(!browser()||!activeOwnerId)return null;try{return JSON.parse(localStorage.getItem(sessionOwnerPrefix()+id)||"null");}catch{return null;}}
function patchSavedSession(id:string,mut:(s:MathsSession)=>MathsSession){const s=readSavedSession(id);if(!s)return null;const next=mut(s);saveSession(next);return next;}
function localFlagResult(name:string,args:RpcArgs){const id=String(args.p_question_id??"");const value=Boolean(args.p_value);for(let i=0;i<localStorage.length;i++){const key=localStorage.key(i);if(!key?.startsWith(sessionOwnerPrefix()))continue;try{const s=JSON.parse(localStorage.getItem(key)||"null") as MathsSession;if(!s?.questions?.some(q=>q.questionId===id))continue;const questions=s.questions.map(q=>q.questionId===id?{...q,...(name==="maths_set_starred"?{starred:value}:name==="maths_set_difficult"?{difficult:value}:name==="maths_set_mastered"?{mastered:value}:name==="maths_set_concept"?{inConcept:value}:{})}:q);saveSession({...s,questions});}catch{}}
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
async function networkRpc<T>(name:string,args?:RpcArgs):Promise<T>{
  let timer:ReturnType<typeof setTimeout>|undefined;
  try{const result=await Promise.race([supabaseBrowser().rpc(name,args??{}),new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error(`${name} timed out. Please retry.`)),RPC_TIMEOUT_MS);})]);if(result.error)throw new Error(mathsErrorMessage(result.error,`${name} failed. Please retry.`));return result.data as T;}
  finally{if(timer)clearTimeout(timer);}
}
function networkRead<T>(name:string,args?:RpcArgs):Promise<T>{const key=cacheKey(name,args);const existing=readInflight.get(key);if(existing)return existing as Promise<T>;const request=networkRpc<T>(name,args).finally(()=>readInflight.delete(key));readInflight.set(key,request);return request;}
function startRpc(name:string){return /^maths_start_/.test(name);}
async function localSafeStart<T>(name:string,args?:RpcArgs):Promise<T>{const owner=activeOwnerId;const data=await networkRpc<T>("maths_get_local_safe_start",{p_start_rpc:name,p_args:args??{}});if(owner!==activeOwnerId)throw new Error("Maths account changed while loading. Please retry.");if((data as MathsSession)?.sessionId)saveSession(data as MathsSession);return data;}

async function warmRead(name:string,args?:RpcArgs,force=false){
  await ensureOwner();
  if(!force&&cacheAge(name,args)<WARM_SKIP_AGE)return;
  const owner=activeOwnerId,epoch=cacheEpoch;
  try{const fresh=await networkRead(name,args);if(owner!==activeOwnerId||epoch!==cacheEpoch)return;writeCache(name,args,fresh);publish(name,args,fresh);}catch{/* background warmup is best effort */}
}
export async function prefetchMathsCore(force=false){
  if(!browser())return;
  if(readOutbox().length&&!force){scheduleMathsWarm(1800);return;}
  if(coreWarmRunning)return coreWarmRunning;
  coreWarmRunning=(async()=>{
    for(const group of CORE_WARM_GROUPS){
      await Promise.allSettled(group.map(([name,args])=>warmRead(name,args,force)));
    }
  })().finally(()=>{coreWarmRunning=null;});
  return coreWarmRunning;
}
export async function prefetchMathsPath(path:string){
  const pathname=String(path||"").split("?")[0];
  const reads:WarmRead[]=
    pathname==="/maths"?[["maths_get_home_snapshot"]]:
    pathname.startsWith("/maths/chapters")?[["maths_get_chapters_hub"],["maths_get_home_snapshot"]]:
    pathname.startsWith("/maths/library")?[["maths_get_library_hub"]]:
    pathname.startsWith("/maths/ondemand")?[["maths_get_ondemand_hub"]]:
    pathname.startsWith("/maths/progress")?[["maths_get_progress"]]:
    pathname.startsWith("/maths/mocks")?[["maths_get_mocks_hub"]]:
    pathname.startsWith("/maths/formulas")?[["maths_get_formula_hub"]]:
    pathname.startsWith("/maths/concepts")?[["maths_get_concepts_hub"]]:
    pathname.startsWith("/maths/calculation")?[["maths_get_calculation_hub"]]:[];
  await Promise.allSettled(reads.map(([name,args])=>warmRead(name,args)));
}
function scheduleMathsWarm(ms=1200){
  if(!browser())return;
  if(warmTimer)clearTimeout(warmTimer);
  warmTimer=setTimeout(()=>{warmTimer=null;if(readOutbox().length){scheduleMathsWarm(1800);return;}void prefetchMathsCore();},Math.max(0,ms));
}

function readOutbox():PendingWrite[]{if(!browser()||!activeOwnerId)return[];try{const x=JSON.parse(localStorage.getItem(outboxKey())||"[]");return Array.isArray(x)?x.filter(row=>row?.ownerId===activeOwnerId):[];}catch{return[];}}
function writeOutbox(rows:PendingWrite[]){if(!browser()||!activeOwnerId)return;try{localStorage.setItem(outboxKey(),JSON.stringify(rows));window.dispatchEvent(new Event("maths:v2-sync-change"));}catch{}}
function schedule(ms=0){if(!browser())return;if(wakeTimer)clearTimeout(wakeTimer);wakeTimer=setTimeout(()=>void flushMathsOutbox(),Math.max(0,ms));}
function optimisticFromSession(args:RpcArgs){const sid=String(args.p_session_id??"");const qid=String(args.p_question_id??"");const selected=String(args.p_selected_option??"").toUpperCase();const session=readSavedSession(sid);const q=session?.questions?.find(x=>x.questionId===qid);const reveal=q?.answerMode==="REVEAL";const result=reveal?"seen":selected&&selected===String(q?.correctOption??"").toUpperCase()?"correct":"wrong";const attemptId=String(args.p_client_attempt_key??"");if(session){const attempts={...(session.attempts??{}),[qid]:{result,selectedOption:selected,responseSec:Number(args.p_response_sec??0),attemptId}};saveSession({...session,attempts});}return {ok:true,queued:!mathsLocalSafe(),durable:mathsLocalSafe(),dry_run:mathsLocalSafe(),result,correct:result==="correct",correctOption:q?.correctOption??"",selectedOption:selected,attemptId};}
async function queueAnswer<T>(args:RpcArgs):Promise<T>{
  const sid=String(args.p_session_id??"");const qid=String(args.p_question_id??"");const key=String(args.p_client_attempt_key??"").trim()||`maths-v2-${sid}-${qid}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`;args={...args,p_client_attempt_key:key};
  const optimistic=optimisticFromSession(args) as T;if(mathsLocalSafe())return optimistic;
  const rows=readOutbox();if(!rows.some(x=>x.id===key))rows.push({id:key,ownerId:activeOwnerId,name:"maths_submit_answer",args,tries:0,nextAt:0,queuedAt:Date.now()});writeOutbox(rows);schedule(0);return optimistic;
}
function queueMutation<T>(name:string,args:RpcArgs):T{
  const optimistic=localMutation<T>(name,args);const rows=readOutbox();const id=`${name}:${Date.now()}:${Math.random().toString(36).slice(2,8)}`;
  rows.push({id,ownerId:activeOwnerId,name,args,tries:0,nextAt:0,queuedAt:Date.now()});writeOutbox(rows);schedule(0);
  return (optimistic&&typeof optimistic==="object"?{...optimistic,dry_run:false,local_only:false,queued:true,durable:false}:optimistic) as T;
}
async function flushMathsOutbox(){
  if(!browser()||outboxRunning||!navigator.onLine||mathsLocalSafe())return;const rows=readOutbox();if(!rows.length)return;const now=Date.now();const item=rows.find(x=>x.nextAt<=now);if(!item){schedule(Math.min(60000,Math.max(500,Math.min(...rows.map(x=>x.nextAt))-now)));return;}outboxRunning=true;
  try{try{const result=await networkRpc(item.name,item.args);writeOutbox(readOutbox().filter(x=>x.id!==item.id));window.dispatchEvent(new CustomEvent("maths:v2-write-durable",{detail:{id:item.id,name:item.name,result}}));scheduleMathsWarm(1400);}catch(e){const latest=readOutbox();const hit=latest.find(x=>x.id===item.id);if(hit){hit.tries++;hit.lastError=mathsErrorMessage(e,"Maths write failed.");hit.nextAt=Date.now()+BACKOFF[Math.min(BACKOFF.length-1,Math.max(0,hit.tries-1))];writeOutbox(latest);}}}finally{outboxRunning=false;if(readOutbox().length)schedule(250);}
}
async function flushMathsWritesBeforeFinish(){
  if(!browser()||mathsLocalSafe())return;
  let passes=0;
  while(readOutbox().length&&passes<80){
    if(!navigator.onLine)throw new Error("Your Maths answers are saved on this device but are still offline. Reconnect before finishing.");
    await flushMathsOutbox();
    const left=readOutbox();
    if(!left.length)return;
    if(left.some(x=>x.tries>0))throw new Error("Some Maths changes are still waiting to sync. Retry Finish after sync succeeds.");
    await new Promise<void>(resolve=>window.setTimeout(resolve,50));
    passes++;
  }
  if(readOutbox().length)throw new Error("Maths is still saving your latest changes. Retry Finish after sync completes.");
}
function wire(){if(!browser()||wired)return;wired=true;window.addEventListener("online",()=>{schedule(0);scheduleMathsWarm(250);});document.addEventListener("visibilitychange",()=>{if(!document.hidden){schedule(0);scheduleMathsWarm(250);}});supabaseBrowser().auth.onAuthStateChange((_event,session)=>setOwner(session?.user.id??""));window.setInterval(()=>{if(readOutbox().length)schedule(0);},60000);schedule(0);}
export function pendingMathsWrites(){return readOutbox().length;}
export function failedMathsWrites(){return readOutbox().filter(x=>x.tries>0).length;}
export function invalidateMathsCaches(){cacheEpoch++;if(!browser()||!activeOwnerId)return;const keys:string[]=[];for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(k?.startsWith(cacheOwnerPrefix()))keys.push(k);}keys.forEach(k=>localStorage.removeItem(k));}

export async function mathsRpc<T=unknown>(name:string,args?:RpcArgs):Promise<T>{
  wire();await ensureOwner();
  if(mathsLocalSafe()&&startRpc(name))return localSafeStart<T>(name,args);
  if(name==="maths_submit_answer")return queueAnswer<T>({...args});
  if(mathsLocalSafe()&&!name.startsWith("maths_get_"))return localMutation<T>(name,args??{});
  if(name==="maths_finish_session"){
    await flushMathsWritesBeforeFinish();
    const owner=activeOwnerId;const out=await networkRpc<T>(name,args);
    if(owner!==activeOwnerId)throw new Error("Maths account changed while finishing. Please retry.");
    const sid=String(args?.p_session_id??"");if(sid)patchSavedSession(sid,x=>({...x,completed:true}));
    scheduleMathsWarm(50);return out;
  }
  if(/^maths_(set_|save_)/.test(name))return queueMutation<T>(name,args??{});
  if(cacheable(name)){
    const cached=readCache<T>(name,args);if(cached!==undefined){const owner=activeOwnerId,epoch=cacheEpoch;void networkRead<T>(name,args).then(fresh=>{if(owner!==activeOwnerId||epoch!==cacheEpoch)return;writeCache(name,args,fresh);publish(name,args,fresh);if(name==="maths_get_session"&&(fresh as MathsSession)?.sessionId)saveSession(fresh as MathsSession);}).catch(()=>{});return cached;}
    const owner=activeOwnerId,epoch=cacheEpoch;const fresh=await networkRead<T>(name,args);if(owner!==activeOwnerId)throw new Error("Maths account changed while loading. Please retry.");if(epoch===cacheEpoch){writeCache(name,args,fresh);if(name==="maths_get_session"&&(fresh as MathsSession)?.sessionId)saveSession(fresh as MathsSession);}return fresh;
  }
  const owner=activeOwnerId;const out=await networkRpc<T>(name,args);if(owner!==activeOwnerId)throw new Error("Maths account changed while loading. Please retry.");if(startRpc(name)&&(out as MathsSession)?.sessionId)saveSession(out as MathsSession);return out;
}

export async function getMathsSession(sessionId:string):Promise<MathsSession>{
  await ensureOwner();
  if(mathsLocalSafe()&&sessionId.startsWith("local-")){const local=readSavedSession(sessionId);if(local)return local;throw new Error("Local Safe session is no longer available on this device.");}
  const fresh=await mathsRpc<MathsSession>("maths_get_session",{p_session_id:sessionId});const local=readSavedSession(sessionId);if(!local)return fresh;
  const attempts={...(fresh.attempts??{}),...(local.attempts??{})};const questions=fresh.questions.map(q=>{const l=local.questions.find(x=>x.questionId===q.questionId);return l?{...q,starred:l.starred,difficult:l.difficult,mastered:l.mastered,inConcept:l.inConcept}:q;});const merged={...fresh,attempts,questions};saveSession(merged);return merged;
}
export function rememberMathsSession(session:MathsSession){saveSession(session);}
export function subscribeMathsFresh<T>(name:string,args:RpcArgs|undefined,onFresh:(data:T)=>void){if(!browser())return()=>{};const wanted=stableText(args);const fn=(e:Event)=>{const d=(e as CustomEvent<FreshDetail<T>>).detail;if(d?.name===name&&stableText(d.args)===wanted)onFresh(d.data);};window.addEventListener("maths:v2-rpc-fresh",fn);return()=>window.removeEventListener("maths:v2-rpc-fresh",fn);}
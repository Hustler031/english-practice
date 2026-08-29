"use client";

import { supabaseBrowser } from "@/lib/supabase";

type Args=Record<string,unknown>;
type CacheEntry<T=unknown>={at:number;data:T};
type OutboxItem={id:string;args:Args;tries:number;nextAt:number;queuedAt:number};
type FreshDetail<T=unknown>={name:string;args:Args;data:T};
const ROOT="revision:v2:gk:";
const MAX_AGE=12*60*60*1000;
const BACKOFF=[1000,2500,5000,15000,30000,60000];
let running=false;let timer:ReturnType<typeof setTimeout>|null=null;let wired=false;let activeUser="";
const browser=()=>typeof window!=="undefined";
const stable=(a?:Args)=>Object.keys(a||{}).sort().reduce<Args>((o,k)=>(o[k]=(a||{})[k],o),{});
const stableText=(a?:Args)=>JSON.stringify(stable(a));
const cachePrefix=(uid:string)=>`${ROOT}${uid}:rpc-cache:`;
const outboxKey=(uid:string)=>`${ROOT}${uid}:answer-outbox:v1`;
const key=(uid:string,n:string,a?:Args)=>`${cachePrefix(uid)}${n}:${stableText(a)}`;
function cacheable(n:string){return n.startsWith("gk_get_");}
async function userId(){const{data}=await supabaseBrowser().auth.getSession();const uid=data.session?.user?.id||"";if(!uid)throw new Error("Authentication required");activeUser=uid;return uid;}
function publish<T>(name:string,args:Args|undefined,data:T){if(!browser())return;try{window.dispatchEvent(new CustomEvent<FreshDetail<T>>("revision:gk-rpc-fresh",{detail:{name,args:stable(args),data}}));}catch{}}
function readCache<T>(uid:string,name:string,args?:Args){if(!browser())return undefined;try{const raw=localStorage.getItem(key(uid,name,args));if(!raw)return undefined;const e=JSON.parse(raw) as CacheEntry<T>;if(!e||Date.now()-e.at>MAX_AGE)return undefined;return e.data;}catch{return undefined;}}
function writeCache<T>(uid:string,name:string,args:Args|undefined,data:T){if(!browser())return;try{localStorage.setItem(key(uid,name,args),JSON.stringify({at:Date.now(),data}));}catch{}}
async function network<T>(name:string,args?:Args){const{data,error}=await supabaseBrowser().rpc(name,args||{});if(error)throw error;return data as T;}
function readOutbox(uid=activeUser):OutboxItem[]{if(!browser()||!uid)return[];try{const x=JSON.parse(localStorage.getItem(outboxKey(uid))||"[]");return Array.isArray(x)?x:[];}catch{return[];}}
function writeOutbox(uid:string,x:OutboxItem[]){if(!browser()||!uid)return;try{localStorage.setItem(outboxKey(uid),JSON.stringify(x));}catch{}}
function schedule(ms=0){if(!browser())return;if(timer)clearTimeout(timer);timer=setTimeout(()=>void flushGkAnswerOutbox(),Math.max(0,ms));}
export async function flushGkAnswerOutbox(){if(!browser()||running||!navigator.onLine)return;let uid="";try{uid=await userId();}catch{return;}const rows=readOutbox(uid);if(!rows.length)return;const now=Date.now();const item=rows.find(x=>x.nextAt<=now);if(!item){const next=Math.min(...rows.map(x=>x.nextAt||now+60000));schedule(Math.min(60000,Math.max(500,next-now)));return;}running=true;try{try{const result=await network("gk_submit_answer",item.args);writeOutbox(uid,readOutbox(uid).filter(x=>x.id!==item.id));try{window.dispatchEvent(new CustomEvent("revision:gk-answer-durable",{detail:{id:item.id,result}}));}catch{}}catch{const latest=readOutbox(uid);const hit=latest.find(x=>x.id===item.id);if(hit){hit.tries++;hit.nextAt=Date.now()+BACKOFF[Math.min(BACKOFF.length-1,hit.tries-1)];writeOutbox(uid,latest);}}}finally{running=false;if(readOutbox(uid).length)schedule(250);}}
function clearPreviousAccountPrivateState(nextUid:string){if(!browser())return;try{const marker=`${ROOT}active-user`;const previous=localStorage.getItem(marker)||"";if(previous&&previous!==nextUid){for(let i=localStorage.length-1;i>=0;i--){const k=localStorage.key(i);if(k?.startsWith(`${ROOT}${previous}:`))localStorage.removeItem(k);}}localStorage.setItem(marker,nextUid);}catch{}}
function wire(){if(!browser()||wired)return;wired=true;window.addEventListener("online",()=>schedule(0));document.addEventListener("visibilitychange",()=>{if(!document.hidden)schedule(0)});supabaseBrowser().auth.onAuthStateChange((_event,session)=>{const uid=session?.user?.id||"";if(uid){clearPreviousAccountPrivateState(uid);activeUser=uid;schedule(0);}else{activeUser="";}});window.setInterval(()=>{if(readOutbox().length)schedule(0)},60000);schedule(0);}
export async function gkRpc<T=unknown>(name:string,args?:Args):Promise<T>{wire();const uid=await userId();clearPreviousAccountPrivateState(uid);if(name==="gk_submit_answer"){const questionId=String(args?.p_question_id||"").trim();const selected=String(args?.p_selected_option||"").toUpperCase();const attemptId=String(args?.p_attempt_id||"").trim()||`gk-${questionId}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`;const payload={...(args||{}),p_attempt_id:attemptId};if(!questionId||!["A","B","C","D"].includes(selected))return network<T>(name,payload);const rows=readOutbox(uid);if(!rows.some(x=>x.id===attemptId))rows.push({id:attemptId,args:payload,tries:0,nextAt:0,queuedAt:Date.now()});writeOutbox(uid,rows);schedule(0);return {ok:true,queued:true,durable:false,attemptId} as T;}if(cacheable(name)){const cached=readCache<T>(uid,name,args);if(cached!==undefined){void network<T>(name,args).then(fresh=>{writeCache(uid,name,args,fresh);publish(name,args,fresh)}).catch(()=>{});return cached;}const fresh=await network<T>(name,args);writeCache(uid,name,args,fresh);return fresh;}return network<T>(name,args);}
export function subscribeGkFresh<T>(name:string,args:Args|undefined,onFresh:(x:T)=>void){if(!browser())return()=>{};const wanted=stableText(args);const h=(e:Event)=>{const d=(e as CustomEvent<FreshDetail<T>>).detail;if(d?.name===name&&stableText(d.args)===wanted)onFresh(d.data);};window.addEventListener("revision:gk-rpc-fresh",h as EventListener);return()=>window.removeEventListener("revision:gk-rpc-fresh",h as EventListener);}
export function pendingGkAnswers(){return readOutbox().length;}
export function clearGkPrivateCache(){if(!browser())return;try{for(let i=localStorage.length-1;i>=0;i--){const k=localStorage.key(i);if(k?.startsWith(ROOT))localStorage.removeItem(k);}activeUser="";}catch{}}

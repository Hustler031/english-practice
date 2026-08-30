"use client";

import { supabaseBrowser } from "@/lib/supabase";

type Args=Record<string,unknown>;
type CacheEntry<T=unknown>={at:number;data:T};
type OutboxItem={id:string;name:string;args:Args;tries:number;nextAt:number;queuedAt:number};
type FreshDetail<T=unknown>={name:string;args:Args;data:T};

const ROOT="revision:v2:gk:";
const MAX_AGE=12*60*60*1000;
const BACKOFF=[1000,2500,5000,15000,30000,60000];
const DURABLE=new Set(["gk_submit_answer","gk_record_exposure","gk_mark_guessed","gk_set_starred","gk_set_difficult","gk_set_flag","gk_save_note","gk_save_session"]);
const MUTATION=/^gk_(?:submit_|record_|mark_|set_|save_|start_|create_|finish_|complete_)/;
const PAUSED_KEYS=[`${ROOT}paused-session:v3`,`${ROOT}paused-session:v2`,`${ROOT}paused-session:v1`];
let running=false;let timer:ReturnType<typeof setTimeout>|null=null;let wired=false;let activeUser="";

const browser=()=>typeof window!=="undefined";
const stable=(a?:Args)=>Object.keys(a||{}).sort().reduce<Args>((o,k)=>(o[k]=(a||{})[k],o),{});
const stableText=(a?:Args)=>JSON.stringify(stable(a));
const cachePrefix=(uid:string)=>`${ROOT}${uid}:rpc-cache:`;
const outboxKey=(uid:string)=>`${ROOT}${uid}:mutation-outbox:v2`;
const key=(uid:string,n:string,a?:Args)=>`${cachePrefix(uid)}${n}:${stableText(a)}`;
function cacheable(n:string){return n.startsWith("gk_get_");}
function localHost(){if(!browser())return false;return ["localhost","127.0.0.1","::1"].includes(window.location.hostname);}
export function isGkLocalSafe(){return localHost()&&process.env.NEXT_PUBLIC_ALLOW_GK_LOCAL_MUTATIONS!=="true";}
async function userId(){const{data}=await supabaseBrowser().auth.getSession();const uid=data.session?.user?.id||"";if(!uid)throw new Error("Authentication required");activeUser=uid;return uid;}
function publish<T>(name:string,args:Args|undefined,data:T){if(!browser())return;try{window.dispatchEvent(new CustomEvent<FreshDetail<T>>("revision:gk-rpc-fresh",{detail:{name,args:stable(args),data}}));}catch{}}
function publishPending(uid:string){if(!browser())return;try{window.dispatchEvent(new CustomEvent("revision:gk-sync-pending",{detail:{count:readOutbox(uid).length}}));}catch{}}
function readCache<T>(uid:string,name:string,args?:Args){if(!browser())return undefined;try{const raw=localStorage.getItem(key(uid,name,args));if(!raw)return undefined;const e=JSON.parse(raw) as CacheEntry<T>;if(!e||Date.now()-e.at>MAX_AGE)return undefined;return e.data;}catch{return undefined;}}
function writeCache<T>(uid:string,name:string,args:Args|undefined,data:T){if(!browser())return;try{localStorage.setItem(key(uid,name,args),JSON.stringify({at:Date.now(),data}));}catch{}}
async function network<T>(name:string,args?:Args){const{data,error}=await supabaseBrowser().rpc(name,args||{});if(error)throw error;return data as T;}
function readOutbox(uid=activeUser):OutboxItem[]{if(!browser()||!uid)return[];try{const x=JSON.parse(localStorage.getItem(outboxKey(uid))||"[]");return Array.isArray(x)?x:[];}catch{return[];}}
function writeOutbox(uid:string,x:OutboxItem[]){if(!browser()||!uid)return;try{localStorage.setItem(outboxKey(uid),JSON.stringify(x));publishPending(uid);}catch{}}
function clearGlobalPaused(){if(!browser())return;try{PAUSED_KEYS.forEach(k=>localStorage.removeItem(k));}catch{}}
function removeUserPrivateState(uid:string){if(!browser()||!uid)return;try{for(let i=localStorage.length-1;i>=0;i--){const k=localStorage.key(i);if(k?.startsWith(`${ROOT}${uid}:`))localStorage.removeItem(k);}}catch{}}
function schedule(ms=0){if(!browser()||isGkLocalSafe())return;if(timer)clearTimeout(timer);timer=setTimeout(()=>void flushGkMutationOutbox(),Math.max(0,ms));}
function makeId(prefix:string){return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2,9)}`;}
function prepareDurable(name:string,input?:Args){const args={...(input||{})};let id="";
 if(name==="gk_submit_answer"){id=String(args.p_attempt_id||"").trim()||makeId(`gk-${String(args.p_question_id||"Q")}`);args.p_attempt_id=id;}
 else if(name==="gk_record_exposure"){id=String(args.p_exposure_id||"").trim()||makeId("gk-exp");args.p_exposure_id=id;}
 else if(name==="gk_mark_guessed"){id=String(args.p_mutation_id||"").trim()||makeId("gk-guess");args.p_mutation_id=id;}
 else id=makeId(name);
 return{id,args};
}
function localSimulation<T>(name:string,args?:Args):T{const a=args||{};const result:Record<string,unknown>={ok:true,localSafe:true,durable:false,simulated:true};
 if(name==="gk_submit_answer"){result.attemptId=String(a.p_attempt_id||makeId("gk-local-answer"));result.queued=false;}
 if(name==="gk_record_exposure")result.exposureId=String(a.p_exposure_id||makeId("gk-local-exp"));
 if(name==="gk_mark_guessed"){result.attemptId=a.p_attempt_id;result.guessed=a.p_guessed!==false;}
 return result as T;}

export async function flushGkMutationOutbox(){if(!browser()||running||!navigator.onLine||isGkLocalSafe())return;let uid="";try{uid=await userId();}catch{return;}const rows=readOutbox(uid).slice().sort((a,b)=>a.queuedAt-b.queuedAt);if(!rows.length)return;const item=rows[0];const now=Date.now();if(item.nextAt>now){schedule(Math.min(60000,Math.max(500,item.nextAt-now)));return;}running=true;try{try{const result=await network(item.name,item.args);writeOutbox(uid,readOutbox(uid).filter(x=>x.id!==item.id));try{window.dispatchEvent(new CustomEvent("revision:gk-mutation-durable",{detail:{id:item.id,name:item.name,result}}));}catch{}invalidateReadCache(uid);}catch{const latest=readOutbox(uid);const hit=latest.find(x=>x.id===item.id);if(hit){hit.tries++;hit.nextAt=Date.now()+BACKOFF[Math.min(BACKOFF.length-1,hit.tries-1)];writeOutbox(uid,latest);}}}finally{running=false;if(readOutbox(uid).length)schedule(250);}}
function invalidateReadCache(uid:string){if(!browser()||!uid)return;try{for(let i=localStorage.length-1;i>=0;i--){const k=localStorage.key(i);if(k?.startsWith(cachePrefix(uid)))localStorage.removeItem(k);}}catch{}}
function clearPreviousAccountPrivateState(nextUid:string){if(!browser())return;try{const marker=`${ROOT}active-user`;const previous=localStorage.getItem(marker)||"";if(previous&&previous!==nextUid){removeUserPrivateState(previous);clearGlobalPaused();}localStorage.setItem(marker,nextUid);}catch{}}
function clearSignedOutPrivateState(){if(!browser())return;try{const marker=`${ROOT}active-user`;const previous=activeUser||localStorage.getItem(marker)||"";if(previous)removeUserPrivateState(previous);clearGlobalPaused();localStorage.removeItem(marker);activeUser="";}catch{activeUser="";}}
function wire(){if(!browser()||wired)return;wired=true;window.addEventListener("online",()=>schedule(0));document.addEventListener("visibilitychange",()=>{if(!document.hidden)schedule(0)});supabaseBrowser().auth.onAuthStateChange((_event,session)=>{const uid=session?.user?.id||"";if(uid){clearPreviousAccountPrivateState(uid);activeUser=uid;schedule(0);}else clearSignedOutPrivateState();});window.setInterval(()=>{if(readOutbox().length)schedule(0)},60000);schedule(0);}

export async function gkRpc<T=unknown>(name:string,args?:Args):Promise<T>{wire();const uid=await userId();clearPreviousAccountPrivateState(uid);
 if(MUTATION.test(name)&&isGkLocalSafe())return localSimulation<T>(name,args);
 if(DURABLE.has(name)){
   const prepared=prepareDurable(name,args);const rows=readOutbox(uid);
   if(!rows.some(x=>x.id===prepared.id))rows.push({id:prepared.id,name,args:prepared.args,tries:0,nextAt:0,queuedAt:Date.now()});
   writeOutbox(uid,rows);schedule(0);
   return {ok:true,queued:true,durable:false,id:prepared.id,attemptId:name==="gk_submit_answer"?prepared.id:String(prepared.args.p_attempt_id||"")} as T;
 }
 if(cacheable(name)){const cached=readCache<T>(uid,name,args);if(cached!==undefined){void network<T>(name,args).then(fresh=>{writeCache(uid,name,args,fresh);publish(name,args,fresh)}).catch(()=>{});return cached;}const fresh=await network<T>(name,args);writeCache(uid,name,args,fresh);return fresh;}
 const result=await network<T>(name,args);if(MUTATION.test(name))invalidateReadCache(uid);return result;
}

export function subscribeGkFresh<T>(name:string,args:Args|undefined,onFresh:(x:T)=>void){if(!browser())return()=>{};const wanted=stableText(args);const h=(e:Event)=>{const d=(e as CustomEvent<FreshDetail<T>>).detail;if(d?.name===name&&stableText(d.args)===wanted)onFresh(d.data);};window.addEventListener("revision:gk-rpc-fresh",h as EventListener);return()=>window.removeEventListener("revision:gk-rpc-fresh",h as EventListener);}
export function pendingGkMutations(){return readOutbox().length;}
export function pendingGkAnswers(){return readOutbox().filter(x=>x.name==="gk_submit_answer").length;}
export function clearGkPrivateCache(){if(!browser())return;try{for(let i=localStorage.length-1;i>=0;i--){const k=localStorage.key(i);if(k?.startsWith(ROOT)&&k.includes(":rpc-cache:"))localStorage.removeItem(k);}}catch{}}

"use client";

import { supabaseBrowser } from "@/lib/supabase";
import type { GkQuestion } from "@/lib/gk-types";

type SessionRow={lane:string;ids:string[];at:number};
type Args=Record<string,unknown>;

const ROOT="revision:v2:gk:fresh-session-history:v2";
const TTL=7*24*60*60*1000;
const MAX_ROWS=40;
const MAX_RECENT_SESSIONS=6;
const MAX_EXCLUDE=500;

function browser(){return typeof window!=="undefined";}
async function ownerKey(){if(!browser())return "";try{const{data}=await supabaseBrowser().auth.getSession();const uid=data.session?.user?.id||"";return uid?`${ROOT}:${uid}`:"";}catch{return "";}}
function clean(rows:unknown):SessionRow[]{if(!Array.isArray(rows))return[];const cutoff=Date.now()-TTL;return rows.filter((x):x is SessionRow=>!!x&&typeof x==="object"&&typeof (x as SessionRow).lane==="string"&&Array.isArray((x as SessionRow).ids)&&Number((x as SessionRow).at||0)>=cutoff).slice(0,MAX_ROWS);}
function read(key:string){if(!browser()||!key)return[];try{return clean(JSON.parse(localStorage.getItem(key)||"[]"));}catch{return[];}}
function write(key:string,rows:SessionRow[]){if(!browser()||!key)return;try{localStorage.setItem(key,JSON.stringify(rows.slice(0,MAX_ROWS)));}catch{}}
function stableArgs(args:Args){const out:Args={};Object.keys(args).filter(k=>k!=="p_count").sort().forEach(k=>{out[k]=args[k]});return out;}
function ids(rows:GkQuestion[]){return [...new Set((rows||[]).map(x=>String(x?.id||"").trim()).filter(Boolean))];}
function recentIds(key:string,lane:string){return [...new Set(read(key).filter(x=>x.lane===lane).slice(0,MAX_RECENT_SESSIONS).flatMap(x=>x.ids))].slice(0,MAX_EXCLUDE);}
function strictMode(mode:string){return ["new","unseen","new_v2","new_random"].includes(String(mode||"").toLowerCase());}

export function gkFreshLane(name:string,args:Args){return `${name}:${JSON.stringify(stableArgs(args))}`;}

export async function loadFreshGkQuestions({name,args,requested,load}:{name:string;args:Args;requested:number;load:(expandedCount:number)=>Promise<GkQuestion[]>}){
 const key=await ownerKey();
 const n=Math.max(1,Math.min(1000,Number(requested||20)));
 const lane=gkFreshLane(name,args),excluded=recentIds(key,lane),excludedSet=new Set(excluded);
 const expanded=Math.max(n,Math.min(1000,n+excluded.length));
 const rows=await load(expanded);
 const fresh=rows.filter(x=>!excludedSet.has(String(x.id||""))),old=rows.filter(x=>excludedSet.has(String(x.id||"")));
 const selected=(strictMode(String(args.p_mode||""))?fresh:[...fresh,...old]).slice(0,n);
 const chosen=selected.length?selected:strictMode(String(args.p_mode||""))?[]:rows.slice(0,n);
 const chosenIds=ids(chosen);
 if(key&&chosenIds.length)write(key,[{lane,ids:chosenIds,at:Date.now()},...read(key)]);
 return chosen;
}

export async function clearGkFreshSessionHistory(){const key=await ownerKey();if(!browser()||!key)return;try{localStorage.removeItem(key);}catch{}}

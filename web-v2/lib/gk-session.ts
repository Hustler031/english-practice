"use client";

import type { GkLane } from "@/lib/gk-types";

export type GkPausedAnswer = { selected:string; displaySelected?:string; correct:boolean; correctKey:string; attemptId?:string; guessed?:boolean };
export type GkPausedSession = {
  sessionId:string;
  title:string;
  lane:GkLane;
  mode:string;
  index:number;
  questions:unknown[];
  answers:Record<string,GkPausedAnswer>;
  optionOrders?:Record<string,string[]>;
  query:string;
  savedAt:number;
};

const KEY="revision:v2:gk:paused-session:v3";
const LEGACY_V2="revision:v2:gk:paused-session:v2";
const LEGACY_V1="revision:v2:gk:paused-session:v1";
const HARD_REFRESH_KEY="revision:v2:gk:hard-refresh-intent:v1";

export function normalizeGkQuizQuery(search:string){
  const params=new URLSearchParams(String(search||""));
  params.delete("resume");
  params.delete("remoteResume");
  params.delete("_refresh");
  params.sort();
  return params.toString();
}

export function canAutoRestoreGkPaused(value:GkPausedSession|null,currentSearch:string,reloadIntent:boolean){
  if(!reloadIntent||!value)return false;
  return normalizeGkQuizQuery(value.query)===normalizeGkQuizQuery(currentSearch);
}

export function markGkHardRefreshIntent(){
  if(typeof window==="undefined")return;
  try{window.sessionStorage.setItem(HARD_REFRESH_KEY,JSON.stringify({path:window.location.pathname,at:Date.now()}));}catch{}
}

export function consumeGkReloadIntent(){
  if(typeof window==="undefined")return false;
  let explicit=false;
  try{
    const raw=window.sessionStorage.getItem(HARD_REFRESH_KEY);
    window.sessionStorage.removeItem(HARD_REFRESH_KEY);
    const x=raw?JSON.parse(raw):null;
    explicit=!!x&&x.path===window.location.pathname&&Number.isFinite(Number(x.at))&&Date.now()-Number(x.at)<60_000;
  }catch{}
  try{
    const nav=window.performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming|undefined;
    return explicit||nav?.type==="reload";
  }catch{return explicit;}
}

function validPaused(x:unknown):x is GkPausedSession{
  if(!x||typeof x!=="object")return false;
  const v=x as Partial<GkPausedSession>;
  if(typeof v.sessionId!=="string"||!v.sessionId.trim())return false;
  if(typeof v.title!=="string"||typeof v.mode!=="string"||typeof v.query!=="string")return false;
  if(!["MAIN","RAPID","MIXED"].includes(String(v.lane||"")))return false;
  if(!Number.isInteger(v.index)||Number(v.index)<0||!Number.isFinite(Number(v.savedAt)))return false;
  if(!Array.isArray(v.questions)||!v.questions.length)return false;
  if(!v.answers||typeof v.answers!=="object"||Array.isArray(v.answers))return false;
  return v.questions.every(q=>{
    if(!q||typeof q!=="object")return false;
    const row=q as {id?:unknown;question?:unknown;options?:unknown};
    return typeof row.id==="string"&&!!row.id&&typeof row.question==="string"&&Array.isArray(row.options);
  });
}

export function readGkPaused():GkPausedSession|null{
  if(typeof window==="undefined")return null;
  try{
    const raw=window.localStorage.getItem(KEY)||window.localStorage.getItem(LEGACY_V2)||window.localStorage.getItem(LEGACY_V1);
    const x=raw?JSON.parse(raw):null;
    if(!validPaused(x))return null;
    return {...x,index:Math.min(x.index,Math.max(0,x.questions.length-1))};
  }catch{return null;}
}

export function saveGkPaused(value:GkPausedSession){
  if(typeof window==="undefined")return;
  try{
    window.localStorage.setItem(KEY,JSON.stringify(value));
    window.localStorage.removeItem(LEGACY_V2);
    window.localStorage.removeItem(LEGACY_V1);
  }catch{}
}

export function clearGkPaused(){
  if(typeof window==="undefined")return;
  try{
    window.localStorage.removeItem(KEY);
    window.localStorage.removeItem(LEGACY_V2);
    window.localStorage.removeItem(LEGACY_V1);
  }catch{}
}

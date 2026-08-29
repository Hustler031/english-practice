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

const KEY="revision:v2:gk:paused-session:v2";
const LEGACY="revision:v2:gk:paused-session:v1";

export function readGkPaused():GkPausedSession|null{
  if(typeof window==="undefined")return null;
  try{
    const raw=window.localStorage.getItem(KEY)||window.localStorage.getItem(LEGACY);
    const x=raw?JSON.parse(raw):null;
    if(!x||!Array.isArray(x.questions)||!x.questions.length)return null;
    return {...x,sessionId:String(x.sessionId||`gk-local-${x.savedAt||Date.now()}`),lane:(x.lane||"MIXED") as GkLane};
  }catch{return null;}
}
export function saveGkPaused(value:GkPausedSession){if(typeof window==="undefined")return;try{window.localStorage.setItem(KEY,JSON.stringify(value));window.localStorage.removeItem(LEGACY);}catch{}}
export function clearGkPaused(){if(typeof window==="undefined")return;try{window.localStorage.removeItem(KEY);window.localStorage.removeItem(LEGACY);}catch{}}

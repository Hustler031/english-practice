"use client";

export type GkPausedAnswer = { selected:string; correct:boolean; correctKey:string };
export type GkPausedSession = {
  title:string;
  lane:"MAIN"|"RAPID";
  mode:string;
  index:number;
  questions:unknown[];
  answers:Record<string,GkPausedAnswer>;
  query:string;
  savedAt:number;
};

const KEY="revision:v2:gk:paused-session:v1";

export function readGkPaused():GkPausedSession|null{
  if(typeof window==="undefined")return null;
  try{const raw=window.localStorage.getItem(KEY);const x=raw?JSON.parse(raw):null;return x&&Array.isArray(x.questions)&&x.questions.length?x:null;}catch{return null;}
}
export function saveGkPaused(value:GkPausedSession){if(typeof window==="undefined")return;try{window.localStorage.setItem(KEY,JSON.stringify(value));}catch{}}
export function clearGkPaused(){if(typeof window==="undefined")return;try{window.localStorage.removeItem(KEY);}catch{}}

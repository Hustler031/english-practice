"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { failedMathsWrites, invalidateMathsCaches, mathsLocalSafe, pendingMathsWrites } from "@/lib/maths-rpc";

type Tab="home"|"chapters"|"library"|"ondemand"|"progress";
type Theme="dark"|"light";
type JumpState={total:number;current:number;statuses:string[]};
const tabs:{id:Tab;href:string;icon:string;label:string}[]=[
  {id:"home",href:"/maths",icon:"⌂",label:"Home"},
  {id:"chapters",href:"/maths/chapters",icon:"▤",label:"Chapters"},
  {id:"library",href:"/maths/library",icon:"▦",label:"Library"},
  {id:"ondemand",href:"/maths/ondemand",icon:"◆",label:"On Demand"},
  {id:"progress",href:"/maths/progress",icon:"▥",label:"Progress"},
];
function activeTab(path:string):Tab{if(path==="/maths"||/\/maths\/(session|resume|new|starred|exam)(?:\/|$)/.test(path))return"home";if(path.startsWith("/maths/chapters"))return"chapters";if(path.startsWith("/maths/library"))return"library";if(/\/maths\/(ondemand|mocks|formulas|calculation|concepts|demand)(?:\/|$)/.test(path))return"ondemand";return"progress";}
function applyTheme(theme:Theme,persist=false){document.documentElement.dataset.theme=theme;document.documentElement.style.colorScheme=theme;if(persist)localStorage.setItem("maths-theme",theme);}
function timerText(seconds:number){const m=Math.floor(seconds/60),s=seconds%60;return `${m}:${String(s).padStart(2,"0")}`;}
function readJumpState():JumpState|null{
  const select=document.querySelector<HTMLSelectElement>(".m-quiz-shell .m-jump");
  if(!select)return null;
  const total=select.options.length;
  const current=Math.max(0,Math.min(Number(select.value)||0,Math.max(0,total-1)));
  const statuses=Array.from({length:total},()=>"");
  try{
    const id=new URLSearchParams(window.location.search).get("id");
    const raw=id?localStorage.getItem(`maths:v2:session:${id}`):null;
    const session=raw?JSON.parse(raw) as {questions?:{questionId?:string}[];attempts?:Record<string,{result?:string}>}:null;
    (session?.questions??[]).slice(0,total).forEach((q,i)=>{statuses[i]=String(session?.attempts?.[String(q.questionId??"")]?.result??"");});
  }catch{}
  return {total,current,statuses};
}
function triggerNativeSelect(select:HTMLSelectElement,value:string){
  const setter=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,"value")?.set;
  if(setter)setter.call(select,value);else select.value=value;
  select.dispatchEvent(new Event("change",{bubbles:true}));
}

export function MathsFrame({children}:{children:ReactNode}){
  const path=usePathname();const router=useRouter();const active=useMemo(()=>activeTab(path),[path]);
  const examRoute=/^\/maths\/exam(?:\/|$)/.test(path);
  const examSessionMode=/^\/maths\/exam\/session(?:\/|$)/.test(path);
  const legacyQuizMode=/^\/maths\/session(?:\/|$)/.test(path);
  const quizMode=legacyQuizMode||examSessionMode;
  const[theme,setTheme]=useState<Theme>("dark");const[pending,setPending]=useState(0);const[failed,setFailed]=useState(0);const[refreshing,setRefreshing]=useState(false);const[safe,setSafe]=useState(false);const[timerVisible,setTimerVisible]=useState(false);const[timerSeconds,setTimerSeconds]=useState(0);const[jump,setJump]=useState<JumpState|null>(null);const questionStartedAt=useRef(Date.now());
  function resetQuestionTimer(){questionStartedAt.current=Date.now();setTimerSeconds(0);}
  useEffect(()=>{const saved=localStorage.getItem("maths-theme");const next:Theme=saved==="light"?"light":"dark";setTheme(next);applyTheme(next);setSafe(mathsLocalSafe());const sync=()=>{setPending(pendingMathsWrites());setFailed(failedMathsWrites());};sync();const t=setInterval(sync,700);window.addEventListener("maths:v2-sync-change",sync);window.addEventListener("maths:v2-write-durable",sync);window.addEventListener("maths:v2-owner-change",sync);return()=>{clearInterval(t);window.removeEventListener("maths:v2-sync-change",sync);window.removeEventListener("maths:v2-write-durable",sync);window.removeEventListener("maths:v2-owner-change",sync);};},[]);
  useEffect(()=>{if(path!=="/maths")return;window.history.pushState({...window.history.state,mathsHomeGuard:true},"",window.location.href);const back=()=>router.replace("/");window.addEventListener("popstate",back);return()=>window.removeEventListener("popstate",back);},[path,router]);
  useEffect(()=>{setTimerVisible(false);resetQuestionTimer();setJump(null);},[path]);
  useEffect(()=>{
    if(!legacyQuizMode)return;
    let cancelled=false;let raf=0;let timer=0;
    const tick=()=>setTimerSeconds(Math.max(0,Math.floor((Date.now()-questionStartedAt.current)/1000)));
    const arm=()=>{if(cancelled)return;if(!document.querySelector(".m-quiz-shell .m-question-card")){raf=window.requestAnimationFrame(arm);return;}resetQuestionTimer();tick();timer=window.setInterval(tick,250);};
    arm();
    return()=>{cancelled=true;if(raf)window.cancelAnimationFrame(raf);if(timer)window.clearInterval(timer);};
  },[legacyQuizMode,path]);
  useEffect(()=>{
    if(!legacyQuizMode)return;
    const main=document.querySelector(".maths-content");
    const click=(ev:Event)=>{
      const target=ev.target as HTMLElement|null;
      if(target?.closest(".m-quiz-head .m-quiz-head-top>span")){const state=readJumpState();if(state){ev.preventDefault();setJump(state);}return;}
      const nav=target?.closest<HTMLButtonElement>(".m-nav-dock button");
      if(nav&&!nav.disabled&&/previous|next/i.test(nav.textContent||""))resetQuestionTimer();
    };
    const key=(ev:KeyboardEvent)=>{if(ev.key==="Escape")setJump(null);};
    main?.addEventListener("click",click);document.addEventListener("keydown",key);
    return()=>{main?.removeEventListener("click",click);document.removeEventListener("keydown",key);};
  },[legacyQuizMode,path]);
  useEffect(()=>{
    if(path!=="/maths/mocks")return;
    const main=document.querySelector<HTMLElement>(".maths-content");if(!main)return;
    const wire=()=>{
      if(new URLSearchParams(window.location.search).has("chapter"))return;
      const head=Array.from(main.querySelectorAll<HTMLElement>(".m-section-title")).find(x=>x.textContent?.trim()==="By Chapter");
      const list=head?.nextElementSibling as HTMLElement|null;
      if(!head||!list?.classList.contains("m-list")||head.dataset.mockCollapseWired==="1")return;
      head.dataset.mockCollapseWired="1";head.dataset.mockOpen="false";head.classList.add("m-mock-break-head");head.setAttribute("role","button");head.setAttribute("tabindex","0");head.setAttribute("aria-expanded","false");list.classList.add("m-mock-chapter-list");
      const toggle=()=>{const open=head.dataset.mockOpen!=="true";head.dataset.mockOpen=String(open);head.setAttribute("aria-expanded",String(open));list.classList.toggle("open",open);};
      head.onclick=toggle;head.onkeydown=(ev:KeyboardEvent)=>{if(ev.key==="Enter"||ev.key===" "){ev.preventDefault();toggle();}};
    };
    wire();const observer=new MutationObserver(wire);observer.observe(main,{childList:true,subtree:true});return()=>observer.disconnect();
  },[path]);
  function toggle(){const next:Theme=theme==="dark"?"light":"dark";setTheme(next);applyTheme(next,true);}
  async function refresh(){if(refreshing)return;setRefreshing(true);invalidateMathsCaches();try{if("caches"in window){const names=await caches.keys();await Promise.allSettled(names.map(x=>caches.delete(x)));}}catch{}const u=new URL(location.href);u.searchParams.set("_refresh",Date.now().toString());location.replace(u.toString());}
  function jumpTo(index:number){const select=document.querySelector<HTMLSelectElement>(".m-quiz-shell .m-jump");if(!select)return;resetQuestionTimer();triggerNativeSelect(select,String(index));setJump(null);window.scrollTo({top:0,behavior:"auto"});}
  const shellClass=`maths-app${quizMode?" maths-quiz-mode":""}${examRoute?" maths-exam-route":""}${examSessionMode?" maths-exam-session":""}`;
  return <div className={shellClass}><header className="maths-header"><Link href="/maths" className="maths-brand"><strong>Maths Revision</strong><span>SSC formula + method recall</span></Link><div className="maths-header-actions">{!quizMode&&safe&&<span className="maths-pill">Local Safe</span>}{!quizMode&&pending>0&&<span className={`maths-pill syncing ${failed?"retrying":""}`}><i/>{failed?`Sync retrying ${failed}`:`Syncing ${pending}`}</span>}{legacyQuizMode&&<button className={`maths-icon-btn maths-timer-btn ${timerVisible?"maths-timer-on":""}`} type="button" onClick={()=>setTimerVisible(v=>!v)} aria-pressed={timerVisible} title={timerVisible?"Hide question time":"Show question time"}>⏱ {timerVisible?timerText(timerSeconds):"Timer"}</button>}{!quizMode&&<Link className="maths-icon-btn" href="/" aria-label="Revision launcher" title="Revision launcher">⌂</Link>}<button className="maths-icon-btn" type="button" onClick={toggle} aria-label="Toggle theme">{theme==="dark"?"◐":"◑"}</button><button className={`maths-icon-btn ${refreshing?"spin":""}`} type="button" onClick={()=>void refresh()} aria-label="Refresh Maths" disabled={refreshing}>↻</button></div></header><main className="maths-content">{children}</main>{!quizMode&&<nav className="maths-nav" aria-label="Maths navigation">{tabs.map(t=><Link key={t.id} href={t.href} className={`maths-nav-item ${active===t.id?"active":""}`} aria-current={active===t.id?"page":undefined}><b>{t.icon}</b><span>{t.label}</span></Link>)}</nav>}{legacyQuizMode&&jump&&<div className="m-old-jump-backdrop" role="dialog" aria-modal="true" aria-label="Jump to question" onMouseDown={e=>{if(e.target===e.currentTarget)setJump(null);}}><section className="m-old-jump-sheet"><div className="m-old-jump-head"><div className="m-old-jump-copy"><small>Question selector</small><strong>Jump to question</strong></div><button className="m-old-jump-close" type="button" aria-label="Close question selector" onClick={()=>setJump(null)}>×</button></div><div className="m-old-jump-grid">{Array.from({length:jump.total},(_,i)=>{const status=jump.statuses[i];const state=status==="correct"?"qj-correct":status==="wrong"?"qj-wrong":status?"qj-seen":"";return <button key={i} type="button" className={`m-old-jump-q ${state} ${i===jump.current?"qj-current":""}`} onClick={()=>jumpTo(i)}>{i+1}</button>;})}</div></section></div>}</div>;
}
export function MathsLoading({text="Loading Maths…"}:{text?:string}){return <div className="maths-loading"><i/><i/><i/><span>{text}</span></div>}

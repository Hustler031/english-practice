"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ReactNode, useEffect, useMemo, useState } from "react";
import { invalidateMathsCaches, mathsLocalSafe, pendingMathsWrites } from "@/lib/maths-rpc";

type Tab="home"|"chapters"|"library"|"ondemand"|"progress";
type Theme="dark"|"light";
const tabs:{id:Tab;href:string;icon:string;label:string}[]=[
  {id:"home",href:"/maths",icon:"⌂",label:"Home"},
  {id:"chapters",href:"/maths/chapters",icon:"▤",label:"Chapters"},
  {id:"library",href:"/maths/library",icon:"▦",label:"Library"},
  {id:"ondemand",href:"/maths/ondemand",icon:"◆",label:"On Demand"},
  {id:"progress",href:"/maths/progress",icon:"▥",label:"Progress"},
];
function activeTab(path:string):Tab{if(path==="/maths"||/\/maths\/(session|resume|new|starred)(?:\/|$)/.test(path))return"home";if(path.startsWith("/maths/chapters"))return"chapters";if(path.startsWith("/maths/library"))return"library";if(/\/maths\/(ondemand|mocks|formulas|calculation|concepts|demand)(?:\/|$)/.test(path))return"ondemand";return"progress";}
function applyTheme(theme:Theme,persist=false){document.documentElement.dataset.theme=theme;document.documentElement.style.colorScheme=theme;if(persist)localStorage.setItem("maths-theme",theme);}

export function MathsFrame({children}:{children:ReactNode}){
  const path=usePathname();const router=useRouter();const active=useMemo(()=>activeTab(path),[path]);
  const[theme,setTheme]=useState<Theme>("dark");const[pending,setPending]=useState(0);const[refreshing,setRefreshing]=useState(false);const[safe,setSafe]=useState(false);
  useEffect(()=>{const saved=localStorage.getItem("maths-theme");const next:Theme=saved==="light"?"light":"dark";setTheme(next);applyTheme(next);setSafe(mathsLocalSafe());const sync=()=>setPending(pendingMathsWrites());sync();const t=setInterval(sync,700);window.addEventListener("maths:v2-sync-change",sync);window.addEventListener("maths:v2-answer-durable",sync);return()=>{clearInterval(t);window.removeEventListener("maths:v2-sync-change",sync);window.removeEventListener("maths:v2-answer-durable",sync);};},[]);
  useEffect(()=>{if(path!=="/maths")return;window.history.pushState({...window.history.state,mathsHomeGuard:true},"",window.location.href);const back=()=>router.replace("/");window.addEventListener("popstate",back);return()=>window.removeEventListener("popstate",back);},[path,router]);
  function toggle(){const next:Theme=theme==="dark"?"light":"dark";setTheme(next);applyTheme(next,true);}
  async function refresh(){if(refreshing)return;setRefreshing(true);invalidateMathsCaches();try{if("caches"in window){const names=await caches.keys();await Promise.allSettled(names.map(x=>caches.delete(x)));}}catch{}const u=new URL(location.href);u.searchParams.set("_refresh",Date.now().toString());location.replace(u.toString());}
  return <div className="maths-app"><header className="maths-header"><Link href="/maths" className="maths-brand"><strong>Maths Revision</strong><span>SSC formula + method recall</span></Link><div className="maths-header-actions">{safe&&<span className="maths-pill">Local Safe</span>}{pending>0&&<span className="maths-pill syncing"><i/>Syncing {pending}</span>}<Link className="maths-icon-btn" href="/" aria-label="Revision launcher" title="Revision launcher">⌂</Link><button className="maths-icon-btn" type="button" onClick={toggle} aria-label="Toggle theme">{theme==="dark"?"◐":"◑"}</button><button className={`maths-icon-btn ${refreshing?"spin":""}`} type="button" onClick={()=>void refresh()} aria-label="Refresh Maths" disabled={refreshing}>↻</button></div></header><main className="maths-content">{children}</main><nav className="maths-nav" aria-label="Maths navigation">{tabs.map(t=><Link key={t.id} href={t.href} className={`maths-nav-item ${active===t.id?"active":""}`} aria-current={active===t.id?"page":undefined}><b>{t.icon}</b><span>{t.label}</span></Link>)}</nav></div>;
}
export function MathsLoading({text="Loading Maths…"}:{text?:string}){return <div className="maths-loading"><i/><i/><i/><span>{text}</span></div>}

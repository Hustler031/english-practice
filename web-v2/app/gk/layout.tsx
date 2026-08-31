"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { MouseEvent, ReactNode } from "react";
import { useEffect, useState } from "react";
import { clearGkPrivateCache, isGkLocalSafe } from "@/lib/gk-rpc";
import { markGkHardRefreshIntent } from "@/lib/gk-session";
import "./gk-home-english-parity.css";
import "./gk-shell-polish.css";
import "./gk-final-intelligence.css";
import "./gk-final-intelligence-mobile.css";
import "./gk-lively-polish.css";

type Theme="dark"|"light";
function applyTheme(next:Theme,persist=false){document.documentElement.dataset.theme=next;document.documentElement.style.colorScheme=next;const color=next==="light"?"#f5f7fb":"#0d1117";document.querySelectorAll('meta[name="theme-color"]').forEach(el=>el.setAttribute("content",color));if(persist)window.localStorage.setItem("english-theme",next);}

export default function GkLayout({ children }: { children: ReactNode }) {
 const pathname=usePathname();
 const[theme,setTheme]=useState<Theme>("dark"),[refreshing,setRefreshing]=useState(false),[localSafe,setLocalSafe]=useState(false);
 useEffect(()=>{const saved=window.localStorage.getItem("english-theme");const next:Theme=saved==="light"?"light":"dark";setTheme(next);applyTheme(next);setLocalSafe(isGkLocalSafe());},[]);
 useEffect(()=>{if(pathname!=="/gk")return;const p=new URLSearchParams(window.location.search);if(p.get("tab")==="progress")window.location.replace("/gk/intelligence");},[pathname]);
 function toggleTheme(){const next:Theme=theme==="dark"?"light":"dark";setTheme(next);applyTheme(next,true);}
 async function hardRefresh(){if(refreshing)return;setRefreshing(true);markGkHardRefreshIntent();clearGkPrivateCache();try{if("caches" in window){const names=await window.caches.keys();await Promise.allSettled(names.map(name=>window.caches.delete(name)));}}catch{}const target=new URL(window.location.href);target.searchParams.set("_refresh",Date.now().toString());window.location.replace(target.toString());}
 function forceSamePageNavigation(event: MouseEvent<HTMLDivElement>) {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const target = event.target as Element | null;
  const anchor = target?.closest("a");
  if (!anchor) return;
  const href = anchor.getAttribute("href");
  if (!href || href.startsWith("#")) return;
  const url = new URL(href, window.location.href);
  if(url.origin===window.location.origin&&url.pathname==="/gk"&&url.searchParams.get("tab")==="progress"){
   event.preventDefault();event.stopPropagation();window.location.assign("/gk/intelligence");return;
  }
  if (url.origin !== window.location.origin || url.pathname !== "/gk" || !url.searchParams.has("tab")) return;
  event.preventDefault();event.stopPropagation();window.location.assign(`${url.pathname}${url.search}${url.hash}`);
 }
 const quizRoute=pathname?.startsWith("/gk/quiz");
 return <div className="gk-app-shell gk-parity-scope" onClickCapture={forceSamePageNavigation}>
  <header className="gk-shell-header">
   <Link href="/gk?tab=home" className="gk-shell-brand" aria-label="GK Mastery home"><strong>GK Mastery</strong><span>SSC GK practice + revision</span></Link>
   <div className="gk-shell-controls">
    {localSafe&&<span className="gk-shell-safe">Local Safe</span>}
    {!quizRoute&&<Link href="/gk/teacher" className="gk-shell-intelligence">Teacher PYQ</Link>}
    {!quizRoute&&<Link href="/gk/intelligence" className="gk-shell-intelligence">Progress</Link>}
    {!quizRoute&&<Link href="/gk/sprint" className="gk-shell-intelligence">Sprint</Link>}
    <Link href="/" className="gk-shell-control" aria-label="Revision root" title="Revision root">⌂</Link>
    <button className="gk-shell-control" type="button" aria-label={theme==="dark"?"Switch to light mode":"Switch to dark mode"} onClick={toggleTheme}>{theme==="dark"?"☀":"☾"}</button>
    <button className={`gk-shell-control ${refreshing?"is-refreshing":""}`} type="button" aria-label="Hard refresh GK" title="Hard refresh" onClick={()=>void hardRefresh()} disabled={refreshing}>↻</button>
   </div>
  </header>
  <div className="gk-shell-body">
   {quizRoute&&<div className="gk-quiz-backbar"><button className="gk-english-back" type="button" onClick={()=>window.history.back()}>← Back</button></div>}
   {children}
  </div>
 </div>;
}

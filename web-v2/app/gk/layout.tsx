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
import "./gk-navigation-structure.css";
import "./gk-practice-hierarchy.css";

type Theme="dark"|"light";
type ShellTab="home"|"content"|"practice"|"demand"|"progress"|null;
const NAV:Array<[Exclude<ShellTab,null>,string,string,string]>=[
 ["home","⌂","Home","/gk?tab=home"],
 ["content","▤","Content","/gk?tab=content"],
 ["practice","◎","Practice","/gk?tab=practice"],
 ["progress","▥","Progress","/gk/intelligence"]
];
function applyTheme(next:Theme,persist=false){document.documentElement.dataset.theme=next;document.documentElement.style.colorScheme=next;const color=next==="light"?"#f5f7fb":"#0d1117";document.querySelectorAll('meta[name="theme-color"]').forEach(el=>el.setAttribute("content",color));if(persist)window.localStorage.setItem("english-theme",next);}

export default function GkLayout({ children }: { children: ReactNode }) {
 const pathname=usePathname();
 const[theme,setTheme]=useState<Theme>("dark"),[refreshing,setRefreshing]=useState(false),[localSafe,setLocalSafe]=useState(false),[shellTab,setShellTab]=useState<ShellTab>(null),[routeQuery,setRouteQuery]=useState("");
 useEffect(()=>{const saved=window.localStorage.getItem("english-theme");const next:Theme=saved==="light"?"light":"dark";setTheme(next);applyTheme(next);setLocalSafe(isGkLocalSafe());},[]);
 useEffect(()=>{const search=window.location.search;setRouteQuery(search);if(pathname==="/gk"){const p=new URLSearchParams(search);if(p.get("tab")==="progress"){window.location.replace("/gk/intelligence");return;}const tab=(p.get("tab")||"home") as Exclude<ShellTab,null>;setShellTab(["home","content","practice","demand"].includes(tab)?tab:"home");return;}if(pathname?.startsWith("/gk/intelligence")){setShellTab("progress");return;}if(pathname?.startsWith("/gk/teacher")){setShellTab("practice");return;}setShellTab(null);},[pathname]);
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
 const dedicatedRoute=!quizRoute&&pathname!=="/gk";
 const intelligenceDetail=pathname?.startsWith("/gk/intelligence")&&/[?&](subject|concept|question)=/.test(routeQuery);
 const teacherDetail=pathname?.startsWith("/gk/teacher")&&/[?&]series=/.test(routeQuery);
 const routeBack=pathname?.startsWith("/gk/intelligence")&&!intelligenceDetail?{href:"/gk?tab=home",label:"GK Home"}:pathname?.startsWith("/gk/teacher")&&!teacherDetail?{href:"/gk?tab=practice",label:"Practice"}:pathname?.startsWith("/gk/sprint")?{href:"/gk?tab=home",label:"GK Home"}:null;
 const practiceRoot=pathname==="/gk"&&shellTab==="practice"&&!new URLSearchParams(routeQuery).get("view");
 return <div className="gk-app-shell gk-parity-scope" onClickCapture={forceSamePageNavigation}>
  <header className="gk-shell-header">
   <Link href="/gk?tab=home" className="gk-shell-brand" aria-label="GK Mastery home"><strong>GK Mastery</strong><span>SSC GK practice + revision</span></Link>
   <div className="gk-shell-controls">
    {localSafe&&<span className="gk-shell-safe">Local Safe</span>}
    {!quizRoute&&<Link href="/gk/sprint" className={`gk-shell-intelligence ${pathname?.startsWith("/gk/sprint")?"is-active":""}`}>Sprint</Link>}
    <Link href="/" className="gk-shell-control" aria-label="Revision root" title="Revision root">⌂</Link>
    <button className="gk-shell-control" type="button" aria-label={theme==="dark"?"Switch to light mode":"Switch to dark mode"} onClick={toggleTheme}>{theme==="dark"?"☀":"☾"}</button>
    <button className={`gk-shell-control ${refreshing?"is-refreshing":""}`} type="button" aria-label="Hard refresh GK" title="Hard refresh" onClick={()=>void hardRefresh()} disabled={refreshing}>↻</button>
   </div>
  </header>
  <div className="gk-shell-body">
   {quizRoute&&<div className="gk-quiz-backbar"><button className="gk-english-back" type="button" onClick={()=>window.history.back()}>← Back</button></div>}
   {routeBack&&<div className="gk-route-backbar"><a className="gk-route-back" href={routeBack.href}>← {routeBack.label}</a></div>}
   {practiceRoot&&<section className="gk-practice-prelude" aria-label="Practice priorities">
    <div className="gk-practice-heading"><span>Practice</span><h1>Teacher PYQ first</h1><p>Teacher source practice is the main GK lane. Smart tools below repair and reinforce that same knowledge history.</p></div>
    <article className="gk-practice-teacher-hero">
     <div className="gk-practice-teacher-main"><div className="gk-practice-teacher-copy"><span className="gk-practice-primary-label">PRIMARY PRACTICE</span><h2>Teacher PYQ</h2><p>Topic-wise for concept building, Mixed PYQ for exam transfer. One canonical learning history across both.</p></div><Link className="gk-practice-teacher-open" href="/gk/teacher">Open full library ›</Link></div>
     <div className="gk-practice-teacher-actions"><Link href="/gk/teacher?series=TEACHER_TOPIC_PYQ"><b>Topic-wise PYQ</b><small>Build + repair concepts</small></Link><Link href="/gk/teacher?series=TEACHER_MIXED_PYQ"><b>Mixed PYQ</b><small>Interleaved exam transfer</small></Link><Link href="/gk/quiz?teacherSeries=TEACHER_TOPIC_PYQ&mode=smart&lane=MIXED&count=20&title=Teacher%20PYQ%20%C2%B7%20Smart"><b>Smart Teacher 20</b><small>Priority-based teacher retrieval</small></Link></div>
    </article>
    <article className="gk-booster-future"><div className="gk-booster-head"><div><span className="gk-booster-kicker">Future support lane</span><h2>GPT Booster</h2></div><span className="gk-booster-status">Future-ready</span></div><p>Verified GPT-generated practice can land here later without replacing teacher authority or creating a second mastery system.</p><div className="gk-booster-slots"><span>Weakness Fix</span><span>Confusion Cards</span><span>Reverse Recall</span><span>Exam Traps</span></div></article>
   </section>}
   {children}
  </div>
  {dedicatedRoute&&<nav className="gk-shell-bottomnav" aria-label="GK navigation">{NAV.map(([tab,icon,label,href])=><a key={tab} className={shellTab===tab?"is-active":""} href={href}><span>{icon}</span><small>{label}</small></a>)}</nav>}
 </div>;
}

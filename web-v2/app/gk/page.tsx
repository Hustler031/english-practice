"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { rpc, subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { readGkPaused, type GkPausedSession } from "@/lib/gk-session";
import styles from "./gk.module.css";

type Summary={total:number;eligibleTotal:number;exposed:number;coverage:number;starred:number;difficult:number;flagged:number;weak:number;due:number;main:number;rapidRecall:number;eligibleMain:number;eligibleRapidRecall:number};
type Snapshot={ok:boolean;summary:Summary;recommended?:{mode:string;count:number;reason:string};subjects?:Array<{subject:string;count:number;active:number;attempted:number;weak:number}>};
type Lecture={lectureKey:string;lectureNo?:string|number;contentType?:string;title?:string;date?:string;sourceFile?:string;status?:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number};
type SubjectHub={subject:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number;topics:Array<{topic:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number}>};

const quiz=(params:Record<string,string|number|undefined>)=>{const q=new URLSearchParams();Object.entries(params).forEach(([k,v])=>{if(v!==undefined&&v!=="")q.set(k,String(v));});return `/gk/quiz?${q.toString()}`;};

export default function GkHome(){
  const ready=useAuthGuard();
  const[snapshot,setSnapshot]=useState<Snapshot|null>(null);
  const[lectures,setLectures]=useState<Lecture[]>([]);
  const[subjects,setSubjects]=useState<SubjectHub[]>([]);
  const[paused,setPaused]=useState<GkPausedSession|null>(null);
  const[error,setError]=useState(false);
  const[showContent,setShowContent]=useState(false);
  const[showSubjects,setShowSubjects]=useState(false);

  useEffect(()=>{if(!ready)return;let alive=true;const accept=(x:Snapshot)=>{if(alive&&x?.ok!==false){setSnapshot(x);setError(false);}};const off=subscribeRpcFresh<Snapshot>("gk_get_home_snapshot",undefined,accept);rpc<Snapshot>("gk_get_home_snapshot").then(accept).catch(()=>alive&&setError(true));setPaused(readGkPaused());return()=>{alive=false;off();};},[ready]);
  useEffect(()=>{if(!ready||!showContent||lectures.length)return;rpc<Lecture[]>("gk_get_content_hub").then(x=>setLectures(Array.isArray(x)?x:[])).catch(()=>setError(true));},[ready,showContent,lectures.length]);
  useEffect(()=>{if(!ready||!showSubjects||subjects.length)return;rpc<SubjectHub[]>("gk_get_subject_hub").then(x=>setSubjects(Array.isArray(x)?x:[])).catch(()=>setError(true));},[ready,showSubjects,subjects.length]);

  const s=snapshot?.summary;
  const unseen=Math.max(0,(s?.eligibleTotal??0)-(s?.exposed??0));
  const rec=snapshot?.recommended;
  const topLectures=useMemo(()=>lectures.slice(0,8),[lectures]);
  const topSubjects=useMemo(()=>subjects.slice(0,10),[subjects]);
  if(!ready)return <main className={styles.shell}><div className="loading-copy">Checking session…</div></main>;

  return <main className={styles.shell}>
    <div className={styles.top}><div><Link href="/" className={styles.back}>‹ Revision</Link><div className={styles.title}><strong>GK</strong><span>General Knowledge revision</span></div></div></div>
    {error&&<div className={styles.notice}>GK progress couldn&apos;t refresh. Practice navigation is still available; retry by reopening this page.</div>}

    {paused&&<Link className={styles.resume} href={`/gk/quiz?resume=1`}><span><b>Resume paused practice</b><small>{paused.title} · {paused.index+1} / {paused.questions.length}</small></span><span>Resume ›</span></Link>}

    <div className={styles.overview}>
      <div className={styles.pill}><b>{s?`${Math.round(s.coverage)}%`:'—'}</b><span>Bank exposed</span></div>
      <div className={styles.pill}><b>{s?.due??'—'}</b><span>Due</span></div>
      <div className={styles.pill}><b>{s?.weak??'—'}</b><span>Weak</span></div>
      <div className={styles.pill}><b>{s?.starred??'—'}</b><span>Starred</span></div>
    </div>

    <section className={styles.section}><div className={styles.sectionHead}><h2>Main banks</h2><span>Kept strictly separate</span></div><div className={styles.primaryGrid}>
      <Link className={styles.primary} href={quiz({lane:'MAIN',mode:'all',title:'Main'})}><em>Main bank</em><b>Main</b><small>{s?.main??475} total · {s?.eligibleMain??247} active</small></Link>
      <Link className={styles.primary} href={quiz({lane:'RAPID',mode:'all',title:'Rapid Recall'})}><em>Fast recall bank</em><b>Rapid Recall</b><small>{s?.rapidRecall??430} questions</small></Link>
    </div></section>

    <section className={styles.section}><div className={styles.sectionHead}><h2>Smart revision</h2><span>{rec?.reason||'Use your real learning state'}</span></div><div className={styles.list}>
      <Link className={styles.row} href={quiz({source:'smart',mode:rec?.mode||'smart',count:rec?.count||20,title:'Smart Revision'})}><span className={styles.icon}>↻</span><span className={styles.copy}><b>Smart Revision</b><small>Due → Weak → Difficult → Starred → unseen evidence</small></span><span className={styles.count}>{rec?.count||20}</span></Link>
      <Link className={styles.row} href={quiz({source:'smart',mode:'unseen',count:20,title:'New Practice'})}><span className={styles.icon}>✨</span><span className={styles.copy}><b>New Practice</b><small>Genuinely unexposed active GK only</small></span><span className={styles.count}>{unseen}</span></Link>
      <Link className={styles.row} href={quiz({source:'smart',mode:'weak',count:20,title:'Weak Knowledge'})}><span className={styles.icon}>🔥</span><span className={styles.copy}><b>Weak Knowledge</b><small>Persistent Weak · Weak · Fragile</small></span><span className={styles.count}>{s?.weak??0}</span></Link>
      <Link className={styles.row} href={quiz({source:'smart',mode:'mixed',count:20,title:'Random Practice'})}><span className={styles.icon}>🎲</span><span className={styles.copy}><b>Random Practice</b><small>Mixed active GK practice</small></span><span className={styles.count}>20</span></Link>
      <Link className={styles.row} href={quiz({source:'smart',mode:'difficult',count:20,title:'Difficult'})}><span className={styles.icon}>◆</span><span className={styles.copy}><b>Difficult</b><small>Your personal Difficult marks</small></span><span className={styles.count}>{s?.difficult??0}</span></Link>
      <Link className={styles.row} href={quiz({source:'smart',mode:'starred',count:20,title:'Starred Revision'})}><span className={styles.icon}>★</span><span className={styles.copy}><b>Starred Revision</b><small>Return to questions you deliberately saved</small></span><span className={styles.count}>{s?.starred??0}</span></Link>
    </div></section>

    <section className={styles.section}><div className={styles.sectionHead}><h2>Browse content</h2><span>Source and academic hierarchy</span></div><div className={styles.hub}>
      <button className={styles.hubButton} onClick={()=>setShowContent(x=>!x)}><b>By Lecture / Source</b><small>Preserve lecture identity and lane</small></button>
      <button className={styles.hubButton} onClick={()=>setShowSubjects(x=>!x)}><b>By Subject / Topic</b><small>Use existing academic classification</small></button>
    </div>
    {showContent&&<div className={styles.list} style={{marginTop:9}}>{topLectures.length?topLectures.map(l=><Link key={l.lectureKey} className={styles.row} href={quiz({source:'lecture',lecture:l.lectureKey,lane:l.main?'MAIN':'RAPID',title:l.title||`Lecture ${l.lectureNo??''}`})}><span className={styles.icon}>L</span><span className={styles.copy}><b>{l.title||`Lecture ${l.lectureNo??''}`}</b><small>{l.contentType||l.sourceFile||'GK source'} · Main {l.main} · Rapid {l.rapidRecall}</small></span><span className={styles.count}>{l.total}</span></Link>):<div className={styles.notice}>Loading lecture/source hierarchy…</div>}</div>}
    {showSubjects&&<div className={styles.list} style={{marginTop:9}}>{topSubjects.length?topSubjects.map(x=><Link key={x.subject} className={styles.row} href={quiz({source:'subject',subject:x.subject,lane:x.main?'MAIN':'RAPID',title:x.subject})}><span className={styles.icon}>S</span><span className={styles.copy}><b>{x.subject}</b><small>{x.topics?.length||0} topics · Main {x.main} · Rapid {x.rapidRecall}</small></span><span className={styles.count}>{x.total}</span></Link>):<div className={styles.notice}>Loading subject/topic hierarchy…</div>}</div>}
    </section>

    <section className={styles.section}><div className={styles.sectionHead}><h2>Knowledge snapshot</h2><span>Current migrated history</span></div><div className={styles.overview}>
      <div className={styles.pill}><b>{s?.exposed??'—'}</b><span>Attempted</span></div><div className={styles.pill}><b>{s?.eligibleTotal??'—'}</b><span>Active bank</span></div><div className={styles.pill}><b>{s?.difficult??'—'}</b><span>Difficult</span></div><div className={styles.pill}><b>{s?.flagged??'—'}</b><span>Flags</span></div>
    </div></section>
  </main>;
}

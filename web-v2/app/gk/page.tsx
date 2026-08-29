"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { gkRpc, subscribeGkFresh } from "@/lib/gk-rpc";
import { useAuthGuard } from "@/lib/use-auth";
import { readGkPaused, type GkPausedSession } from "@/lib/gk-session";
import styles from "./gk.module.css";

type Summary={total:number;eligibleTotal:number;exposed:number;eligibleExposed:number;coverage:number;starred:number;difficult:number;guessed:number;flagged:number;weak:number;due:number;retentionAccuracy:number;main:number;rapidRecall:number;eligibleMain:number;eligibleRapidRecall:number};
type Snapshot={ok:boolean;summary:Summary;recommended?:{mode:string;count:number;reason:string}};
type Lecture={lectureKey:string;lectureNo?:string|number;contentType?:string;title?:string;date?:string;sourceFile?:string;status?:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number};
type Topic={topic:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number};
type SubjectHub={subject:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number;topics:Topic[]};
type QuizParams=Record<string,string|number|undefined>;

const quiz=(params:QuizParams)=>{const q=new URLSearchParams();Object.entries(params).forEach(([k,v])=>{if(v!==undefined&&v!=="")q.set(k,String(v));});return `/gk/quiz?${q.toString()}`;};
function LaneButtons({base,main,rapid}:{base:QuizParams;main:number;rapid:number}){return <span className={styles.laneActions}>{main>0&&<Link href={quiz({...base,lane:"MAIN"})}>Main {main}</Link>}{rapid>0&&<Link href={quiz({...base,lane:"RAPID"})}>Rapid {rapid}</Link>}</span>}
function QuickRow({icon,title,sub,count,mode}:{icon:string;title:string;sub:string;count:number|string;mode:string}){const base={mode,count:20,title};return <div className={styles.quickBtn}><span className={styles.quickIcon}>{icon}</span><span className={styles.quickCopy}><b>{title}</b><small>{sub}</small></span><span className={styles.quickCount}>{count}</span><LaneButtons base={base} main={1} rapid={1}/></div>}

export default function GkHome(){
 const ready=useAuthGuard();const[snapshot,setSnapshot]=useState<Snapshot|null>(null);const[lectures,setLectures]=useState<Lecture[]>([]);const[subjects,setSubjects]=useState<SubjectHub[]>([]);const[paused,setPaused]=useState<GkPausedSession|null>(null);const[error,setError]=useState(false);const[showContent,setShowContent]=useState(false);const[showSubjects,setShowSubjects]=useState(false);
 useEffect(()=>{if(!ready)return;let alive=true;const accept=(x:Snapshot)=>{if(alive&&x?.ok!==false){setSnapshot(x);setError(false);}};const off=subscribeGkFresh<Snapshot>("gk_get_home_snapshot",undefined,accept);gkRpc<Snapshot>("gk_get_home_snapshot").then(accept).catch(()=>alive&&setError(true));setPaused(readGkPaused());return()=>{alive=false;off();};},[ready]);
 useEffect(()=>{if(!ready||!showContent||lectures.length)return;gkRpc<Lecture[]>("gk_get_content_hub").then(x=>setLectures(Array.isArray(x)?x:[])).catch(()=>setError(true));},[ready,showContent,lectures.length]);
 useEffect(()=>{if(!ready||!showSubjects||subjects.length)return;gkRpc<SubjectHub[]>("gk_get_subject_hub").then(x=>setSubjects(Array.isArray(x)?x:[])).catch(()=>setError(true));},[ready,showSubjects,subjects.length]);
 const s=snapshot?.summary,unseen=Math.max(0,(s?.eligibleTotal??0)-(s?.eligibleExposed??0)),rec=snapshot?.recommended,topLectures=useMemo(()=>lectures.slice(0,12),[lectures]),topSubjects=useMemo(()=>subjects.slice(0,12),[subjects]);
 if(!ready)return <main className={styles.shell}><div className="loading-copy">Checking session…</div></main>;
 return <main className={styles.shell}>
  <header className={styles.topbar}><div><Link href="/" className={styles.back}>‹ Revision</Link><div className={styles.brand}>SSC Master Revision</div><div className={styles.brandSub}>GK mastery · retention-aware revision</div></div></header>
  {error&&<div className={styles.notice}>GK progress couldn&apos;t refresh. Your saved navigation and cached progress remain usable.</div>}
  {paused&&<Link className={styles.resume} href="/gk/quiz?resume=1"><span><b>Resume paused practice</b><small>{paused.title} · {paused.lane} · {paused.index+1} / {paused.questions.length}</small></span><span>Resume ›</span></Link>}
  <section className={styles.hero}><div className={styles.eyebrow}>Daily Revision</div><div className={styles.heroRow}><div><div className={styles.heroTitle}>{s?.due??0} ready for recall</div><div className={styles.heroMuted}>Persistent Weak → Weak → Fragile → Due → controlled New.</div></div><span className={styles.tag}>✓ 0 today</span></div><div className={styles.heroProgress}><span>Today&apos;s progress</span><b>0 / 20</b></div><div className={styles.miniProgress}><i style={{width:'0%'}}/></div><Link className={styles.heroButton} href={quiz({lane:'MAIN',mode:'smart',title:'Daily Revision'})}>Start Daily Revision</Link></section>
  <div className={styles.bankStrip}><Link href={quiz({lane:'MAIN',mode:'all',title:'Main'})}><b>Main</b><small>{s?.eligibleMain??247} active</small></Link><Link href={quiz({lane:'RAPID',mode:'all',title:'Rapid Recall'})}><b>Rapid Recall</b><small>{s?.eligibleRapidRecall??430} questions</small></Link></div>

  <section className={styles.section}><div className={styles.sectionHead}><h2>Quick Start</h2></div><div className={styles.list}>
   <QuickRow icon="↻" title="Smart Revision" sub={`Recommended now: ${rec?.mode||'mixed'} · choose the bank`} count={rec?.count||20} mode={rec?.mode||'mixed'}/>
   <QuickRow icon="✨" title="New Practice" sub="Genuinely unexposed active questions only" count={unseen} mode="unseen"/>
   <QuickRow icon="🎲" title="Random Practice" sub="Random practice inside the bank you choose" count="20" mode="random"/>
   <QuickRow icon="◆" title="Difficult" sub="Your personal Difficult marks" count={s?.difficult??0} mode="difficult"/>
   <QuickRow icon="🔥" title="Weak Knowledge" sub="Persistent Weak · Weak · Fragile" count={s?.weak??0} mode="weak"/>
   <QuickRow icon="★" title="Starred Revision" sub="Questions you deliberately saved" count={s?.starred??0} mode="starred"/>
   <QuickRow icon="◌" title="Recall Check" sub="Seen-before knowledge for reinforcement" count={s?.eligibleExposed??0} mode="recall"/>
   <QuickRow icon="?" title="Guessed" sub="Unconfirmed guessed knowledge" count={s?.guessed??0} mode="guessed"/>
  </div></section>

  <section className={styles.section}><div className={styles.sectionHead}><h2>Content</h2></div><div className={styles.hub}>
   <button className={styles.hubButton} onClick={()=>setShowContent(x=>!x)}><b>By Lecture / Source</b><small>{showContent?'Hide sources':'Open lecture/source bank'}</small></button>
   <button className={styles.hubButton} onClick={()=>setShowSubjects(x=>!x)}><b>By Subject / Topic</b><small>{showSubjects?'Hide subjects':'Open academic hierarchy'}</small></button>
  </div>
  {showContent&&<div className={styles.list} style={{marginTop:9}}>{topLectures.length?topLectures.map(l=><div key={l.lectureKey} className={styles.row}><span className={styles.icon}>L</span><span className={styles.copy}><b>{l.title||`Lecture ${l.lectureNo??''}`}</b><small>{l.contentType||l.sourceFile||'GK source'} · {l.attempted} attempted · {l.weak} weak</small></span><span className={styles.rowEnd}><span className={styles.count}>{l.total}</span><LaneButtons base={{source:'lecture',lecture:l.lectureKey,title:l.title||`Lecture ${l.lectureNo??''}`}} main={l.main} rapid={l.rapidRecall}/></span></div>):<div className={styles.notice}>Loading lecture/source hierarchy…</div>}</div>}
  {showSubjects&&<div className={styles.subjectList} style={{marginTop:9}}>{topSubjects.length?topSubjects.map(x=><details key={x.subject} className={styles.subjectCard}><summary><span><b>{x.subject}</b><small>{x.topics?.length||0} topics · {x.attempted} attempted · {x.weak} weak</small></span><span className={styles.count}>{x.total} ▾</span></summary><div className={styles.subjectLanes}><span>Whole subject</span><LaneButtons base={{source:'subject',subject:x.subject,title:x.subject}} main={x.main} rapid={x.rapidRecall}/></div><div className={styles.topicList}>{(x.topics||[]).map(t=><div className={styles.topicRow} key={`${x.subject}:${t.topic}`}><span><b>{t.topic}</b><small>{t.attempted} attempted · {t.weak} weak</small></span><LaneButtons base={{source:'subject',subject:x.subject,topic:t.topic,title:`${x.subject} · ${t.topic}`}} main={t.main} rapid={t.rapidRecall}/></div>)}</div></details>):<div className={styles.notice}>Loading subject/topic hierarchy…</div>}</div>}
  </section>

  <section className={styles.section}><div className={styles.sectionHead}><h2>Knowledge Snapshot</h2></div><div className={styles.overview}><div className={styles.pill}><b>{s?`${Math.round(s.coverage)}%`:'—'}</b><span>Bank exposed</span></div><div className={styles.pill}><b>{s?`${Math.round(s.retentionAccuracy||0)}%`:'—'}</b><span>Retention accuracy</span></div></div></section>
  <nav className={styles.bottomNav}><Link href="/gk">⌂<small>Home</small></Link><button onClick={()=>setShowContent(true)}>▤<small>Content</small></button><Link href={quiz({lane:'MAIN',mode:'random',title:'Practice'})}>◎<small>Practice</small></Link><Link href={quiz({lane:'MAIN',mode:'difficult',title:'On Demand'})}>◆<small>On Demand</small></Link><Link href={quiz({lane:'MAIN',mode:'recall',title:'Progress'})}>▥<small>Progress</small></Link></nav>
 </main>;
}

"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useAuthGuard } from "@/lib/use-auth";
import { gkRpc, pendingGkAnswers, queueGkAnswer, subscribeGkFresh } from "@/lib/gk";
import "./gk.css";

type Home = { ok:boolean; summary:{total:number;exposed:number;coverage:number;starred:number;difficult:number;flagged:number;weak:number;due:number;main:number;rapidRecall:number}; subjects:Array<{subject:string;count:number;attempted:number;weak:number}>; recommended:{mode:string;count:number;reason:string} };
type Lecture = { lectureKey:string;lectureNo:number|null;contentType:string|null;title:string|null;date:string|null;sourceFile:string|null;status:string|null;total:number;main:number;rapidRecall:number;attempted:number;weak:number };
type Opt = {key:string;text:string};
type Q = { id:string; question_id:string; concept_id?:string; content_lane?:string; lecture_key?:string; lecture_no?:number; source_label?:string; source_date?:string; subject?:string; topic?:string; question:string; options:Opt[]; correctKey:string; explanation?:string; trick?:string; related_fact?:string; exam_trap?:string; difficulty?:string; state?:{attempts:number;correct:number;wrong:number;status:string;starred:boolean;difficult:boolean;flagged:boolean;flagReason:string;note:string} };

type View = "home"|"content"|"quiz";

export default function GkPage(){
  const ready=useAuthGuard();
  const [home,setHome]=useState<Home|null>(null); const [lectures,setLectures]=useState<Lecture[]>([]); const [view,setView]=useState<View>("home");
  const [questions,setQuestions]=useState<Q[]>([]); const [index,setIndex]=useState(0); const [selected,setSelected]=useState<string|null>(null); const [revealed,setRevealed]=useState(false); const [loading,setLoading]=useState(false); const [quizTitle,setQuizTitle]=useState("GK Practice"); const [startedAt,setStartedAt]=useState(0); const [noteOpen,setNoteOpen]=useState(false); const [noteDraft,setNoteDraft]=useState(""); const [theme,setTheme]=useState<"light"|"dark">("light"); const [pending,setPending]=useState(0);
  const q=questions[index];

  useEffect(()=>{ if(!ready)return; const saved=(localStorage.getItem("revision:theme") as "light"|"dark"|null); const t=saved??(matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light"); setTheme(t); document.documentElement.dataset.theme=t; void loadHome(); const off=subscribeGkFresh<Home>("gk_get_home_snapshot",undefined,setHome); const sync=()=>setPending(pendingGkAnswers()); addEventListener("revision:gk:answer-synced",sync); sync(); return()=>{off();removeEventListener("revision:gk:answer-synced",sync);}; },[ready]);

  useEffect(()=>{ if(view!=="quiz"||!q)return; setSelected(null); setRevealed(false); setStartedAt(Date.now()); setNoteDraft(q.state?.note??""); setNoteOpen(false); },[view,index,q?.id]);

  useEffect(()=>{
    if(!ready||typeof window==="undefined"||location.pathname!=="/gk")return;
    if(!(history.state&&history.state.__revisionGkHome)){
      history.replaceState({...history.state,__revisionLauncherGuard:true},"","/");
      history.pushState({__revisionGkHome:true},"","/gk");
    }
  },[ready]);

  async function loadHome(){ try{const [h,c]=await Promise.all([gkRpc<Home>("gk_get_home_snapshot"),gkRpc<Lecture[]>("gk_get_content_hub")]);setHome(h);setLectures(c);}catch{} }
  function toggleTheme(){const n=theme==="dark"?"light":"dark";setTheme(n);document.documentElement.dataset.theme=n;localStorage.setItem("revision:theme",n);}
  async function startSmart(mode:string,count=20,title?:string){setLoading(true);try{const rows=await gkRpc<Q[]>("gk_get_smart_revision",{p_mode:mode,p_count:count});setQuestions(rows);setIndex(0);setQuizTitle(title??label(mode));setView("quiz");}finally{setLoading(false);} }
  async function startLecture(l:Lecture,lane:"main"|"rapid_recall"){setLoading(true);try{const rows=await gkRpc<Q[]>("gk_get_lecture_batch",{p_lecture_key:l.lectureKey,p_lane:lane,p_mode:"all",p_count:100});setQuestions(rows);setIndex(0);setQuizTitle(`${l.title||l.contentType||"Lecture"} · ${lane==="main"?"Main":"Rapid Recall"}`);setView("quiz");}finally{setLoading(false);} }
  function label(x:string){return ({smart:"Smart Revision",due:"Due Revision",weak:"Weak Concepts",starred:"Starred",difficult:"Difficult",unseen:"New GK",mixed:"Mixed Practice"} as Record<string,string>)[x]??"GK Practice";}
  async function answer(k:string){if(!q||revealed)return;setSelected(k);setRevealed(true);await queueGkAnswer({questionId:q.id||q.question_id,selectedOption:k,mode:quizTitle,responseMs:Math.max(0,Date.now()-startedAt),markedReview:!!q.state?.starred});setPending(pendingGkAnswers());}
  async function setStar(){if(!q)return;const v=!q.state?.starred;await gkRpc("gk_set_starred",{p_question_id:q.id||q.question_id,p_starred:v});q.state={...(q.state??defaultState()),starred:v};setQuestions([...questions]);}
  async function setDifficult(){if(!q)return;const v=!q.state?.difficult;await gkRpc("gk_set_difficult",{p_question_id:q.id||q.question_id,p_difficult:v});q.state={...(q.state??defaultState()),difficult:v};setQuestions([...questions]);}
  async function saveNote(){if(!q)return;await gkRpc("gk_save_note",{p_question_id:q.id||q.question_id,p_note:noteDraft});q.state={...(q.state??defaultState()),note:noteDraft};setQuestions([...questions]);setNoteOpen(false);}
  function defaultState(){return {attempts:0,correct:0,wrong:0,status:"New",starred:false,difficult:false,flagged:false,flagReason:"",note:""};}
  function exitQuiz(){if(!confirm("Pause this GK session and return to GK Home? Your saved answers are kept."))return;setView("home");void loadHome();}
  const progress=questions.length?Math.round(((index+1)/questions.length)*100):0;
  const statements=useMemo(()=> q?.question?.split(/(?=\b(?:1|2|3|4)\s*[.)]\s+)/).filter(Boolean)??[],[q?.question]);

  if(!ready)return <main className="gk-shell"><div className="gk-loading">Checking session…</div></main>;
  return <main className="gk-shell">
    <header className="gk-top"><div><Link href="/" className="gk-back" aria-label="Back to Revision launcher">‹</Link><span className="gk-brand">GK Revision</span></div><div className="gk-actions"><span className="gk-sync">{pending?`${pending} pending`:"Synced"}</span><button onClick={toggleTheme} className="gk-icon-btn" aria-label="Toggle theme">{theme==="dark"?"☀":"☾"}</button></div></header>

    {view==="home"&&<section className="gk-content">
      <div className="gk-hero"><div><small>GENERAL KNOWLEDGE</small><h1>Revise what matters.</h1><p>Main learning and Rapid Recall stay separate, while your history drives smart revision.</p></div><button className="gk-primary" disabled={loading} onClick={()=>startSmart(home?.recommended?.mode??"smart",home?.recommended?.count??20)}>{loading?"Loading…":"Start Smart Revision"}</button></div>
      <div className="gk-pills"><span><b>{home?.summary.coverage??0}%</b> exposed</span><span><b>{home?.summary.due??0}</b> due</span><span><b>{home?.summary.weak??0}</b> weak</span><span><b>{home?.summary.starred??0}</b> starred</span><span><b>{home?.summary.difficult??0}</b> difficult</span></div>
      <div className="gk-grid two"><button className="gk-card lane" onClick={()=>startSmart("unseen",20,"Main · New Practice")}><span className="badge main">MAIN</span><h2>Main Practice</h2><p>{home?.summary.main??475} questions · concept learning and revision</p><b>Practice →</b></button><button className="gk-card lane" onClick={()=>{const l=lectures.find(x=>x.rapidRecall>0); if(l)void startLecture(l,"rapid_recall"); else void startSmart("mixed",20,"Rapid Recall");}}><span className="badge rapid">RAPID</span><h2>Rapid Recall</h2><p>{home?.summary.rapidRecall??430} focused recall questions</p><b>Recall →</b></button></div>
      <div className="gk-section-head"><div><h2>Revision intelligence</h2><p>{home?.recommended?.reason??"Use your migrated learning history to choose the next set."}</p></div></div>
      <div className="gk-grid three"><button className="gk-card compact" onClick={()=>startSmart("due",30)}><b>{home?.summary.due??0}</b><span>Due revision</span></button><button className="gk-card compact" onClick={()=>startSmart("weak",30)}><b>{home?.summary.weak??0}</b><span>Weak concepts</span></button><button className="gk-card compact" onClick={()=>startSmart("starred",30)}><b>{home?.summary.starred??0}</b><span>Starred</span></button><button className="gk-card compact" onClick={()=>startSmart("difficult",30)}><b>{home?.summary.difficult??0}</b><span>Difficult</span></button><button className="gk-card compact" onClick={()=>startSmart("mixed",20)}><b>20</b><span>Mixed set</span></button><button className="gk-card compact" onClick={()=>setView("content")}><b>{lectures.length}</b><span>Lectures / Sources</span></button></div>
      <div className="gk-section-head"><div><h2>Subjects</h2><p>Academic classification preserved from the original GK bank.</p></div></div>
      <div className="gk-subjects">{(home?.subjects??[]).slice(0,12).map(s=><button key={s.subject} className="gk-subject" onClick={()=>setView("content")}><span>{s.subject}</span><small>{s.attempted}/{s.count} seen · {s.weak} weak</small></button>)}</div>
    </section>}

    {view==="content"&&<section className="gk-content"><div className="gk-section-head sticky"><div><button className="text-back" onClick={()=>setView("home")}>← GK Home</button><h1>Lectures & Sources</h1><p>Choose Main or Rapid Recall inside each source.</p></div></div><div className="lecture-list">{lectures.map(l=><article className="lecture-row" key={l.lectureKey}><div><small>{l.contentType||"GK"}{l.date?` · ${l.date}`:""}</small><h3>{l.title||l.sourceFile||l.lectureKey}</h3><p>{l.attempted}/{l.total} attempted · {l.weak} weak</p></div><div className="lecture-actions"><button disabled={!l.main} onClick={()=>startLecture(l,"main")}>Main {l.main}</button><button disabled={!l.rapidRecall} onClick={()=>startLecture(l,"rapid_recall")}>Rapid {l.rapidRecall}</button></div></article>)}</div></section>}

    {view==="quiz"&&q&&<section className="quiz-shell">
      <div className="quiz-head"><button className="text-back" onClick={exitQuiz}>← Pause</button><div><strong>{quizTitle}</strong><small>{index+1} / {questions.length}</small></div><div className="quiz-tools"><button className={q.state?.starred?"on":""} onClick={setStar}>★</button><button className={q.state?.difficult?"on difficult":""} onClick={setDifficult}>!</button><button className={q.state?.note?"on":""} onClick={()=>setNoteOpen(v=>!v)}>✎</button></div></div>
      <div className="progress"><i style={{width:`${progress}%`}}/></div>
      <div className="question-card"><div className="question-meta"><span>{q.subject||"GK"}{q.topic?` · ${q.topic}`:""}</span><span>{q.id||q.question_id}</span></div><div className="question-text">{statements.length>1?statements.map((s,i)=><p key={i}>{s.trim()}</p>):<p>{q.question}</p>}</div><div className="options">{q.options?.map(o=>{const correct=revealed&&o.key===q.correctKey;const wrong=revealed&&o.key===selected&&o.key!==q.correctKey;return <button key={o.key} disabled={revealed} className={`${selected===o.key?"selected":""} ${correct?"correct":""} ${wrong?"wrong":""}`} onClick={()=>answer(o.key)}><b>{o.key}</b><span>{o.text}</span></button>})}</div>
        {revealed&&<div className="explanation"><div className={selected===q.correctKey?"result ok":"result bad"}>{selected===q.correctKey?"Correct":"Incorrect"} · Answer {q.correctKey}</div>{q.explanation&&<section><h3>Explanation</h3><p>{q.explanation}</p></section>}{q.related_fact&&<section><h3>Related fact</h3><p>{q.related_fact}</p></section>}{q.trick&&<section><h3>Memory cue</h3><p>{q.trick}</p></section>}{q.exam_trap&&<section><h3>Exam trap</h3><p>{q.exam_trap}</p></section>}</div>}
        {noteOpen&&<div className="note-box"><textarea value={noteDraft} onChange={e=>setNoteDraft(e.target.value)} placeholder="Add your note…"/><div><button onClick={()=>setNoteOpen(false)}>Cancel</button><button onClick={saveNote}>Save note</button></div></div>}
      </div>
      <footer className="quiz-footer"><button disabled={index===0} onClick={()=>setIndex(i=>Math.max(0,i-1))}>Previous</button><button className="next" disabled={!revealed&&!!selected} onClick={()=>{if(index+1<questions.length)setIndex(i=>i+1);else{setView("home");void loadHome();}}}>{index+1<questions.length?"Next":"Finish"}</button></footer>
    </section>}
    {view==="quiz"&&!q&&<section className="gk-content"><div className="gk-empty"><h2>No questions in this set</h2><button onClick={()=>setView("home")}>Back to GK Home</button></div></section>}
  </main>;
}

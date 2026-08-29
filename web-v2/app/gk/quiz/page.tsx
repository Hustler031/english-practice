"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { gkRpc } from "@/lib/gk-rpc";
import { useAuthGuard } from "@/lib/use-auth";
import { clearGkPaused, readGkPaused, saveGkPaused, type GkPausedAnswer } from "@/lib/gk-session";
import styles from "../gk.module.css";

type Lane="MAIN"|"RAPID";
type State={attempts?:number;correct?:number;wrong?:number;status?:string;starred?:boolean;difficult?:boolean;nextReview?:string|null;flagged?:boolean;flagReason?:string;note?:string};
type Opt={key:string;text:string};
type Q={id:string;question_id?:string;question:string;explanation?:string;trick?:string;related_fact?:string;exam_trap?:string;correctKey:string;content_lane?:string;subject?:string;topic?:string;lecture_key?:string;lecture_no?:string|number;concept_id?:string;source_label?:string;difficulty?:string;options:Opt[];state?:State};
type Answers=Record<string,GkPausedAnswer>;
type Meta={lane:Lane;mode:string;source:string;title:string};

function statementQuestion(text:string){const normalized=String(text||"").replace(/\s+(?=\d+\.\s)/g,"\n");return normalized.split(/\n+/).filter(Boolean).map((line,i)=>{const hit=line.match(/^(\d+\.)(.*)$/);return hit?<span className={styles.statement} key={i}><strong>{hit[1]}</strong>{hit[2]}</span>:<span key={i}>{line}</span>;});}

export default function GkQuiz(){
 const ready=useAuthGuard();const params=useMemo(()=>typeof window==="undefined"?new URLSearchParams():new URLSearchParams(window.location.search),[]);
 const queryLane=(params.get("lane")==="RAPID"?"RAPID":"MAIN") as Lane;const queryMode=params.get("mode")||"all";const querySource=params.get("source")||"lane";const queryTitle=params.get("title")||(queryLane==="RAPID"?"Rapid Recall":"Main");
 const[meta,setMeta]=useState<Meta>({lane:queryLane,mode:queryMode,source:querySource,title:queryTitle});const[qs,setQs]=useState<Q[]>([]);const[index,setIndex]=useState(0);const[answers,setAnswers]=useState<Answers>({});const[error,setError]=useState(false);const[loading,setLoading]=useState(true);const[noteOpen,setNoteOpen]=useState(false);const[note,setNote]=useState("");
 useEffect(()=>{if(!ready)return;let alive=true;const paused=params.get("resume")==="1"?readGkPaused():null;if(paused){setMeta({lane:paused.lane,mode:paused.mode,source:"resume",title:paused.title});setQs(paused.questions as Q[]);setIndex(Math.min(paused.index,paused.questions.length-1));setAnswers(paused.answers||{});setLoading(false);return;}const count=Math.max(1,Math.min(100,Number(params.get("count")||50)));let call:Promise<Q[]>;if(querySource==="lecture")call=gkRpc<Q[]>("gk_get_lecture_batch",{p_lecture_key:params.get("lecture")||"",p_lane:queryLane,p_mode:queryMode,p_count:count});else if(querySource==="subject")call=gkRpc<Q[]>("gk_get_subject_batch",{p_subject:params.get("subject")||"Unclassified",p_topic:params.get("topic")||null,p_lane:queryLane,p_mode:queryMode,p_count:count});else call=gkRpc<Q[]>("gk_get_lane_batch",{p_lane:queryLane,p_mode:queryMode,p_count:count});call.then(x=>{if(alive){setQs(Array.isArray(x)?x:[]);setLoading(false);}}).catch(()=>{if(alive){setError(true);setLoading(false);}});return()=>{alive=false;};},[ready,params,queryLane,queryMode,querySource]);
 const q=qs[index],answered=q?answers[q.id]:undefined;
 useEffect(()=>{setNote(q?.state?.note||"");setNoteOpen(false);},[q?.id]);
 async function answer(key:string){if(!q||answered)return;const correct=key===q.correctKey;setAnswers(a=>({...a,[q.id]:{selected:key,correct,correctKey:q.correctKey}}));try{await gkRpc("gk_submit_answer",{p_question_id:q.id,p_selected_option:key,p_marked_review:!!q.state?.starred,p_mode:`${meta.lane.toLowerCase()}:${meta.mode}`});}catch{setError(true);}}
 async function toggleStar(){if(!q)return;const next=!q.state?.starred;setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,starred:next}}:v));try{await gkRpc("gk_set_starred",{p_question_id:q.id,p_starred:next});}catch{setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,starred:!next}}:v));setError(true);}}
 async function toggleDifficult(){if(!q)return;const next=!q.state?.difficult;setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,difficult:next}}:v));try{await gkRpc("gk_set_difficult",{p_question_id:q.id,p_difficult:next});}catch{setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,difficult:!next}}:v));setError(true);}}
 async function toggleFlag(){if(!q)return;const next=!q.state?.flagged;const reason=next?(q.state?.flagReason||"Review requested"):"";setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,flagged:next,flagReason:reason}}:v));try{await gkRpc("gk_set_flag",{p_question_id:q.id,p_active:next,p_reason:reason,p_note:""});}catch{setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,flagged:!next}}:v));setError(true);}}
 async function saveNote(){if(!q)return;try{await gkRpc("gk_save_note",{p_question_id:q.id,p_note:note});setQs(x=>x.map(v=>v.id===q.id?{...v,state:{...v.state,note}}:v));setNoteOpen(false);}catch{setError(true);}}
 function pause(){if(!q)return;if(!window.confirm("Pause this GK practice and return home? Your exact position will be saved."))return;saveGkPaused({title:meta.title,lane:meta.lane,mode:meta.mode,index,questions:qs,answers,query:window.location.search,savedAt:Date.now()});window.location.href="/gk";}
 function go(next:number){setIndex(Math.max(0,Math.min(qs.length-1,next)));window.scrollTo({top:0,behavior:"smooth"});}
 function finish(){clearGkPaused();window.location.href="/gk";}
 if(!ready)return <main className={styles.quiz}><div className="loading-copy">Checking session…</div></main>;
 if(loading)return <main className={styles.quiz}><div className="loading-copy">Loading {meta.title}…</div></main>;
 if(!q)return <main className={styles.quiz}><div className={styles.top}><Link href="/gk" className={styles.back}>‹ GK</Link></div><div className={styles.notice}>{error?"GK questions couldn’t load. Reopen this set to retry.":"No eligible questions are available in this set right now."}</div></main>;
 const pct=((index+1)/Math.max(1,qs.length))*100,last=index===qs.length-1;
 return <main className={styles.quiz}>
  <header className={styles.quizTop}><div className={styles.quizTopLine}><Link href="/gk" className={styles.back}>‹ GK</Link><strong>{meta.title}</strong><span>{index+1}/{qs.length}</span></div><div className={styles.progress}><i style={{width:`${pct}%`}}/></div></header>
  {error&&<div className={styles.notice}>A save is waiting to sync. You can keep studying.</div>}
  <div className={styles.context}><span className={styles.chip}>{q.content_lane||meta.lane}</span>{q.subject&&<span className={styles.chip}>{q.subject}</span>}{q.topic&&<span className={styles.chip}>{q.topic}</span>}{q.lecture_no&&<span className={styles.chip}>Lecture {q.lecture_no}</span>}<span className={styles.chip}>{q.id}</span>{q.state?.status&&<span className={styles.chip}>{q.state.status}</span>}</div>
  <section className={styles.question}>{statementQuestion(q.question)}</section>
  <div className={styles.options}>{q.options.map(o=>{const correct=!!answered&&o.key===answered.correctKey;const wrong=!!answered&&o.key===answered.selected&&!answered.correct;return <button key={o.key} className={`${styles.option} ${correct?styles.correct:""} ${wrong?styles.wrong:""}`} onClick={()=>answer(o.key)} disabled={!!answered}><span className={styles.optionKey}>{o.key}</span><span>{o.text}</span></button>})}</div>
  {answered&&<><section className={styles.explain}><h3>{answered.correct?"Correct · lock the fact":"Review · correct the recall"}</h3><p>{q.explanation||"Answer recorded."}</p>{q.trick&&<p><strong>Trick:</strong> {q.trick}</p>}{q.related_fact&&<p><strong>Related fact:</strong> {q.related_fact}</p>}{q.exam_trap&&<p><strong>Exam trap:</strong> {q.exam_trap}</p>}</section><div className={styles.tools}><button className={`${styles.tool} ${q.state?.starred?styles.activeTool:""}`} onClick={toggleStar}>★ Star</button><button className={`${styles.tool} ${q.state?.difficult?styles.activeTool:""}`} onClick={toggleDifficult}>◆ Difficult</button><button className={`${styles.tool} ${q.state?.flagged?styles.activeTool:""}`} onClick={toggleFlag}>⚑ Flag</button><button className={`${styles.tool} ${(q.state?.note||note)?styles.activeTool:""}`} onClick={()=>setNoteOpen(x=>!x)}>▤ Note</button></div>{noteOpen&&<section className={styles.explain}><h3>Personal note</h3><textarea className={styles.note} value={note} onChange={e=>setNote(e.target.value)} placeholder="Write the exact fact you want to remember"/><button className="btn primary" onClick={saveNote}>Save note</button></section>}</>}
  <footer className={styles.dock}><div className={styles.dockInner}><button onClick={()=>go(index-1)} disabled={index===0}>‹ Previous</button><button onClick={pause}>Ⅱ Pause</button>{last?<button onClick={finish}>Finish ✓</button>:<button onClick={()=>go(index+1)}>Next ›</button>}</div></footer>
 </main>;
}

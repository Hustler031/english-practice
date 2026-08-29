"use client";

import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { rpc } from "@/lib/supabase";
import { makeDisplayOptions, type DisplayOption } from "@/lib/options";
import AddWordSheet from "@/components/add-word-sheet";
import { clearPausedQuiz, savePausedQuiz, type PausedQuizAnswer, type PausedQuizSession } from "@/lib/quiz-session";

type Question = { id:string; category?:string; topic?:string; subtopic?:string; word?:string; question:string; options:{key:string;text:string}[]; correctKey?:string; questionType?:string; explanation?:string; tip?:string; usageNote?:string; example?:string; memoryAid?:string; starred?:boolean; difficult?:boolean; mastered?:boolean; status?:string; attempts?:number; wrong?:number };
type Props = { title:string; backHref:string; load:()=>Promise<Question[]>; module?:string; emptyText?:string; resumeSession?:PausedQuizSession|null };
const difficultModules=new Set(["starredrevision","mysavedrevision","bankcoverage","difficult","phrasalrevision","phrasaldaily"]);
const isRecallCard=(q?:Question)=>/reverse\s+recall\s+card/i.test(String(q?.questionType||""));

export default function QuizRunner({ title, backHref, load, module="practice", emptyText="No questions are available for this selection.", resumeSession }: Props) {
  const router=useRouter();const [items,setItems]=useState<Question[]>([]);const [idx,setIdx]=useState(0);const [answers,setAnswers]=useState<Record<string,PausedQuizAnswer>>({});const [revealedRecall,setRevealedRecall]=useState<Set<string>>(new Set());const [loading,setLoading]=useState(true);const [busy,setBusy]=useState(false);const [error,setError]=useState("");const started=useRef(Date.now());const optionCache=useRef(new Map<string,DisplayOption[]>());

  useEffect(()=>{let live=true;if(resumeSession?.questions?.length){setItems(resumeSession.questions as Question[]);setIdx(Math.max(0,Math.min(resumeSession.index||0,resumeSession.questions.length-1)));setAnswers(resumeSession.answers||{});setRevealedRecall(new Set(resumeSession.revealedRecall||[]));setLoading(false);started.current=Date.now();return()=>{live=false;};}setLoading(true);optionCache.current.clear();setAnswers({});setRevealedRecall(new Set());load().then(x=>{if(live){setItems(Array.isArray(x)?x:[]);setIdx(0);started.current=Date.now();}}).catch((e:any)=>live&&setError(e.message)).finally(()=>live&&setLoading(false));return()=>{live=false;};},[load,resumeSession]);

  useEffect(()=>{if(!items.length)return;savePausedQuiz({title,backHref,module,index:idx,questions:items,answers,revealedRecall:[...revealedRecall],savedAt:Date.now()});},[items,idx,title,backHref,module,answers,revealedRecall]);
  useEffect(()=>{if(loading)return;const onBack=()=>window.location.assign(backHref);window.history.pushState({englishQuiz:true},"");window.addEventListener("popstate",onBack);return()=>window.removeEventListener("popstate",onBack);},[loading,backHref]);

  const q=items[idx];const answer=q?answers[q.id]:undefined;
  const options=useMemo(()=>{if(!q||isRecallCard(q))return[];const hit=optionCache.current.get(q.id);if(hit)return hit;const made=makeDisplayOptions(q.questionType,q.options||[]);optionCache.current.set(q.id,made);return made;},[q?.id,q?.questionType,q?.options]);
  const selectedDisplayKey=answer?(options.find(o=>o.canonicalKey===answer.selectedCanonicalKey)?.key||answer.selectedCanonicalKey):"";const correctDisplayKey=answer?(options.find(o=>o.canonicalKey===answer.correctCanonicalKey)?.key||answer.correctCanonicalKey):"";const showDifficult=difficultModules.has(module.toLowerCase());const recall=isRecallCard(q);const recallShown=!!q&&revealedRecall.has(q.id);

  function move(next:number){if(next<0||next>=items.length)return;setIdx(next);setError("");started.current=Date.now();window.scrollTo({top:0,behavior:"smooth"});}
  function pause(){window.location.assign(backHref);}
  async function answerCanonical(canonicalKey:string){if(!q||answer||busy)return;setBusy(true);setError("");try{const out=await rpc<any>("english_submit_answer",{p_question_id:q.id,p_selected_key:canonicalKey,p_time_seconds:Math.min(180,(Date.now()-started.current)/1000),p_marked_revision:!!q.starred,p_attempt_id:`v2-${q.id}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`,p_module:module});setAnswers(a=>({...a,[q.id]:{selectedCanonicalKey:canonicalKey,correct:!!out.is_correct,correctCanonicalKey:String(out.correct_key||q.correctKey||"").toUpperCase()}}));}catch(e:any){setError(e.message);}finally{setBusy(false);}}
  async function answerOption(option:DisplayOption){return answerCanonical(option.canonicalKey);}
  async function toggleMark(){if(!q)return;const next=!q.starred;setItems(rows=>rows.map((row,i)=>i===idx?{...row,starred:next}:row));try{await rpc("english_set_starred",{p_question_id:q.id,p_starred:next});}catch(e:any){setItems(rows=>rows.map((row,i)=>i===idx?{...row,starred:!next}:row));setError(e.message);}}
  async function toggleDifficult(){if(!q)return;const next=!q.difficult;setItems(rows=>rows.map((row,i)=>i===idx?{...row,difficult:next}:row));try{await rpc("english_set_difficult",{p_question_id:q.id,p_difficult:next});}catch(e:any){setItems(rows=>rows.map((row,i)=>i===idx?{...row,difficult:!next}:row));setError(e.message);}}
  async function mastered(){if(!q||!window.confirm("Mark Mastered only after spaced retention is proven?"))return;try{await rpc("english_set_mastered",{p_question_id:q.id,p_mastered:true,p_require_proven:true});setItems(rows=>rows.map((row,i)=>i===idx?{...row,mastered:true}:row));if(idx<items.length-1)move(idx+1);else{clearPausedQuiz();router.push(backHref);}}catch(e:any){setError(e.message||"Retention not proven yet");}}
  function revealRecall(){if(!q)return;setRevealedRecall(s=>{const next=new Set(s);next.add(q.id);return next;});}
  function finish(){clearPausedQuiz();router.push(backHref);}

  if(loading)return <main className="center"><div className="muted">Loading {title}…</div></main>;
  if(!items.length)return <main className="shell quiz"><QuizTop title={title} onBack={pause}/><div className="empty-state"><h2>{title}</h2><p className="muted">{error||emptyText}</p></div></main>;
  if(!q)return <main className="shell"><div className="error-box">Question position is unavailable.</div></main>;

  return <main className="shell quiz quiz-with-tools">
    <QuizTop title={title} onBack={pause} count={`${idx+1} / ${items.length}`}/><div className="progress"><span style={{width:`${((idx+1)/items.length)*100}%`}}/></div>
    <section className="quiz-card">
      <div className="quiz-meta"><span className="pill">{q.category||q.topic||"English"}</span>{q.subtopic&&<span className="pill">{q.subtopic}</span>}<span className="pill">{q.id}</span><LearningSignals status={q.status} attempts={q.attempts} wrong={q.wrong}/></div>
      <div className="question-area">{!recall&&q.word&&<div className="question-word">{q.word}</div>}<div className="question">{q.question}</div></div>
      {recall?<RecallCard q={q} revealed={recallShown} answer={answer} busy={busy} onReveal={revealRecall} onRate={answerCanonical}/>:<div className="options">{options.map(o=>{let cls="option";if(selectedDisplayKey===o.key)cls+=" selected";if(answer&&o.canonicalKey===answer.correctCanonicalKey)cls+=" correct";if(answer&&selectedDisplayKey===o.key&&o.canonicalKey!==answer.correctCanonicalKey)cls+=" wrong";return <button key={o.key} className={cls} onClick={()=>answerOption(o)} disabled={!!answer||busy}><span className="option-key">{o.key}</span><span>{o.text}</span></button>;})}</div>}
      {error&&<div className="result-wrap"><div className="error-box">{error}</div></div>}
      {answer&&!recall&&<div className="result-wrap"><div className={`result-head ${answer.correct?"good-result":"bad-result"}`}><span className="result-dot"/><strong>{answer.correct?"Correct":"Incorrect"}</strong><span className="spacer"/><span className="pill">Answer {correctDisplayKey}</span></div><div className="explanation">{q.explanation||"No explanation available."}{q.example?`\n\nExample: ${q.example}`:""}{q.usageNote?`\n\nUsage: ${q.usageNote}`:""}{q.tip?`\n\nTip: ${q.tip}`:""}{q.memoryAid?`\n\nRemember: ${q.memoryAid}`:""}</div></div>}
      {answer&&showDifficult&&<button className={`mastered-after ${q.mastered?"done":""}`} onClick={mastered}>{q.mastered?"✓ Mastered":"✓"}</button>}
    </section>
    <div className="quiz-tools"><button className={`btn ghost ${q.starred?"warn":""}`} onClick={toggleMark}>{q.starred?"★ Marked":"☆ Mark"}</button><AddWordSheet questionId={q.id} initialWord={q.word||""} source={title} label="📝 Add Word"/>{showDifficult?<button className={`btn ghost ${q.difficult?"danger":""}`} onClick={toggleDifficult}>{q.difficult?"⚡ Difficult ✓":"⚡ Difficult"}</button>:<button className="btn ghost" onClick={mastered}>✓ Mastered</button>}<button className="btn ghost" onClick={pause}>Ⅱ Pause</button></div>
    <div className="quiz-nav"><button className="btn ghost" disabled={idx===0} onClick={()=>move(idx-1)}>← Previous</button><button className="btn primary" onClick={()=>idx<items.length-1?move(idx+1):finish()}>{idx===items.length-1?"Finish":"Next →"}</button></div>
  </main>;
}

function RecallCard({q,revealed,answer,busy,onReveal,onRate}:{q:Question;revealed:boolean;answer?:PausedQuizAnswer;busy:boolean;onReveal:()=>void;onRate:(key:string)=>void}){if(!revealed&&!answer)return <div className="card" style={{textAlign:"center"}}><b>Think of the Phrasal Verb first.</b><button className="btn primary full-width" style={{marginTop:10}} onClick={onReveal}>View Answer</button></div>;const label=answer?(answer.selectedCanonicalKey==="A"?"✓ Yaad tha":answer.selectedCanonicalKey==="B"?"~ Confused":"✕ Bhool gaya"):"";return <><div className="card"><div className="question-word">{q.word}</div>{q.explanation&&<div className="explanation" style={{marginTop:0}}>{q.explanation}{q.example?`\n\nExample: ${q.example}`:""}</div>}</div><div className="action-matrix" style={{marginTop:9}}><button className="btn soft" disabled={!!answer||busy} onClick={()=>onRate("A")}>✓ Yaad tha</button><button className="btn soft" disabled={!!answer||busy} onClick={()=>onRate("B")}>~ Confused</button><button className="btn soft" disabled={!!answer||busy} onClick={()=>onRate("C")}>✕ Bhool gaya</button></div>{answer&&<div className={`result-head ${answer.selectedCanonicalKey==="A"?"good-result":"bad-result"}`} style={{marginTop:9}}><strong>{label}</strong></div>}</>}
function QuizTop({title,onBack,count}:{title:string;onBack:()=>void;count?:string}){return <div className="quiz-top"><button className="btn ghost" onClick={onBack}>← Back</button><div className="quiz-title"><div className="brand">{title}</div>{count&&<div className="quiz-count">{count}</div>}</div><div/></div>}
function LearningSignals({status,attempts,wrong}:{status?:string;attempts?:number;wrong?:number}){const persistent=status==="Persistent Weak";const weak=!persistent&&["Weak","Fragile"].includes(status||"");return <>{persistent&&<span className="pill signal-persistent">Persistent Weak</span>}{weak&&<span className="pill signal-weak">Weak</span>}{typeof attempts==="number"&&attempts>0&&<span className="pill">{attempts} attempt{attempts===1?"":"s"}{wrong?` · ${wrong} wrong`:""}</span>}</>}

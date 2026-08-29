"use client";

import { useRouter } from "next/navigation";
import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import { rpc } from "@/lib/supabase";
import { makeDisplayOptions, type DisplayOption } from "@/lib/options";
import AddWordSheet from "@/components/add-word-sheet";
import { clearPausedQuiz, savePausedQuiz, type PausedQuizAnswer, type PausedQuizSession } from "@/lib/quiz-session";

type Question = { id:string; category?:string; topic?:string; subtopic?:string; word?:string; question:string; options:{key:string;text:string}[]; correctKey?:string; questionType?:string; explanation?:string; tip?:string; usageNote?:string; example?:string; memoryAid?:string; related?:string; starred?:boolean; difficult?:boolean; mastered?:boolean; status?:string; attempts?:number; correct?:number; wrong?:number; nextReview?:string; selectionReason?:string; reason?:string };
type Props = { title:string; backHref:string; load:()=>Promise<Question[]>; module?:string; emptyText?:string; resumeSession?:PausedQuizSession|null; initialIndex?:number; onPause?:(index:number,total:number)=>void|Promise<void>; onFinish?:()=>void|Promise<void>; onExit?:()=>void };
const difficultModules=new Set(["starredrevision","mysavedrevision","bankcoverage","difficult","phrasalrevision","phrasaldaily"]);
const isRecallCard=(q?:Question)=>/reverse\s+recall\s+card/i.test(String(q?.questionType||""));

export default function QuizRunner({ title, backHref, load, module="practice", emptyText="No questions are available for this selection.", resumeSession, initialIndex=0, onPause, onFinish, onExit }: Props) {
  const router=useRouter();const [items,setItems]=useState<Question[]>([]);const [idx,setIdx]=useState(0);const [answers,setAnswers]=useState<Record<string,PausedQuizAnswer>>({});const [revealedRecall,setRevealedRecall]=useState<Set<string>>(new Set());const [loading,setLoading]=useState(true);const [busy,setBusy]=useState(false);const [error,setError]=useState("");const started=useRef(Date.now());const optionCache=useRef(new Map<string,DisplayOption[]>());const exitRef=useRef<{idx:number;total:number;onPause?:Props["onPause"];onExit?:Props["onExit"]}>({idx:0,total:0});

  useEffect(()=>{let live=true;if(resumeSession?.questions?.length){setItems(resumeSession.questions as Question[]);setIdx(Math.max(0,Math.min(resumeSession.index||0,resumeSession.questions.length-1)));setAnswers(resumeSession.answers||{});setRevealedRecall(new Set(resumeSession.revealedRecall||[]));setLoading(false);started.current=Date.now();return()=>{live=false;};}setLoading(true);optionCache.current.clear();setAnswers({});setRevealedRecall(new Set());load().then(x=>{if(live){const rows=Array.isArray(x)?x:[];setItems(rows);setIdx(rows.length?Math.max(0,Math.min(initialIndex,rows.length-1)):0);started.current=Date.now();}}).catch((e:any)=>live&&setError(e.message)).finally(()=>live&&setLoading(false));return()=>{live=false;};},[load,resumeSession,initialIndex]);
  useEffect(()=>{exitRef.current={idx,total:items.length,onPause,onExit};},[idx,items.length,onPause,onExit]);
  useEffect(()=>{if(!items.length)return;savePausedQuiz({title,backHref,module,index:idx,questions:items,answers,revealedRecall:[...revealedRecall],savedAt:Date.now()});},[items,idx,title,backHref,module,answers,revealedRecall]);
  useEffect(()=>{if(loading)return;const onBack=()=>{const x=exitRef.current;Promise.resolve(x.onPause?.(x.idx,x.total)).catch(()=>{}).finally(()=>{if(x.onExit)x.onExit();else router.push(backHref);});};window.history.pushState({englishQuiz:true},"");window.addEventListener("popstate",onBack);return()=>window.removeEventListener("popstate",onBack);},[loading,backHref,router]);

  const q=items[idx];const answer=q?answers[q.id]:undefined;const [intelOpen,setIntelOpen]=useState(false);
  useEffect(()=>setIntelOpen(false),[q?.id]);
  const options=useMemo(()=>{if(!q||isRecallCard(q))return[];const hit=optionCache.current.get(q.id);if(hit)return hit;const made=makeDisplayOptions(q.questionType,q.options||[]);optionCache.current.set(q.id,made);return made;},[q?.id,q?.questionType,q?.options]);
  const selectedDisplayKey=answer?(options.find(o=>o.canonicalKey===answer.selectedCanonicalKey)?.key||answer.selectedCanonicalKey):"";const showDifficult=difficultModules.has(module.toLowerCase());const recall=isRecallCard(q);const recallShown=!!q&&revealedRecall.has(q.id);

  function move(next:number){if(next<0||next>=items.length)return;setIdx(next);setError("");started.current=Date.now();window.scrollTo({top:0,behavior:"smooth"});}
  async function exitQuiz(){try{await onPause?.(idx,items.length);}catch{}if(onExit)onExit();else router.push(backHref);}
  async function answerCanonical(canonicalKey:string){
    if(!q||answer||busy)return;
    const localCorrectKey=String(q.correctKey||"").toUpperCase();
    // Apps Script paints the answer before its async save completes. Keep that
    // tactile behaviour here; the server result can correct the canonical key.
    setAnswers(a=>({...a,[q.id]:{selectedCanonicalKey:canonicalKey,correct:canonicalKey===localCorrectKey,correctCanonicalKey:localCorrectKey}}));
    setBusy(true);setError("");
    try{const out=await rpc<any>("english_submit_answer",{p_question_id:q.id,p_selected_key:canonicalKey,p_time_seconds:Math.min(180,(Date.now()-started.current)/1000),p_marked_revision:!!q.starred,p_attempt_id:`v2-${q.id}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`,p_module:module});const correctKey=String(out.correct_key||localCorrectKey).toUpperCase();setAnswers(a=>({...a,[q.id]:{selectedCanonicalKey:canonicalKey,correct:!!out.is_correct,correctCanonicalKey:correctKey}}));}
    catch(e:any){setError(`Answer is shown, but saving it failed: ${e.message||"please retry later"}`);}
    finally{setBusy(false);}
  }
  async function answerOption(option:DisplayOption){return answerCanonical(option.canonicalKey);}
  async function toggleMark(){if(!q)return;const next=!q.starred;setItems(rows=>rows.map((row,i)=>i===idx?{...row,starred:next}:row));try{await rpc("english_set_starred",{p_question_id:q.id,p_starred:next});}catch(e:any){setItems(rows=>rows.map((row,i)=>i===idx?{...row,starred:!next}:row));setError(e.message);}}
  async function toggleDifficult(){if(!q)return;const next=!q.difficult;setItems(rows=>rows.map((row,i)=>i===idx?{...row,difficult:next}:row));try{await rpc("english_set_difficult",{p_question_id:q.id,p_difficult:next});}catch(e:any){setItems(rows=>rows.map((row,i)=>i===idx?{...row,difficult:!next}:row));setError(e.message);}}
  async function mastered(){if(!q||!window.confirm("Mark Mastered only after spaced retention is proven?"))return;try{await rpc("english_set_mastered",{p_question_id:q.id,p_mastered:true,p_require_proven:true});setItems(rows=>rows.map((row,i)=>i===idx?{...row,mastered:true}:row));if(idx<items.length-1)move(idx+1);else await finish();}catch(e:any){setError(e.message||"Retention not proven yet");}}
  function revealRecall(){if(!q)return;setRevealedRecall(s=>{const next=new Set(s);next.add(q.id);return next;});}
  async function finish(){try{await onFinish?.();}catch{}clearPausedQuiz();if(onExit)onExit();else router.push(backHref);}

  if(loading)return <main className="center"><div className="muted">Loading {title}…</div></main>;
  if(!items.length)return <main className="shell quiz"><QuizTop title={title} onBack={()=>void exitQuiz()}/><div className="empty-state"><h2>{title}</h2><p className="muted">{error||emptyText}</p></div></main>;
  if(!q)return <main className="shell"><div className="error-box">Question position is unavailable.</div></main>;

  return <main className="shell quiz quiz-with-tools">
    <QuizTop title={title} onBack={()=>void exitQuiz()} count={`${idx+1} / ${items.length}`}/><div className="progress"><span style={{width:`${((idx+1)/items.length)*100}%`}}/></div>
    <section className="quiz-card">
      <div className="quiz-meta"><span className="pill">{q.category||q.topic||"English"}</span><span className="pill">{q.id}</span><LearningSignals status={q.status}/><button className="intel-button" type="button" aria-label="Question intelligence" aria-expanded={intelOpen} onClick={()=>setIntelOpen(true)}>ⓘ</button></div>
      <div className="question-area">{!recall&&q.word&&<div className="question-word">{q.word}</div>}<div className="question">{q.question}</div></div>
      {recall?<RecallCard q={q} revealed={recallShown} answer={answer} busy={busy} onReveal={revealRecall} onRate={answerCanonical}/>:<div className="options">{options.map(o=>{let cls="option";if(selectedDisplayKey===o.key)cls+=" selected";if(answer&&o.canonicalKey===answer.correctCanonicalKey)cls+=" correct";if(answer&&selectedDisplayKey===o.key&&o.canonicalKey!==answer.correctCanonicalKey)cls+=" wrong";return <button key={o.key} className={cls} onClick={()=>answerOption(o)} disabled={!!answer||busy}><span className="option-key">{o.key}</span><span>{o.text}</span></button>;})}</div>}
      {error&&<div className="result-wrap"><div className="error-box">{error}</div></div>}
      {answer&&!recall&&<div className="result-wrap"><span className={`answer-cue ${answer.correct?"good-result":"bad-result"}`}>{answer.correct?"✓ Correct":"✕ Incorrect"}</span><Explanation q={q} options={options}/></div>}
      {answer&&showDifficult&&<button className={`mastered-after ${q.mastered?"done":""}`} onClick={mastered}>{q.mastered?"✓ Mastered":"✓ Mastered"}</button>}
    </section>
    <div className={`quiz-tools ${showDifficult?"quiz-tools-four":"quiz-tools-three"}`}><button className={`btn ghost ${q.starred?"warn":""}`} onClick={toggleMark}>{q.starred?"★ Marked":"☆ Mark"}</button><AddWordSheet questionId={q.id} initialWord={q.word||""} questionText={q.question} source={title} label="📝 Add Word"/>{showDifficult&&<button className={`btn ghost ${q.difficult?"danger":""}`} onClick={toggleDifficult}>{q.difficult?"⚡ Difficult ✓":"⚡ Difficult"}</button>}<button className="btn ghost" onClick={()=>void exitQuiz()}>Ⅱ Pause</button></div>
    <div className="quiz-nav"><button className="btn ghost" disabled={idx===0} onClick={()=>move(idx-1)}>← Previous</button><button className="btn primary" onClick={()=>idx<items.length-1?move(idx+1):void finish()}>{idx===items.length-1?"Finish":"Next →"}</button></div>
    {intelOpen&&<QuestionIntelligence q={q} module={module} onClose={()=>setIntelOpen(false)}/>}
  </main>;
}

function RecallCard({q,revealed,answer,busy,onReveal,onRate}:{q:Question;revealed:boolean;answer?:PausedQuizAnswer;busy:boolean;onReveal:()=>void;onRate:(key:string)=>void}){if(!revealed&&!answer)return <div className="card" style={{textAlign:"center"}}><b>Think of the Phrasal Verb first.</b><button className="btn primary full-width" style={{marginTop:10}} onClick={onReveal}>View Answer</button></div>;const label=answer?(answer.selectedCanonicalKey==="A"?"✓ Yaad tha":answer.selectedCanonicalKey==="B"?"~ Confused":"✕ Bhool gaya"):"";return <><div className="card"><div className="question-word">{q.word}</div>{q.explanation&&<div className="explanation" style={{marginTop:0}}>{q.explanation}{q.example?`\n\nExample: ${q.example}`:""}</div>}</div><div className="action-matrix" style={{marginTop:9}}><button className="btn soft" disabled={!!answer||busy} onClick={()=>onRate("A")}>✓ Yaad tha</button><button className="btn soft" disabled={!!answer||busy} onClick={()=>onRate("B")}>~ Confused</button><button className="btn soft" disabled={!!answer||busy} onClick={()=>onRate("C")}>✕ Bhool gaya</button></div>{answer&&<div className={`result-head ${answer.selectedCanonicalKey==="A"?"good-result":"bad-result"}`} style={{marginTop:9}}><strong>{label}</strong></div>}</>}
function QuizTop({title,onBack,count}:{title:string;onBack:()=>void;count?:string}){return <div className="quiz-top"><button className="btn ghost" onClick={onBack}>← Back</button><div className="quiz-title"><div className="brand">{title}</div>{count&&<div className="quiz-count">{count}</div>}</div><div/></div>}
function LearningSignals({status}:{status?:string}){const persistent=status==="Persistent Weak";const weak=!persistent&&["Weak","Fragile"].includes(status||"");return <>{persistent&&<span className="pill signal-persistent">Persistent Weak</span>}{weak&&<span className="pill signal-weak">Weak</span>}</>}

function displayAwareText(text:string,options:DisplayOption[]){
 if(!text||!options.length)return text;
 const map=new Map(options.map(option=>[String(option.canonicalKey||"").toUpperCase(),String(option.key||"").toUpperCase()]));
 const mapped=text.replace(/\b(option\s+)([A-D])\b/gi,(_all,prefix,key)=>`${prefix}${map.get(String(key).toUpperCase())||key}`)
  .replace(/(^|[\s—–;,])([A-D])(?=\s*:)/g,(_all,prefix,key)=>`${prefix}${map.get(String(key).toUpperCase())||key}`);
 return mapped.replace(/\.\s+\./g,".");
}
function Explanation({q,options}:{q:Question;options:DisplayOption[]}){const sections:Array<[string,string|undefined,string?]>=[["Explanation",q.explanation],["Example",q.example],["Usage",q.usageNote],["Tip",q.tip,"tip"],["Remember",q.memoryAid],["Related",q.related]];return <div className="explanation">{sections.filter(([,text])=>text).map(([heading,text,kind])=><div className={kind?"tipbox":""} key={heading}><h3>{heading}</h3><p><Emphasised text={displayAwareText(text||"",options)} q={q}/></p></div>)}</div>}
function Emphasised({text,q}:{text:string;q:Question}){const terms=[q.word,"rather than","unlike","refers to"].filter((x):x is string=>!!x&&x.length>2);const matcher=new RegExp(`(${terms.map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("|")})`,"gi");return <>{text.split(matcher).map((part,index)=>terms.some(t=>part.toLowerCase()===t.toLowerCase())?<strong key={index}>{part}</strong>:<Fragment key={index}>{part}</Fragment>)}</>}
function QuestionIntelligence({q,module,onClose}:{q:Question;module:string;onClose:()=>void}){const reason=q.selectionReason||q.reason||q.status||"Selected for this practice set";return <div className="sheet-backdrop" role="dialog" aria-modal="true" aria-label="Question intelligence" onMouseDown={e=>{if(e.target===e.currentTarget)onClose();}}><section className="add-word-sheet intelligence-sheet"><div className="sheet-heading"><div><strong>Question Intelligence</strong><span>Why this question is in this session.</span></div><button className="control-icon" onClick={onClose} aria-label="Close" type="button">×</button></div><div className="intelligence-list"><div><span>Learning state</span><b>{q.status||"Not available"}</b></div><div><span>Selection</span><b>{reason}</b></div>{typeof q.attempts==="number"&&<div><span>Attempts</span><b>{q.attempts} · {q.correct??0} correct · {q.wrong??0} wrong</b></div>}{q.nextReview&&<div><span>Next review</span><b>{q.nextReview}</b></div>}<div><span>Module</span><b>{module}</b></div></div></section></div>}

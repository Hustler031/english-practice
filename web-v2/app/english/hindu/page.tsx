"use client";

import { useRouter } from "next/navigation";
import { useEffect,useMemo,useRef,useState } from "react";
import { EnglishLoading } from "@/components/english-frame";
import AddWordSheet from "@/components/add-word-sheet";
import PauseSheet from "@/components/pause-sheet";
import QuestionRevisionActions from "@/components/question-revision-actions";
import type { RevisionPayload } from "@/lib/question-revisions";
import { learnerErrorMessage,rpc,subscribeRpcFresh } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { makeDisplayOptions,type DisplayOption } from "@/lib/options";
import { splitSentenceQuestionForDisplay } from "@/lib/question-display";

type Q={
 id:string;
 centralQuestionId:string;
 bankId:string;
 confusionCategory:string;
 pairCluster:string;
 question:string;
 options:{key:string;text:string}[];
 correctKey:string;
 explanation:string;
 example?:string;
 usageNote?:string;
 tip?:string;
 memoryAid?:string;
 related?:string;
 starred?:boolean;
 difficult?:boolean;
 mastered?:boolean;
 status?:string;
 revisionVersion?:number;
};
type Progress={total:number;completed:number;roundsCompleted:number;nextRound:number;target?:number};
type LocalAnswer={selected:string;selectedCanonicalKey:string;correct:boolean;canonicalKey:string;attemptId?:string};
type AppliedRevision={questionId:string;version:number;payload:RevisionPayload};

const CATEGORY_PLAN=[
 ["Confusable Words",4],
 ["Phrasal Verb Contrast",3],
 ["Look-alike / Spelling",3],
 ["Homophone / Homonym",2],
 ["Usage / Collocation",3],
] as const;
const shortState=(status?:string)=>status==="Persistent Weak"?"PW":status==="Weak"?"Weak":status==="Fragile"?"Fragile":"";

async function applyConfusionRevisions(items:Q[]):Promise<Q[]>{
 const ids=[...new Set(items.map(q=>String(q.centralQuestionId||"").trim()).filter(Boolean))].slice(0,120);
 if(!ids.length)return items;
 try{
  const out=await rpc<{revisions?:AppliedRevision[]}>("english_get_applied_question_revisions",{p_question_ids:ids,p_cache_buster:Date.now()});
  const byId=new Map((out.revisions||[]).map(x=>[x.questionId,x]));
  return items.map(q=>{
   const revision=byId.get(q.centralQuestionId),p=revision?.payload;
   if(!revision||!p)return q;
   const key=String(p.correctKey||"").toUpperCase();
   if(!["A","B","C","D"].includes(key))return q;
   return {...q,question:p.question||q.question,options:[{key:"A",text:p.optionA},{key:"B",text:p.optionB},{key:"C",text:p.optionC},{key:"D",text:p.optionD}],correctKey:key,explanation:p.explanation||q.explanation,revisionVersion:Number(revision.version)||undefined};
  });
 }catch{return items;}
}

export default function DailyConfusionPage(){
 const ready=useAuthGuard(),router=useRouter();
 const[items,setItems]=useState<Q[]>([]);
 const[progress,setProgress]=useState<Progress|null>(null);
 const[quiz,setQuiz]=useState(false);
 const[idx,setIdx]=useState(0);
 const[answers,setAnswers]=useState<Record<string,LocalAnswer>>({});
 const[error,setError]=useState("");
 const[returnHref,setReturnHref]=useState("/english");
 const started=useRef(Date.now());
 const optionCache=useRef(new Map<string,DisplayOption[]>());

 useEffect(()=>{try{const p=new URLSearchParams(window.location.search).get("return");if(p?.startsWith("/english"))setReturnHref(p)}catch{}},[]);
 async function loadLanding(){setProgress(await rpc<Progress>("english_confusion_progress"))}
 useEffect(()=>{
  if(!ready)return;
  const off=subscribeRpcFresh<Progress>("english_confusion_progress",undefined,setProgress);
  loadLanding().catch((e:any)=>setError(learnerErrorMessage(e,"Could not load today’s Daily Confusion set.")));
  return()=>off();
 },[ready]);
 async function startQuiz(){
  setError("");
  try{
   const[q,p]=await Promise.all([rpc<Q[]>("english_get_confusion_quiz"),rpc<Progress>("english_confusion_progress")]);
   const hydrated=await applyConfusionRevisions(q);
   optionCache.current.clear();setItems(hydrated);setProgress(p);setIdx(0);setAnswers({});started.current=Date.now();
   if(hydrated.length)setQuiz(true);else setError("Today’s Daily Confusion 15 has not been published yet.");
  }catch(e:any){setError(learnerErrorMessage(e,"Could not open today’s Daily Confusion quiz. Please retry."))}
 }
 function exitQuiz(){setQuiz(false);setItems([]);setIdx(0);setAnswers({});void loadLanding().catch(()=>{})}
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(quiz&&items.length)return <ConfusionQuiz items={items} setItems={setItems} progress={progress} idx={idx} setIdx={setIdx} answers={answers} setAnswers={setAnswers} error={error} setError={setError} started={started} optionCache={optionCache} exit={exitQuiz}/>;

 const round=Math.max(1,Number(progress?.nextRound||1));
 const completed=Number(progress?.completed||0),total=Number(progress?.total||0),target=Number(progress?.target||15);
 const percent=total?Math.min(100,Math.round((completed/total)*100)):0;
 return <div className="legacy-subpage">
  <div className="legacy-subhead">
   <button className="btn ghost legacy-back" onClick={()=>router.push(returnHref)}>← Back</button>
   <div><h1>Daily Confusion 15</h1><p>High-value SSC confusion traps curated from your fixed master bank.</p></div>
  </div>
  {error&&<div className="error-box">{error}</div>}
  <section className="daily-active-card">
   <div className="daily-active-top">
    <div className="daily-active-copy"><span className="eyebrow">Central Intelligence · Daily</span><h2>{total?`${completed} / ${total} completed`:`${target} questions`}</h2><p>Fresh questions, stable confusion concepts, no random news vocabulary.</p></div>
    <div className="daily-active-side"><strong>{total?`${percent}%`:"15"}</strong><button className="btn primary" onClick={()=>void startQuiz()}>{completed>0?`Practice Again · Round ${round}`:"Start 15"}</button></div>
   </div>
   <div className="progress-track daily-active-progress"><i style={{width:`${percent}%`}}/></div>
  </section>
  <div className="hindu-word-list">
   {CATEGORY_PLAN.map(([name,count])=><article className="hindu-word-card" key={name}><div className="hindu-word-head"><div><b>{name}</b></div><span className="pill">{count}</span></div></article>)}
  </div>
  {!total&&<div className="empty-state"><h3>Today’s set is not published yet.</h3><p className="muted">The scheduled ChatGPT pipeline will create exactly 15 questions from Confusion_Master_Bank.</p></div>}
 </div>;
}

function ConfusionQuiz({items,setItems,progress,idx,setIdx,answers,setAnswers,error,setError,started,optionCache,exit}:{items:Q[];setItems:React.Dispatch<React.SetStateAction<Q[]>>;progress:Progress|null;idx:number;setIdx:(n:number)=>void;answers:Record<string,LocalAnswer>;setAnswers:React.Dispatch<React.SetStateAction<Record<string,LocalAnswer>>>;error:string;setError:(s:string)=>void;started:React.MutableRefObject<number>;optionCache:React.MutableRefObject<Map<string,DisplayOption[]>>;exit:()=>void}){
 const[pauseOpen,setPauseOpen]=useState(false);
 const[intelOpen,setIntelOpen]=useState(false);
 const[contextOpen,setContextOpen]=useState(false);
 const[contextNote,setContextNote]=useState("");
 const[contextSaved,setContextSaved]=useState(false);
 const[contextBusy,setContextBusy]=useState(false);
 const[guessed,setGuessed]=useState(false);
 const q=items[idx];
 const sentenceDisplay=q?splitSentenceQuestionForDisplay(q.question):null;
 const result=q?answers[q.id]:undefined;
 const answeredCount=Object.keys(answers).length;
 const options=useMemo(()=>{
  if(!q)return[];
  const hit=optionCache.current.get(q.id);if(hit)return hit;
  const made=makeDisplayOptions(undefined,q.options,true);optionCache.current.set(q.id,made);return made;
 },[q?.id,q?.options,optionCache]);
 const selected=result?.selected||"";
 const correctDisplayKey=result?options.find(o=>o.canonicalKey===result.canonicalKey)?.key||result.canonicalKey:"";

 useEffect(()=>{setIntelOpen(false);setContextOpen(false);setContextNote("");setContextSaved(false);setContextBusy(false);setGuessed(false)},[q?.id]);
 useEffect(()=>{const onBack=()=>{setPauseOpen(true);window.history.pushState({confusionQuiz:true},"")};window.history.pushState({confusionQuiz:true},"");window.addEventListener("popstate",onBack);return()=>window.removeEventListener("popstate",onBack)},[]);
 function move(next:number){setError("");setIntelOpen(false);setIdx(next);started.current=Date.now();window.scrollTo({top:0,left:0,behavior:"auto"})}
 async function answer(option:DisplayOption){
  if(!q||result)return;setError("");
  try{
   const out=await rpc<any>("english_submit_confusion_answer",{p_question_id:q.centralQuestionId,p_selected_key:option.canonicalKey,p_time_seconds:Math.min(180,(Date.now()-started.current)/1000),p_attempt_id:`v2-confusion-${q.centralQuestionId}-${Date.now()}`});
   if(!out.ok){setError(out.reason||"Unable to submit");return}
   setAnswers(a=>({...a,[q.id]:{selected:option.key,selectedCanonicalKey:option.canonicalKey,correct:!!out.correct,canonicalKey:String(out.correctKey||q.correctKey),attemptId:String(out.attemptId||"")||undefined}}));
  }catch(e:any){setError(learnerErrorMessage(e,"Answer is shown, but it could not be saved on this device. Please retry."))}
 }
 async function recordGuessed(){if(!q?.centralQuestionId||!result||guessed)return;setGuessed(true);setError("");try{await rpc("english_record_guess",{p_question_id:q.centralQuestionId,p_attempt_id:result.attemptId||null})}catch(e:any){setGuessed(false);setError(learnerErrorMessage(e,"Could not record that confidence signal."))}}
 async function saveContext(){
  if(!q?.centralQuestionId||!result||!contextNote.trim()||contextBusy)return;
  setContextBusy(true);setError("");
  try{await rpc("english_save_context_note",{p_question_id:q.centralQuestionId,p_note:contextNote.trim(),p_attempt_id:result.attemptId||null,p_context_snapshot:{selected_answer:result.selectedCanonicalKey,correct_answer:result.canonicalKey,module:"confusion",route:"Daily Confusion",bank_id:q.bankId,category:q.confusionCategory}});setContextSaved(true);setContextOpen(false);setContextNote("")}
  catch(e:any){setError(learnerErrorMessage(e,"Could not save this learning context."))}
  finally{setContextBusy(false)}
 }
 async function star(){
  if(!q?.centralQuestionId)return;const next=!q.starred;
  setItems(a=>a.map((x,i)=>i===idx?{...x,starred:next}:x));
  try{await rpc("english_set_starred",{p_question_id:q.centralQuestionId,p_starred:next})}
  catch(e:any){setError(learnerErrorMessage(e,"Could not update Starred right now."));setItems(a=>a.map((x,i)=>i===idx?{...x,starred:!next}:x))}
 }
 async function difficult(){
  if(!q?.centralQuestionId)return;const next=!q.difficult;
  setItems(a=>a.map((x,i)=>i===idx?{...x,difficult:next}:x));
  try{await rpc("english_set_difficult",{p_question_id:q.centralQuestionId,p_difficult:next})}
  catch(e:any){setError(learnerErrorMessage(e,"Could not update Difficult right now."));setItems(a=>a.map((x,i)=>i===idx?{...x,difficult:!next}:x))}
 }
 async function mastered(){
  if(!q?.centralQuestionId||!result||q.mastered||!window.confirm("Mark Mastered only after spaced retention is proven?"))return;
  try{await rpc("english_set_mastered",{p_question_id:q.centralQuestionId,p_mastered:true,p_require_proven:true});setItems(a=>a.map((x,i)=>i===idx?{...x,mastered:true}:x));if(idx<items.length-1)move(idx+1);else exit()}
  catch(e:any){setError(learnerErrorMessage(e,"Retention is not proven yet."))}
 }
 if(!q)return <div className="error-box">Daily Confusion question position is unavailable.</div>;
 const signal=shortState(q.status);

 return <main className="quiz quiz-with-tools">
  <div className="quiz-top"><button className="btn ghost" onClick={exit}>← Back</button><div className="quiz-title"><div className="brand">Daily Confusion · Round {progress?.nextRound||1}</div><div className="quiz-count">{idx+1} / {items.length}</div></div><div/></div>
  <div className="quiz-progress-meta"><span>Question {idx+1} of {items.length}</span><b>{answeredCount} answered</b></div>
  <div className="progress"><span style={{width:`${items.length?(answeredCount/items.length)*100:0}%`}}/></div>
  <section className="quiz-card">
   <div className="quiz-meta"><span className="pill">DAILY CONFUSION</span><span className="pill">{q.confusionCategory}</span>{signal&&<span className={`pill learning-chip ${signal==="PW"?"signal-persistent":"signal-weak"}`}>{signal}</span>}<button className="intel-button" type="button" aria-label="Question intelligence" onClick={()=>setIntelOpen(true)}>ⓘ</button></div>
   <div className="question-area">{sentenceDisplay?<div className="sentence-question"><div className="sentence-question-instruction">{sentenceDisplay.instruction}</div><div className="question sentence-question-body">{sentenceDisplay.sentence}</div></div>:<div className="question">{q.question}</div>}</div>
   <div className="options">{options.map(o=>{let cls="option";if(selected===o.key)cls+=" selected";if(result&&o.canonicalKey===result.canonicalKey)cls+=" correct";if(result&&selected===o.key&&o.canonicalKey!==result.canonicalKey)cls+=" wrong";return <button className={cls} key={o.key} onClick={()=>void answer(o)} disabled={!!result}><span className="option-key">{o.key}</span><span>{o.text}</span></button>})}</div>
   {error&&<div className="result-wrap"><div className="error-box">{error}</div></div>}
   {result&&<div className="result-wrap"><div className={`result-head ${result.correct?"good-result":"bad-result"}`}><strong>{result.correct?"✓ Correct":"✕ Incorrect"}</strong></div><ConfusionExplanation q={q} correctDisplayKey={correctDisplayKey}/>{q.centralQuestionId&&<><div className="quiz-ai-actions learning-signal-actions"><button className="btn ghost" type="button" onClick={()=>setContextOpen(v=>!v)} aria-expanded={contextOpen}>Add Context</button><button className={`btn ghost ${guessed?"warn":""}`} type="button" disabled={guessed} onClick={()=>void recordGuessed()}>{guessed?"I Guessed ✓":"I Guessed"}</button><QuestionRevisionActions key={q.centralQuestionId} questionId={q.centralQuestionId}/></div>{contextSaved&&<div className="context-saved">✓ Added to learning context</div>}{contextOpen&&<div className="ai-help-panel learning-context-panel"><input value={contextNote} maxLength={600} onChange={e=>setContextNote(e.target.value)} placeholder="What are you confusing or struggling with?"/><button className="btn primary" type="button" disabled={contextBusy||!contextNote.trim()} onClick={()=>void saveContext()}>{contextBusy?"Saving…":"Save"}</button></div>}</>}</div>}
   {result&&q.centralQuestionId&&<button className={`mastered-after ${q.mastered?"done":""}`} disabled={!!q.mastered} onClick={()=>void mastered()}>{q.mastered?"✓ Mastered":"✓ Mastered"}</button>}
  </section>
  <div className="quiz-tools hindu-quiz-tools">
   <button className={`btn ghost ${q.starred?"warn":""}`} onClick={()=>void star()}>{q.starred?"★ Starred":"☆ Star"}</button>
   <AddWordSheet questionId={q.centralQuestionId||""} initialWord={q.pairCluster} source="Daily Confusion" label="📝 Add Word"/>
   <button className={`btn ghost ${q.difficult?"danger":""}`} onClick={()=>void difficult()} disabled={!q.centralQuestionId}>{q.difficult?"⚡ Difficult ✓":"⚡ Difficult"}</button>
   <button className="btn ghost" onClick={()=>setPauseOpen(true)}>Ⅱ Pause</button>
  </div>
  <div className="quiz-nav"><button className="btn ghost" disabled={idx===0} onClick={()=>move(idx-1)}>← Previous</button><button className="btn primary" onClick={()=>idx<items.length-1?move(idx+1):exit()}>{idx===items.length-1?"Finish":"Next →"}</button></div>
  {intelOpen&&<div className="sheet-backdrop" role="dialog" aria-modal="true" onMouseDown={e=>{if(e.target===e.currentTarget)setIntelOpen(false)}}><section className="add-word-sheet intelligence-sheet"><div className="sheet-heading"><div><strong>Question Intelligence</strong><span>Canonical Central Intelligence state.</span></div><button className="control-icon" type="button" onClick={()=>setIntelOpen(false)}>×</button></div><div className="intelligence-list"><div><span>Learning state</span><b>{q.status||"New"}</b></div><div><span>Source</span><b>Confusion Master Bank</b></div><div><span>Bank ID</span><b>{q.bankId}</b></div><div><span>Category</span><b>{q.confusionCategory}</b></div>{result&&<div><span>Pair / Cluster</span><b>{q.pairCluster}</b></div>}{q.revisionVersion&&<div><span>Question version</span><b>Revision {q.revisionVersion}</b></div>}</div></section></div>}
  <PauseSheet open={pauseOpen} onSave={exit} onCancel={()=>setPauseOpen(false)}/>
 </main>;
}

function ConfusionExplanation({q,correctDisplayKey}:{q:Q;correctDisplayKey:string}){
 const sections:Array<[string,string|undefined,string?]>=[["Explanation",q.explanation],["Example",q.example],["Usage",q.usageNote],["Tip",q.tip,"tip"],["Remember",q.memoryAid],["Related",q.related]];
 return <div className="explanation"><div><h3>Correct answer</h3><p><strong>{correctDisplayKey}</strong></p></div>{sections.filter(([,text])=>text).map(([heading,text,kind])=><div className={kind?"tipbox":""} key={heading}><h3>{heading}</h3><p>{text}</p></div>)}</div>;
}

"use client";

import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
import { makeDisplayOptions, type DisplayOption } from "@/lib/options";
import AddWordSheet from "@/components/add-word-sheet";

type DailyItem = {
  sequence:number; priority:number; reason:string; quiz_date:string; status:string;
  question_id:string; topic:string; word:string; question:string; question_type:string;
  option_a:string; option_b:string; option_c:string; option_d:string; correct_key:string;
  explanation:string; tip:string; usage_note:string; example_sentence:string; memory_aid:string;
  related_words:string; source_file:string; source_page:string; starred:boolean; difficult:boolean; mastered?:boolean;
};
type DailyResult = { ok:boolean; total:number; completed:number; remaining:number; batch_date:string; target_is_maximum:boolean; items:DailyItem[] };
type AnswerState = { selectedDisplayKey:string; correct:boolean; correctCanonicalKey:string; attemptId?:string };

const positionKey=(date:string)=>`revision-v2:english:daily:${date}:current-question`;

export default function DailyPage(){
  const ready=useAuthGuard();
  const router=useRouter();
  const [batch,setBatch]=useState<DailyResult|null>(null);
  const [idx,setIdx]=useState(0);
  const [answers,setAnswers]=useState<Record<string,AnswerState>>({});
  const [busy,setBusy]=useState(false);
  const [masterBusy,setMasterBusy]=useState(false);
  const [error,setError]=useState("");
  const [intelOpen,setIntelOpen]=useState(false);
  const [contextOpen,setContextOpen]=useState(false);
  const [contextNote,setContextNote]=useState("");
  const [contextSaved,setContextSaved]=useState(false);
  const [contextBusy,setContextBusy]=useState(false);
  const [guessed,setGuessed]=useState(false);
  const started=useRef(Date.now());
  const optionCache=useRef(new Map<string,DisplayOption[]>());

  useEffect(()=>{
    if(!ready)return;
    optionCache.current.clear();
    setAnswers({});
    rpc<DailyResult>("english_resume_daily")
      .then(x=>{
        let next=0;
        try{
          const saved=localStorage.getItem(positionKey(x.batch_date));
          const found=x.items.findIndex(i=>i.question_id===saved);
          if(found>=0)next=found;
        }catch{}
        setBatch(x); setIdx(next);
        if(x.items[next])try{localStorage.setItem(positionKey(x.batch_date),x.items[next].question_id)}catch{}
        started.current=Date.now();
      })
      .catch((e:any)=>setError(learnerErrorMessage(e,"Could not open Daily Practice. Please retry.")));
  },[ready]);

  const item=batch?.items?.[idx];
  const answerState=item?answers[item.question_id]:undefined;
  const answeredCount=Object.keys(answers).length;
  const options=useMemo(()=>{
    if(!item)return[];
    const hit=optionCache.current.get(item.question_id); if(hit)return hit;
    const made=makeDisplayOptions(item.question_type,[
      {key:"A",text:item.option_a},{key:"B",text:item.option_b},{key:"C",text:item.option_c},{key:"D",text:item.option_d}
    ]);
    optionCache.current.set(item.question_id,made); return made;
  },[item?.question_id,item?.question_type,item?.option_a,item?.option_b,item?.option_c,item?.option_d]);

  useEffect(()=>{
    setIntelOpen(false); setContextOpen(false); setContextNote(""); setContextSaved(false); setContextBusy(false); setGuessed(false);
  },[item?.question_id]);

  function goHome(){router.replace("/english")}
  function move(next:number){
    const target=batch?.items?.[next]; if(!target)return;
    setError(""); setIntelOpen(false); setIdx(next);
    try{localStorage.setItem(positionKey(batch!.batch_date),target.question_id)}catch{}
    started.current=Date.now(); window.scrollTo({top:0,left:0,behavior:"auto"});
  }

  async function answer(option:DisplayOption){
    if(!item||busy||answerState)return;
    const key=item.correct_key.toUpperCase();
    setAnswers(a=>({...a,[item.question_id]:{selectedDisplayKey:option.key,correct:option.canonicalKey===key,correctCanonicalKey:key}}));
    setBusy(true); setError("");
    try{
      const out=await rpc<any>("english_submit_answer",{
        p_question_id:item.question_id,p_selected_key:option.canonicalKey,
        p_time_seconds:Math.max(0,Math.min(180,(Date.now()-started.current)/1000)),p_marked_revision:item.starred,
        p_attempt_id:`v2-${item.question_id}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`,p_module:"daily"
      });
      setAnswers(a=>({...a,[item.question_id]:{
        selectedDisplayKey:option.key,correct:!!out.is_correct,
        correctCanonicalKey:String(out.correct_key||key).toUpperCase(),attemptId:String(out.attempt_id||"")||undefined
      }}));
    }catch(e:any){setError(learnerErrorMessage(e,"Answer is shown, but it could not be saved on this device. Please retry."));}
    finally{setBusy(false);}
  }

  async function recordGuessed(){
    if(!item||!answerState||guessed)return;
    setGuessed(true); setError("");
    try{await rpc("english_record_guess",{p_question_id:item.question_id,p_attempt_id:answerState.attemptId||null});}
    catch(e:any){setGuessed(false);setError(learnerErrorMessage(e,"Could not record that confidence signal."));}
  }

  async function saveContext(){
    if(!item||!answerState||!contextNote.trim()||contextBusy)return;
    setContextBusy(true); setError("");
    try{
      await rpc("english_save_context_note",{
        p_question_id:item.question_id,p_note:contextNote.trim(),p_attempt_id:answerState.attemptId||null,
        p_context_snapshot:{selected_answer:answerState.selectedDisplayKey,correct_answer:answerState.correctCanonicalKey,module:"daily",route:"Daily Practice",reason:item.reason}
      });
      setContextSaved(true); setContextOpen(false); setContextNote("");
    }catch(e:any){setError(learnerErrorMessage(e,"Could not save this learning context."));}
    finally{setContextBusy(false);}
  }

  async function mark(){
    if(!item)return; const next=!item.starred;
    setBatch(b=>b?{...b,items:b.items.map((x,i)=>i===idx?{...x,starred:next}:x)}:b);
    try{await rpc("english_set_starred",{p_question_id:item.question_id,p_starred:next});}
    catch(e:any){setBatch(b=>b?{...b,items:b.items.map((x,i)=>i===idx?{...x,starred:!next}:x)}:b);setError(learnerErrorMessage(e,"Could not update Starred right now."));}
  }

  async function toggleMastered(){
    if(!item||masterBusy)return; const next=!item.mastered;
    if(next&&!window.confirm("Mark Mastered only after spaced retention is proven?"))return;
    setMasterBusy(true);setError("");setBatch(b=>b?{...b,items:b.items.map((x,i)=>i===idx?{...x,mastered:next}:x)}:b);
    try{await rpc("english_set_mastered",{p_question_id:item.question_id,p_mastered:next,p_require_proven:next});}
    catch(e:any){setBatch(b=>b?{...b,items:b.items.map((x,i)=>i===idx?{...x,mastered:!next}:x)}:b);setError(learnerErrorMessage(e,next?"Retention is not proven yet.":"Could not restore this question."));}
    finally{setMasterBusy(false);}
  }

  if(!ready||!batch)return <main className="shell quiz"><div className="loading-shell"><i/><i/><i/><span>{error||"Opening Daily from cache and syncing fresh data…"}</span></div></main>;
  if(!batch.items.length)return <main className="shell quiz"><div className="quiz-top"><button className="btn ghost" onClick={goHome}>← Back</button><div className="quiz-title"><div className="brand">Daily Practice</div></div><div/></div><div className="empty-state"><h2>Daily complete</h2><p className="muted">No currently actionable pending questions remain.</p></div></main>;
  if(!item)return <main className="shell"><div className="error-box">Daily position unavailable.</div></main>;

  return <main className="shell quiz quiz-with-tools">
    <div className="quiz-top"><button className="btn ghost" onClick={goHome}>← Back</button><div className="quiz-title"><div className="brand">Daily Practice</div><div className="quiz-count">{idx+1} / {batch.items.length}</div></div><div/></div>
    <div className="quiz-progress-meta"><span>Question {idx+1} of {batch.items.length}</span><b>{answeredCount} answered</b></div>
    <div className="progress"><span style={{width:`${batch.items.length?(answeredCount/batch.items.length)*100:0}%`}}/></div>
    <section className="quiz-card">
      <div className="quiz-meta"><span className="pill">{item.topic}</span><span className="pill">{item.question_id}</span>{["Persistent Weak","Weak","Fragile"].includes(item.status)&&<span className={`pill learning-chip ${item.status==="Persistent Weak"?"signal-persistent":"signal-weak"}`}>{item.status}</span>}<button className="intel-button" onClick={()=>setIntelOpen(true)} aria-label="Question intelligence">ⓘ</button></div>
      <div className="question-area">{item.word&&<div className="question-word">{item.word}</div>}<div className="question">{item.question}</div></div>
      <div className="options">{options.map(o=>{let cls="option";if(answerState?.selectedDisplayKey===o.key)cls+=" selected";if(answerState&&o.canonicalKey===answerState.correctCanonicalKey)cls+=" correct";if(answerState&&answerState.selectedDisplayKey===o.key&&o.canonicalKey!==answerState.correctCanonicalKey)cls+=" wrong";return <button key={o.key} className={cls} onClick={()=>void answer(o)} disabled={!!answerState||busy}><span className="option-key">{o.key}</span><span>{o.text}</span></button>;})}</div>
      {error&&<div className="result-wrap"><div className="error-box">{error}</div></div>}
      {answerState&&<div className="result-wrap">
        <span className={`answer-cue ${answerState.correct?"good-result":"bad-result"}`}>{answerState.correct?"✓ Correct":"✕ Incorrect"}</span>
        <DailyExplanation item={item}/>
        <div className="quiz-ai-actions learning-signal-actions">
          <button className="btn ghost" type="button" onClick={()=>setContextOpen(v=>!v)} aria-expanded={contextOpen}>Add Context</button>
          <button className={`btn ghost ${guessed?"warn":""}`} type="button" disabled={guessed} onClick={()=>void recordGuessed()}>{guessed?"I Guessed ✓":"I Guessed"}</button>
        </div>
        {contextSaved&&<div className="context-saved">✓ Added to learning context</div>}
        {contextOpen&&<div className="ai-help-panel learning-context-panel"><input value={contextNote} maxLength={600} onChange={e=>setContextNote(e.target.value)} placeholder="What are you confusing or struggling with?"/><button className="btn primary" type="button" disabled={contextBusy||!contextNote.trim()} onClick={()=>void saveContext()}>{contextBusy?"Saving…":"Save"}</button></div>}
        <button className={`mastered-after ${item.mastered?"done":""}`} aria-pressed={!!item.mastered} disabled={masterBusy} onClick={()=>void toggleMastered()}>{item.mastered?"↶ Unmaster":"✓ Mastered"}</button>
      </div>}
    </section>
    <div className="quiz-tools quiz-tools-four"><button className={`btn ghost ${item.starred?"warn":""}`} onClick={()=>void mark()}>{item.starred?"★ Marked":"☆ Mark"}</button><AddWordSheet questionId={item.question_id} initialWord={item.word||""} source="Daily Practice" label="📝 Add Word"/><button className={`btn ghost ${item.mastered?"good":""}`} aria-pressed={!!item.mastered} disabled={masterBusy} onClick={()=>void toggleMastered()}>{item.mastered?"↶ Unmaster":"✓ Mastered"}</button><button className="btn ghost" onClick={goHome}>Ⅱ Pause</button></div>
    <div className="quiz-nav"><button className="btn ghost" disabled={idx===0} onClick={()=>move(idx-1)}>← Previous</button><button className="btn primary" onClick={()=>idx<batch.items.length-1?move(idx+1):goHome()}>{idx===batch.items.length-1?"Finish":"Next →"}</button></div>
    {intelOpen&&<div className="sheet-backdrop" role="dialog" aria-modal="true" onMouseDown={e=>{if(e.target===e.currentTarget)setIntelOpen(false)}}><section className="add-word-sheet intelligence-sheet"><div className="sheet-heading"><div><strong>Question Intelligence</strong><span>Why this item is in today’s set.</span></div><button className="control-icon" onClick={()=>setIntelOpen(false)} type="button">×</button></div><div className="intelligence-list"><div><span>Selection</span><b>{item.reason}</b></div><div><span>Learning state</span><b>{item.status||"Not available"}</b></div><div><span>Module</span><b>Daily Practice</b></div></div></section></div>}
  </main>;
}

function DailyExplanation({item}:{item:DailyItem}){
  const parts:Array<[string,string|undefined,string?]>=[["Explanation",item.explanation],["Example",item.example_sentence],["Usage",item.usage_note],["Tip",item.tip,"tip"],["Remember",item.memory_aid]];
  const word=item.word;
  return <div className="explanation">{parts.filter(([,v])=>v).map(([h,v,kind])=><div className={kind?"tipbox":""} key={h}><h3>{h}</h3><p>{word?String(v).split(new RegExp(`(${word.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")})`,"gi")).map((x,i)=>x.toLowerCase()===word.toLowerCase()?<strong key={i}>{x}</strong>:x):v}</p></div>)}</div>;
}

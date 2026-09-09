"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type GrammarRule={
 ruleKey:string;ruleFamily:string;ruleTitle:string;canonicalRule:string;commonTrap:string;contrastWith:string;
 priority:number;difficulty:string;sourceName:string;sourceUrl:string;seen:boolean;state:string;attempts:number;correct:number;wrong:number;
 recentFailures:number;confidence:number;due:boolean;nextReview?:string;questionCount:number;questionFamilies:string[];
};
type ChapterData={ok:boolean;reason?:string;chapter:string;stats:{totalRules:number;covered:number;coveragePercent:number;weak:number;due:number;questions:number};available:{smart:number;weak:number;due:number;all:number};rules:GrammarRule[];readOnlyBrowsing:boolean};
type ReadQuestion={id:string;question:string;questionType?:string;options:{key:string;text:string}[];correctKey?:string;explanation?:string;tip?:string;usageNote?:string;example?:string;memoryAid?:string;difficulty?:string;questionFamily?:string;attempts?:number};
type Pick={mode:"smart"|"weak"|"due"|"all";count:number;label:string};
const modes=[["🧠","Smart Practice","smart"],["🔥","Weak","weak"],["◷","Due","due"],["▶","Practice All","all"]] as const;

export default function GrammarChapterPage(){
 const ready=useAuthGuard(),router=useRouter(),params=useParams<{chapter:string}>();
 const chapter=useMemo(()=>{try{return decodeURIComponent(String(params?.chapter||""));}catch{return String(params?.chapter||"");}},[params?.chapter]);
 const [data,setData]=useState<ChapterData|null>(null);
 const [pick,setPick]=useState<Pick|null>(null);
 const [pendingMode,setPendingMode]=useState<Pick["mode"]|null>(null);
 const [openRule,setOpenRule]=useState<string|null>(null);
 const [questionMap,setQuestionMap]=useState<Record<string,ReadQuestion[]>>({});
 const [loadingRule,setLoadingRule]=useState<string|null>(null);
 const [error,setError]=useState("");

 useEffect(()=>{
  if(!ready||!chapter)return;
  let live=true;
  rpc<ChapterData>("english_get_grammar_chapter",{p_chapter:chapter}).then(x=>{if(live){setData(x);setError("");}}).catch((e:any)=>live&&setError(learnerErrorMessage(e,"This Grammar chapter could not be opened.")));
  return()=>{live=false;};
 },[ready,chapter]);

 const load=useCallback(()=>pick?rpc<any[]>("english_get_grammar_batch",{p_mode:pick.mode,p_count:pick.count,p_chapter:chapter}):Promise.resolve([]),[pick,chapter]);
 const openQuestions=async(rule:GrammarRule)=>{
  if(openRule===rule.ruleKey){setOpenRule(null);return;}
  setOpenRule(rule.ruleKey);
  if(questionMap[rule.ruleKey]||rule.questionCount===0)return;
  setLoadingRule(rule.ruleKey);
  try{
   const out=await rpc<any>("english_get_grammar_rule_questions",{p_rule_key:rule.ruleKey});
   setQuestionMap(m=>({...m,[rule.ruleKey]:Array.isArray(out?.items)?out.items:[]}));
  }catch(e:any){setError(learnerErrorMessage(e,"Read-only questions could not be loaded."));}
  finally{setLoadingRule(null);}
 };

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(pick)return <QuizRunner title={pick.label} backHref={`/english/grammar/chapter/${encodeURIComponent(chapter)}`} load={load} module="grammarchapter" onExit={()=>setPick(null)}/>;
 if(!data&&!error)return <EnglishLoading text="Opening Grammar chapter…"/>;
 const s=data?.stats,a=data?.available,sizeChoices=[10,20,30,50];
 const start=(mode:Pick["mode"],count:number)=>setPick({mode,count,label:`Grammar · ${chapter} · ${modes.find(m=>m[2]===mode)?.[1]||mode}`});

 return <main className="phrasal-parity-page">
  <section className="pv-page-subhead"><button className="btn ghost" onClick={()=>router.push("/english/grammar")}>← Back</button><div><h1>{chapter||"Grammar"}</h1><p>{s?`${s.covered}/${s.totalRules} rules covered · ${s.questions} canonical questions`:"Focused chapter practice"}</p></div></section>
  {error&&<div className="error-box">{error}</div>}
  {data?.ok===false&&<div className="empty-state"><h2>Chapter unavailable</h2><p className="muted">This Grammar chapter is not in the active curriculum.</p></div>}
  {data?.ok!==false&&<>
   <section className="pv-legacy-card">
    <div className="pv-legacy-head"><div><h2>Chapter Practice</h2><p>Same Grammar Intelligence, restricted to this chapter.</p></div><span className="pv-concept-pill">{s?.coveragePercent??0}% covered</span></div>
    <div className="pv-legacy-metrics">
     <div><b>{s?`${s.covered} / ${s.totalRules}`:"—"}</b><small>Covered</small></div>
     <div><b>{s?.due??"—"}</b><small>Due</small></div>
     <div><b>{s?.weak??"—"}</b><small>Weak</small></div>
     <div><b>{s?.questions??"—"}</b><small>Questions</small></div>
    </div>
    <div className="pv-legacy-actions">{modes.map(([icon,label,mode])=>{
     const n=Number(a?.[mode]||0),disabled=!a||n===0;
     return <button key={mode} className="pv-legacy-action" disabled={disabled} onClick={()=>setPendingMode(mode)}><span>{icon}</span><b>{label}{n?` (${n})`:""}</b></button>;
    })}</div>
   </section>

   <section className="section-block">
    <div className="section-title-line"><h2>Rules & questions</h2><span className="pill">Read only</span></div>
    <p className="muted" style={{fontSize:12,margin:"-2px 2px 10px"}}>Open any rule to review its permanent question variants. Browsing here does not change Grammar Intelligence.</p>
    <div className="stack">{data?.rules?.map(rule=>{
     const opened=openRule===rule.ruleKey,questions=questionMap[rule.ruleKey]||[];
     return <div key={rule.ruleKey}>
      <button className="study-row full-width" type="button" aria-expanded={opened} onClick={()=>void openQuestions(rule)}>
       <span className="row-icon">{rule.seen?"✓":"·"}</span>
       <span className="row-copy"><b>{rule.ruleTitle}</b><small>{rule.ruleFamily} · {rule.questionCount} question{rule.questionCount===1?"":"s"}</small></span>
       <span className="row-status">{rule.state}{rule.due?" · due":""}</span><i>{opened?"⌄":"›"}</i>
      </button>
      {opened&&<div className="stack" style={{marginTop:8,marginBottom:8}}>
       <section className="revision-panel"><h2>{rule.ruleTitle}</h2><p>{rule.canonicalRule}</p>{rule.commonTrap&&<p><b>SSC trap:</b> {rule.commonTrap}</p>}{rule.contrastWith&&<p><b>Contrast:</b> {rule.contrastWith}</p>}</section>
       {loadingRule===rule.ruleKey&&<div className="empty-copy">Opening permanent questions…</div>}
       {!loadingRule&&rule.questionCount===0&&<div className="empty-copy">No canonical question variant has been generated for this rule yet.</div>}
       {!loadingRule&&questions.map((q,i)=><ReadOnlyQuestion key={q.id} q={q} index={i}/>) }
      </div>}
     </div>;
    })}</div>
   </section>
  </>}

  {pendingMode&&<div className="sheet-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPendingMode(null)}}><section className="pv-picker-sheet" onMouseDown={e=>e.stopPropagation()}><h3>{modes.find(m=>m[2]===pendingMode)?.[1]||"Grammar Practice"} · choose questions</h3><div className="pv-picker-counts">{sizeChoices.map(n=><button key={n} disabled={Number(a?.[pendingMode]||0)<1} onClick={()=>{start(pendingMode,n);setPendingMode(null)}}>{n}</button>)}</div><button className="btn ghost full-width" onClick={()=>setPendingMode(null)}>Cancel</button></section></div>}
 </main>;
}

function ReadOnlyQuestion({q,index}:{q:ReadQuestion;index:number}){
 return <article className="card">
  <div className="quiz-meta"><span className="pill">{q.questionFamily||q.questionType||"Grammar"}</span><span className="pill">{q.id}</span><span className="pill">Read only</span></div>
  <div className="question-area"><div className="question">{q.question}</div></div>
  <div className="options">{(q.options||[]).map(o=><div className={`option ${String(o.key).toUpperCase()===String(q.correctKey||"").toUpperCase()?"correct":""}`} key={`${q.id}-${o.key}`}><span className="option-key">{o.key}</span><span>{o.text}</span></div>)}</div>
  <div className="revision-panel" style={{marginTop:10}}><h2>Answer · {q.correctKey||"—"}</h2>{q.explanation&&<p>{q.explanation}</p>}{q.usageNote&&<p><b>Rule:</b> {q.usageNote}</p>}{q.example&&<p><b>Example:</b> {q.example}</p>}</div>
  <div className="pv-cache-note">Variant {index+1} · viewing only · no attempt recorded</div>
 </article>;
}

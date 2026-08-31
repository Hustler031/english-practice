"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Option={key:string;text:string};
type BankQuestion={id:string;category?:string;topic?:string;question:string;options:Option[];correctKey?:string;explanation?:string;questionType?:string;status?:string;mastered?:boolean;attempts?:number;correct?:number;wrong?:number;savedAt?:string;selectionReason?:string};
type Payload={ok:boolean;subject?:string;count?:number;items?:BankQuestion[];error?:string};

const subjectBySlug:Record<string,string>={
  grammar:"Grammar",voice:"Voice",narration:"Narration",vocabulary:"Vocabulary",
  "phrasal-verbs":"Phrasal Verbs","idioms-ows":"Idioms & OWS","spelling-usage":"Spelling & Usage",
};

export default function SprintBankSubjectPage({slug}:{slug:string}){
  const ready=useAuthGuard();
  const subject=subjectBySlug[slug]||"";
  const[data,setData]=useState<Payload|null>(null);
  const[error,setError]=useState("");
  const[practicing,setPracticing]=useState(false);
  const[selected,setSelected]=useState<BankQuestion|null>(null);

  const load=useCallback(async()=>{
    if(!ready||!subject)return;
    try{const out=await rpc<Payload>("english_get_sprint_bank_subject",{p_subject:subject});if(!out?.ok)throw new Error(out?.error||"Sprint Bank subject unavailable");setData(out);setError("")}catch(e:any){setError(learnerErrorMessage(e,"Could not load this Sprint Bank subject."))}
  },[ready,subject]);

  useEffect(()=>{if(ready)void load()},[ready,load]);
  const items=useMemo(()=>Array.isArray(data?.items)?data!.items!:[],[data?.items]);
  const counts=useMemo(()=>{
    let fresh=0,weak=0,learning=0;
    for(const q of items){const s=String(q.status||"New");if(s==="New")fresh++;else if(/Persistent Weak|Weak|Fragile/i.test(s))weak++;else learning++;}
    return {fresh,weak,learning};
  },[items]);
  const loadPractice=useCallback(async()=>shuffle(items),[items]);

  if(!ready)return <EnglishLoading text="Checking Sprint Bank…"/>;
  if(!subject)return <main className="sprint-bank-subject-page"><header className="module-compact-head"><Link className="compact-back" href="/english/exam">← Exam Prep</Link><div className="compact-head-copy"><strong>Sprint Bank</strong><span>Unknown subject</span></div><span/></header><div className="compact-error">This Sprint Bank subject does not exist.</div></main>;
  if(practicing)return <QuizRunner title={`${subject} Sprint Bank`} backHref={`/english/exam/bank/${slug}`} module="sprint_bank" load={loadPractice} emptyText="No saved Sprint questions are available in this subject." onExit={()=>{setPracticing(false);void load()}}/>;
  if(!data&&!error)return <EnglishLoading text={`Opening ${subject} Sprint Bank…`}/>;

  return <main className="sprint-bank-subject-page">
    <header className="module-compact-head sprint-bank-page-head"><Link className="compact-back" href="/english/exam">← Exam Prep</Link><div className="compact-head-copy"><strong>{subject}</strong><span>Sprint Question Bank · {items.length} saved</span></div><span/></header>
    {error&&<div className="compact-error" role="alert">{error}</div>}

    <section className="sprint-bank-practice-card"><div><span>SUBJECT PRACTICE</span><strong>{subject}</strong><small>Practice only the questions you deliberately kept from Sprints.</small></div><button type="button" disabled={!items.length} onClick={()=>setPracticing(true)}>Practice {items.length||""}</button></section>

    <section className="sprint-bank-mini-stats"><div><span>New</span><b>{counts.fresh}</b></div><div><span>Learning</span><b>{counts.learning}</b></div><div><span>Weak</span><b>{counts.weak}</b></div></section>

    <section className="sprint-bank-question-list"><header><strong>Saved Questions</strong><span>Tap a question to review it</span></header>{items.length?items.map((q,index)=><button type="button" key={q.id} className="sprint-bank-question-row" onClick={()=>setSelected(q)}><span className="bank-q-num">{index+1}</span><span className="bank-q-copy"><strong>{q.question}</strong><small>{pretty(q.category||q.topic||subject)} · {q.questionType||"Question"}{q.status?` · ${q.status}`:""}</small></span><span className="bank-q-arrow">›</span></button>):<p className="sprint-bank-empty">No question saved in {subject} yet. Use <b>+ Bank</b> during a Sprint when a question is worth keeping.</p>}</section>

    {selected&&<QuestionDetail question={selected} onClose={()=>setSelected(null)}/>} 
  </main>;
}

function QuestionDetail({question,onClose}:{question:BankQuestion;onClose:()=>void}){
  return <div className="sprint-bank-detail-overlay"><main className="sprint-bank-detail-page"><header className="module-compact-head"><button className="compact-back" type="button" onClick={onClose}>← Questions</button><div className="compact-head-copy"><strong>{pretty(question.category||question.topic||"Sprint Bank")}</strong><span>{question.id}</span></div><span/></header><section className="sprint-review-question-card"><div className="question-eyebrow"><span>{pretty(question.category||question.topic||"English")}</span><span>{question.questionType||"Question"}</span></div><h1>{question.question}</h1><div className="sprint-review-options">{question.options.map(option=><div key={option.key} className={option.key===question.correctKey?"correct":""}><span>{option.key}</span><b>{option.text}</b>{option.key===question.correctKey&&<em>Correct answer</em>}</div>)}</div></section>{question.explanation&&<section className="sprint-review-explanation"><strong>Explanation</strong><p>{question.explanation}</p></section>}<button className="btn primary sprint-bank-detail-close" type="button" onClick={onClose}>Back to Questions</button></main></div>;
}

function shuffle<T>(rows:T[]){const out=[...rows];for(let i=out.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[out[i],out[j]]=[out[j],out[i]];}return out;}
function pretty(value:string){return String(value||"").replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase())}

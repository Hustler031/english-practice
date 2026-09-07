"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { PageHeader } from "@/components/learner-ui";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Option={key:string;text:string};
type StateLabel="PW"|"Weak"|"Fragile"|"Learning"|"New"|"Strong"|"Mastered";
type StateCounts=Record<StateLabel,number>;
type SubjectSummary={subject:string;count:number;states:StateCounts};
type PickItem={id:string;subject:string;category?:string;topic?:string;question:string;options:Option[];correctKey?:string;explanation?:string;questionType?:string;conceptId?:string;status?:string;state:StateLabel;mastered?:boolean;attempts?:number;correct?:number;wrong?:number;lastAttempt?:string;nextReview?:string;savedAt?:string};
type Library={ok:boolean;total:number;subjects:SubjectSummary[];items:PickItem[];error?:string};
type PracticeMode="smart"|10|20|30;

const subjectBySlug:Record<string,string>={grammar:"Grammar",voice:"Voice",narration:"Narration",vocabulary:"Vocabulary","phrasal-verbs":"Phrasal Verbs","idioms-ows":"Idioms & OWS","spelling-usage":"Spelling & Usage"};
const slugBySubject:Record<string,string>=Object.fromEntries(Object.entries(subjectBySlug).map(([slug,subject])=>[subject,slug]));
const subjectHint:Record<string,string>={Grammar:"Rules · Error · Improvement",Voice:"Active ↔ Passive",Narration:"Direct ↔ Indirect",Vocabulary:"Meaning · Synonym · Antonym","Phrasal Verbs":"Phrasal usage and meaning","Idioms & OWS":"Idioms · One Word Substitution","Spelling & Usage":"Spelling · Usage · Fixed Preposition"};
const stateOrder:StateLabel[]=["PW","Weak","Fragile","Learning","New","Strong","Mastered"];

function useSprintPicks(){
 const ready=useAuthGuard();
 const[data,setData]=useState<Library|null>(null),[error,setError]=useState("");
 const load=useCallback(async()=>{if(!ready)return;try{const out=await rpc<Library>("english_get_sprint_picks_library");if(!out?.ok)throw new Error(out?.error||"Sprint Picks unavailable");setData(out);setError("")}catch(e:any){setError(learnerErrorMessage(e,"Could not load Sprint Picks."))}},[ready]);
 useEffect(()=>{if(ready)void load()},[ready,load]);
 return {ready,data,error,load};
}

export function SprintPicksCard(){
 const{ready,data}=useSprintPicks();
 if(!ready)return null;
 return <Link href="/english/targeted/sprint-picks" className="learner-overview-card tone-neutral sprint-picks-entry"><span className="learner-card-icon" aria-hidden>★</span><span className="learner-card-copy"><b>Sprint Picks</b><small>Review questions you personally kept from Sprints.</small></span><strong className="learner-card-count">{data?.total??0}</strong></Link>;
}

export function SprintPicksPage(){
 const{ready,data,error,load}=useSprintPicks();
 const[selectedSubject,setSelectedSubject]=useState("All");
 const[practiceMode,setPracticeMode]=useState<PracticeMode>("smart");
 const[practiceItems,setPracticeItems]=useState<PickItem[]|null>(null);
 const allItems=useMemo(()=>data?.items||[],[data?.items]);
 const scoped=useMemo(()=>selectedSubject==="All"?allItems:allItems.filter(x=>x.subject===selectedSubject),[allItems,selectedSubject]);
 const rows=useMemo(()=>selectedSubject==="All"?(data?.subjects||[]):(data?.subjects||[]).filter(x=>x.subject===selectedSubject),[data?.subjects,selectedSubject]);
 const startPractice=()=>{const picked=practiceMode==="smart"?smartPick(scoped,20):shuffle(scoped).slice(0,practiceMode);if(picked.length)setPracticeItems(picked)};
 if(!ready)return <EnglishLoading text="Checking Sprint Picks…"/>;
 if(practiceItems)return <QuizRunner title={`${selectedSubject==="All"?"Sprint Picks":selectedSubject} · ${practiceMode==="smart"?"Smart":practiceMode}`} backHref="/english/targeted/sprint-picks" module="sprint_bank" load={async()=>practiceItems} emptyText="No Sprint Picks are available in this selection." onExit={()=>{setPracticeItems(null);void load()}}/>;
 if(!data&&!error)return <EnglishLoading text="Opening Sprint Picks…"/>;
 return <main className="top-level-parity learner-rebuild-page sprint-picks-page"><PageHeader back={<Link href="/english/targeted" className="back-link">← Targeted Mastery</Link>} eyebrow="Your curated revision" title="Sprint Picks" subtitle="Questions you deliberately saved from Sprint reviews. This view does not change Central Intelligence."/>{error&&<div className="error-box">{error}</div>}
  <section className="sprint-picks-practice-card"><div><span>PRACTICE SAVED QUESTIONS</span><strong>{selectedSubject}</strong><small>{scoped.length} available · Smart uses existing learning state only; it does not create urgency.</small></div><div className="sprint-picks-practice-actions"><div className="sprint-picks-mode-row">{(["smart",10,20,30] as PracticeMode[]).map(m=><button key={String(m)} type="button" className={practiceMode===m?"active":""} onClick={()=>setPracticeMode(m)}>{m==="smart"?"Smart":m}</button>)}</div><button className="btn primary" type="button" disabled={!scoped.length} onClick={startPractice}>Start Practice</button></div></section>
  <section className="sprint-picks-chip-strip" aria-label="Sprint Pick subject filter"><button type="button" className={selectedSubject==="All"?"active":""} onClick={()=>setSelectedSubject("All")}>All <b>{data?.total??0}</b></button>{(data?.subjects||[]).map(s=><button type="button" key={s.subject} className={selectedSubject===s.subject?"active":""} onClick={()=>setSelectedSubject(s.subject)}>{shortSubject(s.subject)} <b>{s.count}</b></button>)}</section>
  <section className="sprint-picks-category-list"><header><strong>Categories</strong><span>Tap a row to open the saved questions</span></header>{rows.map(row=><Link key={row.subject} className={`sprint-picks-category-row ${row.count?"":"empty"}`} href={`/english/targeted/sprint-picks/${slugBySubject[row.subject]||"grammar"}`}><span className="sprint-picks-category-copy"><b>{row.subject}</b><small>{subjectHint[row.subject]||"Saved Sprint questions"}</small><em>{stateSummary(row.states)}</em></span><span className="sprint-picks-category-count"><b>{row.count}</b><i>›</i></span></Link>)}</section>
 </main>;
}

export function SprintPicksSubjectPage({slug}:{slug:string}){
 const{ready,data,error,load}=useSprintPicks();
 const subject=subjectBySlug[slug]||"";
 const[filter,setFilter]=useState<"All"|StateLabel>("All");
 const[practiceMode,setPracticeMode]=useState<PracticeMode>("smart");
 const[practiceItems,setPracticeItems]=useState<PickItem[]|null>(null);
 const[viewerIndex,setViewerIndex]=useState<number|null>(null);
 const subjectItems=useMemo(()=>data?.items.filter(x=>x.subject===subject)||[],[data?.items,subject]);
 const filtered=useMemo(()=>filter==="All"?subjectItems:subjectItems.filter(x=>x.state===filter),[subjectItems,filter]);
 const counts=useMemo(()=>Object.fromEntries(stateOrder.map(s=>[s,subjectItems.filter(x=>x.state===s).length])) as StateCounts,[subjectItems]);
 const startPractice=()=>{const scope=filter==="All"?subjectItems:filtered;const picked=practiceMode==="smart"?smartPick(scope,20):shuffle(scope).slice(0,practiceMode);if(picked.length)setPracticeItems(picked)};
 useEffect(()=>setViewerIndex(null),[filter]);
 if(!ready)return <EnglishLoading text="Checking Sprint Picks…"/>;
 if(!subject)return <main className="sprint-picks-page"><PageHeader back={<Link href="/english/targeted/sprint-picks" className="back-link">← Sprint Picks</Link>} title="Sprint Picks" subtitle="Unknown category."/></main>;
 if(practiceItems)return <QuizRunner title={`${subject} Sprint Picks`} backHref={`/english/targeted/sprint-picks/${slug}`} module="sprint_bank" load={async()=>practiceItems} emptyText="No Sprint Picks are available in this selection." onExit={()=>{setPracticeItems(null);void load()}}/>;
 if(!data&&!error)return <EnglishLoading text={`Opening ${subject} Sprint Picks…`}/>;
 return <main className="top-level-parity learner-rebuild-page sprint-picks-page"><PageHeader back={<Link href="/english/targeted/sprint-picks" className="back-link">← Sprint Picks</Link>} eyebrow="Saved from Sprint" title={subject} subtitle={`${subjectItems.length} questions · browse read-only or start an intentional practice set.`}/>{error&&<div className="error-box">{error}</div>}
  <section className="sprint-picks-practice-card compact"><div><span>SUBJECT PRACTICE</span><strong>{filter==="All"?subject:`${subject} · ${filter}`}</strong><small>{filtered.length} in this view</small></div><div className="sprint-picks-practice-actions"><div className="sprint-picks-mode-row">{(["smart",10,20,30] as PracticeMode[]).map(m=><button key={String(m)} type="button" className={practiceMode===m?"active":""} onClick={()=>setPracticeMode(m)}>{m==="smart"?"Smart":m}</button>)}</div><button className="btn primary" type="button" disabled={!filtered.length} onClick={startPractice}>Start Practice</button></div></section>
  <section className="sprint-picks-state-strip" aria-label="Learning state filter"><button type="button" className={filter==="All"?"active":""} onClick={()=>setFilter("All")}>All <b>{subjectItems.length}</b></button>{stateOrder.map(s=><button type="button" key={s} className={filter===s?"active":""} disabled={!counts[s]} onClick={()=>setFilter(s)}>{s} <b>{counts[s]}</b></button>)}</section>
  <section className="sprint-picks-question-list"><header><strong>Saved Questions</strong><span>Tap to open read-only review</span></header>{filtered.length?filtered.map((q,index)=><button type="button" key={q.id} className="sprint-picks-question-row" onClick={()=>setViewerIndex(index)}><span className={`sprint-picks-state state-${stateClass(q.state)}`}>{q.state}</span><span className="sprint-picks-question-copy"><b>{q.question}</b><small>{q.questionType||"Question"} · {q.conceptId||q.id}</small></span><span className="sprint-picks-row-arrow">›</span></button>):<p className="sprint-picks-empty">No {filter==="All"?"saved questions":filter} in {subject} yet.</p>}</section>
  {viewerIndex!==null&&filtered[viewerIndex]&&<ReadOnlyViewer items={filtered} index={viewerIndex} onIndex={setViewerIndex} onClose={()=>setViewerIndex(null)}/>} 
 </main>;
}

function ReadOnlyViewer({items,index,onIndex,onClose}:{items:PickItem[];index:number;onIndex:(n:number)=>void;onClose:()=>void}){
 const q=items[index];
 return <div className="sprint-picks-viewer"><main><header className="module-compact-head"><button className="compact-back" type="button" onClick={onClose}>← Questions</button><div className="compact-head-copy"><strong>{q.subject}</strong><span>{index+1}/{items.length} · {q.state} · {q.id}</span></div><span/></header><section className="sprint-review-question-card"><div className="question-eyebrow"><span>{q.questionType||"Question"}</span><span>Read only</span></div><h1>{q.question}</h1><div className="sprint-review-options">{q.options.map(o=><div key={o.key} className={o.key===q.correctKey?"correct":""}><span>{o.key}</span><b>{o.text}</b>{o.key===q.correctKey&&<em>Correct answer</em>}</div>)}</div></section>{q.explanation&&<section className="sprint-review-explanation"><strong>Explanation</strong><p>{q.explanation}</p></section>}<nav className="sprint-picks-viewer-nav"><button type="button" disabled={index===0} onClick={()=>onIndex(Math.max(0,index-1))}>← Previous</button><button type="button" onClick={onClose}>Back to List</button><button type="button" disabled={index>=items.length-1} onClick={()=>onIndex(Math.min(items.length-1,index+1))}>Next →</button></nav></main></div>;
}

function smartPick(rows:PickItem[],limit:number){
 const rank:Record<StateLabel,number>={PW:0,Weak:1,Fragile:2,New:3,Learning:4,Strong:5,Mastered:6};
 const sorted=[...rows].sort((a,b)=>{const dueA=!a.nextReview||new Date(a.nextReview).getTime()<=Date.now()?0:1,dueB=!b.nextReview||new Date(b.nextReview).getTime()<=Date.now()?0:1;return dueA-dueB||rank[a.state]-rank[b.state]||(b.wrong||0)-(a.wrong||0)||(new Date(a.lastAttempt||0).getTime()-new Date(b.lastAttempt||0).getTime())});
 const buckets=new Map<string,PickItem[]>();for(const q of sorted){const bucket=buckets.get(q.subject)||[];bucket.push(q);buckets.set(q.subject,bucket)}
 const out:PickItem[]=[];while(out.length<Math.min(limit,sorted.length)){let moved=false;for(const bucket of buckets.values()){const next=bucket.shift();if(next){out.push(next);moved=true;if(out.length>=limit)break}}if(!moved)break}return out;
}
function shuffle<T>(rows:T[]){const out=[...rows];for(let i=out.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[out[i],out[j]]=[out[j],out[i]];}return out}
function stateSummary(s:StateCounts){const bits:Array<[StateLabel,string]>=[["PW","PW"],["Weak","weak"],["Fragile","fragile"],["New","new"]];const shown=bits.filter(([k])=>(s?.[k]||0)>0).map(([k,label])=>`${s[k]} ${label}`);return shown.length?shown.join(" · "):`${s?.Learning||0} learning · ${s?.Strong||0} strong · ${s?.Mastered||0} mastered`}
function shortSubject(value:string){return value==="Phrasal Verbs"?"Phrasal":value==="Idioms & OWS"?"Idioms/OWS":value==="Spelling & Usage"?"Spelling":value}
function stateClass(value:StateLabel){return value.toLowerCase().replaceAll(" ","-")}

"use client";

import Link from "next/link";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { gkRpc, subscribeGkFresh } from "@/lib/gk-rpc";
import { useAuthGuard } from "@/lib/use-auth";
import type { GkProgress } from "@/lib/gk-types";

type SubjectInsight={subject:string;total:number;seen:number;unseen:number;persistentWeak:number;weak:number;fragile:number;mastered:number;guessed:number;unseenHighYield:number;retention:number;coverage:number;attention_score:number};
type SeriesInsight={seriesId:string;seriesKind:string;title:string;total:number;exposed:number;weak:number;mastered:number;completion:number;retention:number};
type Dashboard={ok:boolean;overview:{readiness:number;retention:number;bankExposure:number;provenKnowledge:number;weakBurden:number;persistentWeak:number;unresolvedGuesses:number;due:number;teacherContentCompletion:number;questionBankExposure:number;knowledgeRetention:number};needsAttention:SubjectInsight[];strongest:SubjectInsight[];subjects:SubjectInsight[];seriesProgress:SeriesInsight[];thisWeek:{factsSeen:number;weakResolved:number;unresolvedGuesses:number}};
type LearningSupport={verified_explanation?:string;exam_trap?:string;memory_tip?:string;confusion_contrast?:string;verification_status?:string;verification_source?:string;last_verified_at?:string;[key:string]:unknown};
type Story={ok:boolean;conceptId?:string;title?:string;subject?:string;history?:{questions:number;attempts:number;correct:number;wrong:number;guessed:number;firstSeen?:string;lastAttempt?:string;nextRecall?:string;currentState?:string};sources?:Array<{seriesTitle:string;seriesKind:string;lectureKey?:string;sourceLabel?:string;sourcePage?:string;sourceDate?:string}>;questions?:Array<{questionId:string;topic:string;state:string;attempts:number;wrong:number;guessed:number;nextRecall?:string}>;learningSupport?:LearningSupport;confusions?:Array<{label?:string;conceptA:string;conceptB:string;evidenceCount:number;verified:boolean}>};

const num=(v:unknown)=>Number(v||0);
const pct=(v:unknown)=>`${Math.round(num(v)*10)/10}%`;
const quiz=(p:Record<string,string|number>)=>`/gk/quiz?${new URLSearchParams(Object.entries(p).map(([k,v])=>[k,String(v)]))}`;
function dateLabel(v?:string){if(!v)return "—";const d=new Date(v);return Number.isNaN(d.getTime())?v:d.toLocaleDateString(undefined,{day:"numeric",month:"short",year:"numeric"});}
function Metric({value,label,copy}:{value:string|number;label:string;copy?:string}){return <div className="gk-intel-metric"><strong>{value}</strong><span>{label}</span>{copy&&<small>{copy}</small>}</div>}
function ProgressBar({value}:{value:number}){return <div className="gk-intel-bar"><i style={{width:`${Math.max(0,Math.min(100,value))}%`}}/></div>}
function Fold({eyebrow,title,meta,children}:{eyebrow:string;title:string;meta:string;children:ReactNode}){return <details className="gk-intel-fold"><summary><div><span>{eyebrow}</span><b>{title}</b><small>{meta}</small></div></summary><div className="gk-intel-fold-body">{children}</div></details>}

export default function GkIntelligencePage(){
 const ready=useAuthGuard();
 const[dash,setDash]=useState<Dashboard|null>(null),[legacy,setLegacy]=useState<GkProgress|null>(null),[story,setStory]=useState<Story|null>(null),[subject,setSubject]=useState(""),[error,setError]=useState("");
 useEffect(()=>{if(!ready)return;const p=new URLSearchParams(window.location.search);setSubject(p.get("subject")||"");const concept=p.get("concept")||"",question=p.get("question")||"",storyArgs={p_concept_id:concept||null,p_question_id:question||null};let live=true;setError("");setStory(null);const unsubDash=subscribeGkFresh<Dashboard>("gk_get_intelligence_dashboard",undefined,x=>{if(live&&x?.ok)setDash(x)}),unsubProgress=subscribeGkFresh<GkProgress>("gk_get_progress",undefined,x=>{if(live&&x?.ok)setLegacy(x)}),unsubStory=concept||question?subscribeGkFresh<Story>("gk_get_knowledge_story",storyArgs,x=>{if(live&&x?.ok)setStory(x)}):()=>{};Promise.allSettled([
   gkRpc<Dashboard>("gk_get_intelligence_dashboard").then(x=>{if(live&&x?.ok)setDash(x)}),
   gkRpc<GkProgress>("gk_get_progress").then(x=>{if(live&&x?.ok)setLegacy(x)}),
   concept||question?gkRpc<Story>("gk_get_knowledge_story",storyArgs).then(x=>{if(live)setStory(x)}):Promise.resolve()
 ]).then(rows=>{if(live&&rows.some(x=>x.status==="rejected"))setError("Some GK intelligence could not be refreshed.")});return()=>{live=false;unsubDash();unsubProgress();unsubStory();};},[ready]);
 const selected=useMemo(()=>dash?.subjects.find(x=>x.subject===subject)||null,[dash,subject]);
 if(!ready)return <main className="gk-intel-page"><div className="loading-copy">Checking session…</div></main>;
 if(!dash)return <main className="gk-intel-page"><div className="loading-copy">Loading GK intelligence…</div>{error&&<p>{error}</p>}</main>;
 if(story?.ok)return <KnowledgeStory story={story}/>;
 if(selected)return <SubjectDetail row={selected} weakConcepts={(legacy?.weakConcepts||[]).filter(x=>x.subject===selected.subject)}/>;
 const o=dash.overview,worst=dash.needsAttention?.[0],best=dash.strongest?.[0],weakConcepts=legacy?.weakConcepts||[];
 return <main className="gk-intel-page">
  <section className="gk-intel-title"><div><span>Progress</span><h1>GK Readiness</h1><p>See the exam signal first. Tap a section below only when you want the underlying evidence.</p></div></section>
  {error&&<div className="gk-intel-notice">{error}</div>}
  <section className="gk-intel-kpis">
   <Metric value={pct(o.readiness)} label="GK readiness" copy="Composite exam-readiness signal"/>
   <Metric value={pct(o.retention)} label="Retention" copy="Spaced recall accuracy"/>
   <Metric value={pct(o.bankExposure)} label="Bank exposure" copy="Questions genuinely seen"/>
   <Metric value={o.weakBurden} label="Weak burden" copy={`${o.persistentWeak} persistent · ${o.unresolvedGuesses} unresolved guesses`}/>
  </section>
  <section className="gk-intel-grid2">
   <article className="gk-intel-card"><div className="gk-intel-cardhead"><div><span>Needs Attention</span><h2>{worst?.subject||"No critical subject"}</h2></div>{worst&&<b>{worst.persistentWeak>0?"Critical":"Needs work"}</b>}</div>{worst&&<><p>{worst.persistentWeak} persistent weak · {worst.weak+worst.fragile} weak/fragile · {worst.guessed} unresolved guesses</p><div className="gk-intel-actions"><a href={`/gk/intelligence?subject=${encodeURIComponent(worst.subject)}`}>Open detail</a><Link href={quiz({mode:"weak",lane:"MIXED",subject:worst.subject,count:20,title:`${worst.subject} · Weak Repair`})}>Practice weak</Link></div></>}</article>
   <article className="gk-intel-card"><div className="gk-intel-cardhead"><div><span>Strongest</span><h2>{best?.subject||"Build more evidence"}</h2></div>{best&&<b>{pct(best.retention)}</b>}</div>{best&&<><p>{pct(best.coverage)} exposed · {best.mastered} proven mastered</p><ProgressBar value={best.retention}/>{best&&<div className="gk-intel-actions"><a href={`/gk/intelligence?subject=${encodeURIComponent(best.subject)}`}>Open detail</a></div>}</>}</article>
  </section>
  <section className="gk-intel-section-stack" aria-label="Progress details">
   <Fold eyebrow="This Week" title="Learning movement" meta={`${dash.thisWeek.factsSeen} facts seen · ${dash.thisWeek.weakResolved} weak resolved · ${dash.thisWeek.unresolvedGuesses} unresolved guesses`}>
    <div className="gk-intel-week"><Metric value={dash.thisWeek.factsSeen} label="Facts seen"/><Metric value={dash.thisWeek.weakResolved} label="Weak resolved"/><Metric value={dash.thisWeek.unresolvedGuesses} label="Unresolved guesses"/></div>
   </Fold>
   <Fold eyebrow="Progress meanings" title="Four different truths" meta={`Teacher ${pct(o.teacherContentCompletion)} · Bank ${pct(o.questionBankExposure)} · Retention ${pct(o.knowledgeRetention)} · Proven ${pct(o.provenKnowledge)}`}>
    <div className="gk-intel-progress-truth"><div><span>Teacher Content Completion</span><b>{pct(o.teacherContentCompletion)}</b><ProgressBar value={o.teacherContentCompletion}/></div><div><span>Question Bank Exposure</span><b>{pct(o.questionBankExposure)}</b><ProgressBar value={o.questionBankExposure}/></div><div><span>Knowledge Retention</span><b>{pct(o.knowledgeRetention)}</b><ProgressBar value={o.knowledgeRetention}/></div><div><span>Proven Knowledge</span><b>{pct(o.provenKnowledge)}</b><ProgressBar value={o.provenKnowledge}/></div></div>
   </Fold>
   <Fold eyebrow="Teacher Course" title="Series progress" meta={`${dash.seriesProgress.length} source series · tap to inspect completion and weak load`}>
    <div className="gk-intel-series">{dash.seriesProgress.map(x=><div className="gk-intel-seriesrow" key={x.seriesId}><div><b>{x.title}</b><small>{x.seriesKind.replaceAll("_"," ")} · {x.exposed}/{x.total} exposed · {x.weak} weak</small></div><strong>{pct(x.completion)}</strong><ProgressBar value={x.completion}/></div>)}</div><a className="gk-intel-fold-link" href="/gk/teacher">Open Teacher PYQ source library</a>
   </Fold>
   <Fold eyebrow="SSC Coverage" title="Subject readiness" meta={`${dash.subjects.length} subjects · tap, then open any subject for its weak/retention detail`}>
    <div className="gk-intel-subjects">{dash.subjects.map(x=><a href={`/gk/intelligence?subject=${encodeURIComponent(x.subject)}`} className="gk-intel-subject" key={x.subject}><div><b>{x.subject}</b><small>{x.seen}/{x.total} seen · retention {pct(x.retention)} · {x.unseenHighYield} unseen teacher PYQ</small></div><span>{x.persistentWeak?`${x.persistentWeak} PW`:x.weak+x.fragile?`${x.weak+x.fragile} weak`:"Open ›"}</span></a>)}</div>
   </Fold>
   {weakConcepts.length>0&&<Fold eyebrow="Knowledge Story" title="Concepts that need repair" meta={`${Math.min(10,weakConcepts.length)} priority concept families · tap one for history and source evidence`}>
    <div className="gk-intel-subjects">{weakConcepts.slice(0,10).map(x=><a href={`/gk/intelligence?concept=${encodeURIComponent(x.conceptId)}`} className="gk-intel-subject" key={x.conceptId}><div><b>{x.topic||x.conceptId}</b><small>{x.subject} · {x.persistentWeak} persistent · {x.weak} weak · retention {pct(x.retentionAccuracy)}</small></div><span>Story ›</span></a>)}</div>
   </Fold>}
  </section>
 </main>;
}

function SubjectDetail({row,weakConcepts}:{row:SubjectInsight;weakConcepts:GkProgress["weakConcepts"]}){
 return <main className="gk-intel-page"><div className="gk-intel-back"><a href="/gk/intelligence">← Progress</a></div><section className="gk-intel-title"><div><span>Subject detail</span><h1>{row.subject}</h1><p>Coverage and retention stay separate; weak evidence remains actionable.</p></div><Link className="gk-intel-primary" href={quiz({mode:"weak",lane:"MIXED",subject:row.subject,count:20,title:`${row.subject} · Weak Repair`})}>Practice Weak</Link></section><section className="gk-intel-kpis"><Metric value={pct(row.coverage)} label="Coverage"/><Metric value={row.seen} label="Seen"/><Metric value={pct(row.retention)} label="Retention"/><Metric value={row.persistentWeak} label="Persistent Weak"/></section><Fold eyebrow="State breakdown" title="What needs work" meta={`${row.weak} weak · ${row.fragile} fragile · ${row.mastered} proven · ${row.unseenHighYield} unseen teacher PYQ`}><div className="gk-intel-progress-truth"><div><span>Weak</span><b>{row.weak}</b></div><div><span>Fragile</span><b>{row.fragile}</b></div><div><span>Proven Mastered</span><b>{row.mastered}</b></div><div><span>Unseen Teacher PYQ</span><b>{row.unseenHighYield}</b></div></div></Fold><Fold eyebrow="Weak Topics" title="Repair by concept" meta={weakConcepts.length?`${weakConcepts.length} concept families surfaced`:`No weak concept family is currently surfaced`}><div className="gk-intel-subjects">{weakConcepts.length?weakConcepts.slice(0,20).map(x=><a href={`/gk/intelligence?concept=${encodeURIComponent(x.conceptId)}`} className="gk-intel-subject" key={x.conceptId}><div><b>{x.topic||x.conceptId}</b><small>{x.persistentWeak} persistent · {x.weak} weak · retention {pct(x.retentionAccuracy)}</small></div><span>Story ›</span></a>):<div className="gk-intel-empty">No weak concept family is currently surfaced for this subject.</div>}</div></Fold><div className="gk-intel-actions"><Link href={quiz({mode:"new",lane:"MAIN",subject:row.subject,count:20,title:`${row.subject} · Topic-wise PYQ`})}>Topic-wise PYQ</Link><Link href={quiz({mode:"random",lane:"MIXED",subject:row.subject,count:25,title:`${row.subject} · Mixed Retrieval`})}>Mixed retrieval</Link></div></main>;
}

function KnowledgeStory({story}:{story:Story}){
 const h=story.history||{questions:0,attempts:0,correct:0,wrong:0,guessed:0};
 const support:LearningSupport=story.learningSupport||{};
 return <main className="gk-intel-page"><div className="gk-intel-back"><a href="/gk/intelligence">← Progress</a></div><section className="gk-intel-title"><div><span>Knowledge Story</span><h1>{story.title||story.conceptId||"Concept"}</h1><p>{story.subject||"GK"} · one knowledge family across every teacher/source appearance.</p></div>{story.conceptId&&<Link className="gk-intel-primary" href={quiz({mode:"weak",lane:"MIXED",concept:story.conceptId,count:20,title:`${story.title||"Concept"} · Repair`})}>Practice concept</Link>}</section><section className="gk-intel-kpis"><Metric value={h.attempts} label="Attempts"/><Metric value={h.correct} label="Correct"/><Metric value={h.wrong} label="Wrong"/><Metric value={h.guessed} label="Guessed"/></section><Fold eyebrow="Current evidence" title={h.currentState||"Learning"} meta={`Next recall ${dateLabel(h.nextRecall)}`}><div className="gk-intel-timeline"><div><span>First seen</span><b>{dateLabel(h.firstSeen)}</b></div><div><span>Last attempt</span><b>{dateLabel(h.lastAttempt)}</b></div><div><span>Questions in family</span><b>{h.questions}</b></div></div></Fold><Fold eyebrow="Sources" title="Teacher provenance" meta={`${story.sources?.length||0} source appearances`}><div className="gk-intel-subjects">{(story.sources||[]).map((s,i)=><div className="gk-intel-subject" key={`${s.seriesTitle}-${s.lectureKey}-${i}`}><div><b>{s.seriesTitle}</b><small>{[s.lectureKey,s.sourceLabel,s.sourcePage&&`Page ${s.sourcePage}`].filter(Boolean).join(" · ")}</small></div><span>{s.seriesKind?.replaceAll("_"," ")}</span></div>)}</div></Fold>{Object.keys(support).length>0&&<Fold eyebrow="Learning support" title="Verified enrichment" meta={`${support.verification_status||"UNVERIFIED"} · teacher content remains authority`}><div>{support.verified_explanation&&<p><b>Explanation:</b> {support.verified_explanation}</p>}{support.exam_trap&&<p><b>Exam trap:</b> {support.exam_trap}</p>}{support.memory_tip&&<p><b>Memory tip:</b> {support.memory_tip}</p>}{support.confusion_contrast&&<p><b>Contrast:</b> {support.confusion_contrast}</p>}</div></Fold>}{(story.confusions?.length||0)>0&&<Fold eyebrow="Confusion engine" title="Nearby concepts" meta={`${story.confusions!.length} confusion relationships`}><div className="gk-intel-subjects">{story.confusions!.map((c,i)=><div className="gk-intel-subject" key={i}><div><b>{c.label||`${c.conceptA} ↔ ${c.conceptB}`}</b><small>{c.evidenceCount} evidence signals</small></div><span>{c.verified?"Verified":"Review"}</span></div>)}</div></Fold>}</main>;
}

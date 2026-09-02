"use client";

import Link from "next/link";
import { useEffect,useMemo,useState } from "react";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary={concepts:number;mapped_questions:number;unresolved_mappings:number;needs_review:number;seen:number;secure:number;exam_ready:number;weak:number;retention_risk:number};
type Row={concept_id:string;domain:string;skill_family:string;name:string;exam_relevance:string;coverage_state:string;confidence_score:number;attempts:number;wrong:number;next_review?:string};
type ContextRow={note_id:string;question_id:string;note:string;processing_status:string;diagnosis?:{type?:string;related_terms?:string[]};created_at:string};
type Activity={id:number;type:string;title:string;detail?:string;questionId?:string;conceptId?:string;at:string};
type TodayActivity={ok:boolean;count:number;items:Activity[]};
type Signals={context_total:number;context_done:number;context_pending:number;context_failed:number;guessed_total:number;guessed_open?:number;confusions_open?:number;context_targeted:number;recent_context:ContextRow[];today_activity?:TodayActivity};
type TargetedSummary={active:number;dueNow:number;confusions:number;needLearning:number;transferChecks:number;retentionChecks:number;recovered:number};
type Confusion={confusionId:string;status:string;primaryName:string;relatedName:string;primaryQuestionId?:string;relatedQuestionId?:string;note?:string};
type FocusRow={questionId:string;conceptId?:string;name:string;skillFamily?:string;reason?:string;nextReview?:string};
type Recovered={concept_id?:string;conceptId?:string;name:string;at:string;source:string};
type Hub={ok:boolean;summary:TargetedSummary;confusions:Confusion[];needLearning:FocusRow[];transferChecks:FocusRow[];retentionChecks:FocusRow[];recovered:Recovered[]};
type QuestionLabel={questionId:string;displayName:string;topic?:string;conceptId?:string;conceptName?:string};
type LabelsResponse={ok:boolean;items:QuestionLabel[]};
type InsightRow={key:string;title:string;detail:string;href?:string;tone:"fix"|"soon"|"good"|"later"};

const isDue=(value?:string)=>!value||new Date(value).getTime()<=Date.now();
const enc=(value:string)=>encodeURIComponent(value);

export default function LearningInsightsPage(){
 const ready=useAuthGuard();
 const[summary,setSummary]=useState<Summary|null>(null);
 const[signals,setSignals]=useState<Signals|null>(null);
 const[hub,setHub]=useState<Hub|null>(null);
 const[priority,setPriority]=useState<Row[]>([]);
 const[labels,setLabels]=useState<Record<string,QuestionLabel>>({});
 const[showAllToday,setShowAllToday]=useState(false);
 const[error,setError]=useState("");
 const[loading,setLoading]=useState(true);

 useEffect(()=>{
  if(!ready)return;let live=true;setLoading(true);setError("");
  Promise.all([
   rpc<Summary>("english_get_concept_intelligence_summary"),
   rpc<Signals>("english_get_learning_signal_summary"),
   rpc<Hub>("english_get_targeted_mastery"),
   rpc<Row[]>("english_get_concept_intelligence_detail",{p_kind:"weak"}),
  ]).then(async([s,g,h,r])=>{
   if(!live)return;setSummary(s);setSignals(g);setHub(h);setPriority(Array.isArray(r)?r.slice(0,8):[]);
   const ids=[
    ...(g.today_activity?.items||[]).map(x=>x.questionId),...g.recent_context.map(x=>x.question_id),
    ...h.needLearning.map(x=>x.questionId),...h.transferChecks.map(x=>x.questionId),...h.retentionChecks.map(x=>x.questionId),
    ...h.confusions.flatMap(x=>[x.primaryQuestionId,x.relatedQuestionId]),
   ].filter(Boolean) as string[];
   const unique=[...new Set(ids)].slice(0,120);
   if(unique.length)try{const out=await rpc<LabelsResponse>("english_get_question_labels",{p_question_ids:unique});if(live)setLabels(Object.fromEntries((out.items||[]).map(x=>[x.questionId,x])))}catch{}
  }).catch((e:any)=>live&&setError(learnerErrorMessage(e,"Could not load Learning Insights."))).finally(()=>live&&setLoading(false));
  return()=>{live=false};
 },[ready]);

 const labelFor=(row:FocusRow)=>labels[row.questionId]?.displayName||row.name||"English practice";
 const questionHref=(row:FocusRow)=>`/english/targeted?question=${enc(row.questionId)}&title=${enc(labelFor(row))}`;
 const todayItems=Array.isArray(signals?.today_activity?.items)?signals!.today_activity!.items:[];
 const visibleToday=todayItems.slice(0,showAllToday?12:6);

 const fixNow=useMemo<InsightRow[]>(()=>{
  if(!hub)return[];
  const conf=hub.confusions.map(c=>({key:`c-${c.confusionId}`,title:`${c.primaryName} vs ${c.relatedName}`,detail:"You flagged this confusion.",href:`/english/targeted?confusion=${enc(c.confusionId)}`,tone:"fix" as const}));
  const transfer=hub.transferChecks.filter(r=>isDue(r.nextReview)).map(r=>({key:`t-${r.questionId}`,title:labelFor(r),detail:reasonText(r,"Fresh understanding check."),href:questionHref(r),tone:"fix" as const}));
  const retention=hub.retentionChecks.filter(r=>isDue(r.nextReview)).map(r=>({key:`r-${r.questionId}`,title:labelFor(r),detail:"Spaced recall is ready.",href:questionHref(r),tone:"fix" as const}));
  const learning=hub.needLearning.filter(r=>isDue(r.nextReview)).map(r=>({key:`n-${r.questionId}`,title:labelFor(r),detail:reasonText(r,"Focused repair from recent evidence."),href:questionHref(r),tone:"fix" as const}));
  return [...conf,...transfer,...retention,...learning].slice(0,6);
 },[hub,labels]);
 const checkSoon=useMemo<InsightRow[]>(()=>{
  if(!hub)return[];
  const transfer=hub.transferChecks.filter(r=>r.nextReview&&!isDue(r.nextReview)).map(r=>({key:`st-${r.questionId}`,title:labelFor(r),detail:"Fresh understanding check.",href:questionHref(r),tone:"soon" as const}));
  const learning=hub.needLearning.filter(r=>r.nextReview&&!isDue(r.nextReview)).map(r=>({key:`sn-${r.questionId}`,title:labelFor(r),detail:"A focused check is coming up.",href:questionHref(r),tone:"soon" as const}));
  return [...transfer,...learning].slice(0,5);
 },[hub,labels]);
 const improving=useMemo<InsightRow[]>(()=>hub?hub.recovered.slice(0,5).map((r,i)=>({key:`i-${r.concept_id||r.conceptId||r.name}-${i}`,title:r.name,detail:"Recent evidence is moving this in the right direction.",tone:"good" as const})):[],[hub]);
 const scheduled=useMemo<InsightRow[]>(()=>hub?hub.retentionChecks.filter(r=>r.nextReview&&!isDue(r.nextReview)).slice(0,6).map(r=>({key:`l-${r.questionId}`,title:labelFor(r),detail:`Next recall check: ${friendlyDate(r.nextReview)}.`,href:questionHref(r),tone:"later" as const})):[],[hub,labels]);

 if(!ready)return <main className="top-level-parity"><div className="loading-copy">Checking session…</div></main>;
 return <main className="top-level-parity learning-intelligence-page learner-insights-page">
  <section className="page-intro intelligence-intro learner-insights-intro">
   <Link href="/english/revision" className="back-link">← Revision</Link>
   <span className="intelligence-kicker">Your study plan</span>
   <h1>Learning Insights</h1>
   <p>See what needs attention and why.</p>
  </section>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Refreshing your learning plan…</div>:<>

   <section className="insights-today-card">
    <div className="insights-today-heading"><div><span className="section-cap">TODAY’S INFO</span><h2>What changed today</h2><p>Real study actions, shown by the question or concept you know.</p></div><strong>{signals?.today_activity?.count??0}</strong></div>
    {visibleToday.length?<div className="insights-today-list">{visibleToday.map(item=><TodayRow key={item.id} item={item} name={activityName(item,labels)}/>)}</div>:<div className="today-activity-empty">No learning-plan change was needed today yet.</div>}
    {todayItems.length>6&&<button className="insights-more-button" type="button" onClick={()=>setShowAllToday(v=>!v)}>{showAllToday?"Show less":"Show more today"}<span>{showAllToday?"↑":`+${Math.min(6,todayItems.length-6)}`}</span></button>}
   </section>

   <InsightSection title="FIX NOW" subtitle="The highest-value practice that is ready now." rows={fixNow} empty="Nothing urgent needs repair right now." actionHref="/english/targeted?view=fix-now" actionLabel="Open focused practice"/>
   <InsightSection title="CHECK SOON" subtitle="Fresh proof that will be useful next." rows={checkSoon} empty="No extra fresh check is waiting right now."/>
   <InsightSection title="IMPROVING" subtitle="Recent evidence is strengthening these areas." rows={improving} empty="Improving concepts will appear after successful repair evidence."/>
   <InsightSection title="SCHEDULED FOR LATER" subtitle="Spaced recall is waiting for the right time." rows={scheduled} empty="No spaced checks are scheduled for later right now." actionHref="/english/targeted?view=waiting" actionLabel="Open schedule"/>

   <section className="insights-how-card">
    <details className="insights-how-details"><summary><span><b>How your learning plan works</b><small>Why something appears now, soon, or later</small></span><i>›</i></summary><div className="insights-how-copy"><p><b>Fix Now</b> prioritises mistakes, uncertainty and confusions that can improve your score immediately.</p><p><b>Check Soon</b> asks for fresh proof so recognition is not mistaken for mastery.</p><p><b>Improving</b> means newer evidence is stronger than the earlier weakness or uncertainty.</p><p><b>Scheduled for Later</b> protects retention by waiting before testing again.</p><details className="insights-technical-details"><summary>Learning details</summary><div className="insights-tech-grid"><Metric label="Exam-ready" value={summary?.exam_ready??0}/><Metric label="Secure" value={summary?.secure??0}/><Metric label="Needs work" value={summary?.weak??0}/><Metric label="Retention risk" value={summary?.retention_risk??0}/></div><div className="insights-signal-line"><span>Context used <b>{signals?.context_done??0}</b></span><span>Guessed awaiting proof <b>{signals?.guessed_open??0}</b></span><span>Open confusions <b>{signals?.confusions_open??0}</b></span></div>{priority.length>0&&<div className="insights-tech-concepts">{priority.map(row=><div key={row.concept_id}><span>{row.name}</span><small>{Math.round(Number(row.confidence_score)||0)}% confidence · {row.attempts} attempts</small></div>)}</div>}<p className="muted">Mapped questions: {summary?.mapped_questions??0} · unresolved mappings: {summary?.unresolved_mappings??0} · context failures: {signals?.context_failed??0}</p></details></div></details>
   </section>
  </>}
 </main>;
}

function TodayRow({item,name}:{item:Activity;name:string}){const tone=activityTone(item.type);return <article className={`insights-today-row ${tone}`}><span className="insights-activity-mark"/><div><b>{name}</b><p>{activityText(item)}</p><small>{new Date(item.at).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"})}</small></div></article>}
function InsightSection({title,subtitle,rows,empty,actionHref,actionLabel}:{title:string;subtitle:string;rows:InsightRow[];empty:string;actionHref?:string;actionLabel?:string}){return <section className={`insight-category-card category-${rows[0]?.tone||"later"}`}><div className="insight-category-head"><div><span className="section-cap">{title}</span><p>{subtitle}</p></div>{actionHref&&<Link href={actionHref}>{actionLabel||"Open"} ›</Link>}</div>{rows.length?<div className="insight-category-list">{rows.map(row=><article className={`insight-category-row tone-${row.tone}`} key={row.key}><span className="insight-row-icon">{row.tone==="fix"?"!":row.tone==="soon"?"↗":row.tone==="good"?"✓":"◷"}</span><div><b>{row.title}</b><p>{row.detail}</p></div>{row.href&&<Link href={row.href}>{row.tone==="later"?"Open":"Practice"} ›</Link>}</article>)}</div>:<div className="insight-empty">{empty}</div>}</section>}
function Metric({label,value}:{label:string;value:number}){return <div><strong>{value}</strong><span>{label}</span></div>}
function activityName(item:Activity,labels:Record<string,QuestionLabel>){if(item.questionId&&labels[item.questionId]?.displayName)return labels[item.questionId].displayName;return cleanActivityTitle(item.title)}
function cleanActivityTitle(value:string){return String(value||"Learning update").replace(/background analysis/gi,"Learning check").replace(/\s*→\s*Targeted/gi,"").replace(/context added to Targeted/gi,"Learning note").replace(/I Guessed\s*→\s*transfer check/gi,"Fresh understanding check")}
function activityText(item:Activity){const t=String(item.type||"");if(t==="guess_transfer")return"You marked this as guessed. A fresh understanding check was added.";if(t==="transfer_generated")return"A fresh related question was prepared because the bank had no suitable alternate.";if(t==="context_ai_no_action")return"Your note was understood; no extra practice was needed.";if(t==="context_ai_queued")return"Your note is being checked in the background while you keep studying.";if(t.includes("context")&&String(item.detail||"").toLowerCase().includes("retention"))return"Your note added a spaced understanding check.";if(t.includes("context")&&String(item.detail||"").toLowerCase().includes("confusion"))return"Your note added focused practice for this confusion.";if(t.includes("context"))return"Your note changed what the app will practise next.";return String(item.detail||"Your learning plan was updated.").replace(/background analysis/gi,"learning check").replace(/Targeted/gi,"focused practice")}
function activityTone(type:string){if(type.includes("generated")||type.includes("transfer"))return"tone-blue";if(type.includes("no_action"))return"tone-green";if(type.includes("queued"))return"tone-amber";return"tone-coral"}
function reasonText(row:FocusRow,fallback:string){const r=String(row.reason||"").toLowerCase();if(r.includes("guess"))return"One independent check remaining.";if(r.includes("confusion"))return"Fresh check from a confusion you noted.";if(r.includes("context"))return"Fresh check from something you noted.";return fallback}
function friendlyDate(value?:string){if(!value)return"Later";const d=new Date(value);if(!Number.isFinite(d.getTime()))return"Later";const now=new Date(),tomorrow=new Date(now);tomorrow.setDate(now.getDate()+1);if(d.toDateString()===tomorrow.toDateString())return"Tomorrow";if(d.toDateString()===now.toDateString())return"Later today";return d.toLocaleDateString(undefined,{day:"numeric",month:"short"})}

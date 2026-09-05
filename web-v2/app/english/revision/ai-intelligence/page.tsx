"use client";
import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { LearnerRow, OverviewCard, PageHeader } from "@/components/learner-ui";
import { confusionLabel, learnerGroup, learnerName } from "@/lib/learner-label";
import { learnerErrorMessage, rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Activity={id:number;type:string;title:string;detail?:string;questionId?:string;at:string};
type Signals={today_activity?:{count:number;items:Activity[]}};
type Focus={questionId:string;name:string;skillFamily?:string;nextReview?:string};
type Confusion={confusionId:string;primaryName:string;relatedName:string;primaryQuestionId?:string;relatedQuestionId?:string};
type Hub={summary:{dueNow:number;confusions:number};confusions:Confusion[];needLearning:Focus[];transferChecks:Focus[];retentionChecks:Focus[];recovered:{name:string}[]};
type Label={questionId:string;displayName:string;topic?:string;conceptName?:string};
type Row={key:string;title:string;detail:string;status?:string;group:string;href?:string;tone:"fix"|"soon"|"good"|"later"};
type Section="today"|"fix"|"soon"|"good"|"later";
type ConceptKind="weak"|"retention_risk"|"secure"|"exam_ready"|"unseen"|"high_yield_unseen"|"needs_validation";
type ConceptSummary={
 concepts:number;active_questions:number;mapped_questions:number;unmapped_questions:number;mapping_pct:number;
 seen:number;weak_only:number;weak:number;retention_risk:number;secure:number;exam_ready:number;unseen:number;covered:number;
 coverage_pct:number;exam_ready_pct:number;high_yield_unseen:number;needs_validation:number;confusions:number;reconciles:boolean;
};
type ConceptItem={concept_id:string;domain?:string;skill_family?:string;name:string;exam_relevance?:string;priority_score?:number;coverage_state:string;confidence_score:number;attempts:number;wrong:number;next_review?:string;question_id?:string};
type WorkerState={healthy:boolean;lastRun?:string;status?:string};
type WorkerHealth={workers:{semantic:WorkerState;learning:WorkerState;quality:WorkerState};queued:number;processing:number;retrying:number;failed7d:number;oldestPendingAt?:string};
const due=(d?:string)=>!d||new Date(d).getTime()<=Date.now();
const href=(id:string,title:string)=>`/english/targeted?question=${encodeURIComponent(id)}&title=${encodeURIComponent(title)}`;
const conceptMeta:Record<ConceptKind,[string,string]>={
 weak:["Weak concepts","Repeated evidence currently needs repair."],
 retention_risk:["Retention risk","Previously learned concepts that need spaced proof."],
 secure:["Secure concepts","Concepts supported by multiple good signals."],
 exam_ready:["Exam-ready concepts","Concepts with strong transfer and delayed-recall evidence."],
 unseen:["Unseen concepts","Active concepts without learner evidence yet."],
 high_yield_unseen:["High-yield unseen","High-relevance concepts still waiting for first evidence."],
 needs_validation:["Needs validation","Seen concepts that still need stronger independent evidence."],
};

export default function LearningInsightsPage(){
 const ready=useAuthGuard();
 const [hub,setHub]=useState<Hub|null>(null),[signals,setSignals]=useState<Signals|null>(null),[labels,setLabels]=useState<Record<string,Label>>({});
 const [concepts,setConcepts]=useState<ConceptSummary|null>(null),[workerHealth,setWorkerHealth]=useState<WorkerHealth|null>(null);
 const [section,setSection]=useState<Section|null>(null),[conceptKind,setConceptKind]=useState<ConceptKind|null>(null),[conceptItems,setConceptItems]=useState<ConceptItem[]>([]),[conceptLoading,setConceptLoading]=useState(false);
 const [error,setError]=useState(""),[loading,setLoading]=useState(true);
 useEffect(()=>{if(!ready)return;let alive=true;Promise.all([
   rpc<Hub>("english_get_targeted_mastery"),rpc<Signals>("english_get_learning_signal_summary"),
   rpc<ConceptSummary>("english_get_concept_intelligence_summary"),rpc<WorkerHealth>("english_get_ai_worker_health")
 ]).then(async([h,s,c,w])=>{if(!alive)return;setHub(h);setSignals(s);setConcepts(c);setWorkerHealth(w);const ids=[...h.needLearning,...h.transferChecks,...h.retentionChecks].map(x=>x.questionId).concat(...h.confusions.map(x=>[x.primaryQuestionId,x.relatedQuestionId].filter(Boolean) as string[]),...(s.today_activity?.items||[]).map(x=>x.questionId||"")).filter(Boolean);if(ids.length)try{const out=await rpc<{items:Label[]}>("english_get_question_labels",{p_question_ids:[...new Set(ids)].slice(0,120)});if(alive)setLabels(Object.fromEntries((out.items||[]).map(x=>[x.questionId,x])))}catch{}}).catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load Learning Insights."))).finally(()=>alive&&setLoading(false));return()=>{alive=false}},[ready]);
 const rows=useMemo(()=>{if(!hub)return {fix:[] as Row[],soon:[] as Row[],good:[] as Row[],later:[] as Row[],today:[] as Row[]};const named=(f:Focus)=>learnerName(labels[f.questionId],f.name),focus=(items:Focus[],kind:Exclude<Section,"today">,detail:string,status?:string):Row[]=>items.map(f=>({key:`${kind}-${f.questionId}`,title:named(f),detail,status,group:learnerGroup(labels[f.questionId]?.topic||f.skillFamily),href:href(f.questionId,named(f)),tone:kind}));const conf:Row[]=hub.confusions.map(c=>({key:`c-${c.confusionId}`,title:confusionLabel(c.primaryName,c.relatedName),detail:"You flagged this confusion",status:"Ready now",group:"Confusions",href:`/english/targeted?confusion=${encodeURIComponent(c.confusionId)}`,tone:"fix" as const}));return {fix:[...conf,...focus(hub.transferChecks.filter(x=>due(x.nextReview)),"fix","Fresh understanding check","Ready now"),...focus(hub.retentionChecks.filter(x=>due(x.nextReview)),"fix","Spaced recall is ready","Ready now"),...focus(hub.needLearning.filter(x=>due(x.nextReview)),"fix","Focused repair from recent evidence","Ready now")],soon:focus(hub.transferChecks.filter(x=>x.nextReview&&!due(x.nextReview)),"soon","Fresh understanding check coming up"),good:hub.recovered.map((x,i)=>({key:`good-${i}-${x.name}`,title:learnerName(undefined,x.name),detail:"Recent evidence is better than before",group:"Improving",tone:"good" as const})),later:focus(hub.retentionChecks.filter(x=>x.nextReview&&!due(x.nextReview)),"later","Fresh proof completed"),today:(signals?.today_activity?.items||[]).map(x=>({key:`today-${x.id}`,title:learnerName(labels[x.questionId||""],cleanTitle(x.title)),detail:activityText(x),status:time(x.at),group:"Today",href:x.questionId?href(x.questionId,learnerName(labels[x.questionId],x.title)):undefined,tone:"soon" as const}))}},[hub,signals,labels]);
 async function openConcepts(kind:ConceptKind){setConceptKind(kind);setConceptLoading(true);setConceptItems([]);try{setConceptItems(await rpc<ConceptItem[]>("english_get_concept_intelligence_detail",{p_kind:kind}))}catch(e:any){setError(learnerErrorMessage(e,"Could not load concept details."))}finally{setConceptLoading(false)}}
 if(!ready)return null;
 if(conceptKind)return <ConceptCategory kind={conceptKind} items={conceptItems} loading={conceptLoading} onBack={()=>setConceptKind(null)}/>;
 if(section)return <Category section={section} rows={rows[section]} onBack={()=>setSection(null)}/>;
 return <main className="top-level-parity learner-rebuild-page">
   <PageHeader back={<Link href="/english/revision" className="back-link">← Revision</Link>} eyebrow="Your study plan" title="Learning Insights" subtitle="See what needs attention and why."/>
   {error&&<div className="error-box">{error}</div>}
   {loading?<div className="loading-copy">Refreshing your learning plan…</div>:<>
     {concepts&&<section className="learner-section"><div className="learner-section-head"><div><h2>Concept coverage</h2><p>{concepts.covered.toLocaleString()} of {concepts.concepts.toLocaleString()} active concepts seen · {concepts.coverage_pct}% coverage</p></div></div><div className="learner-overview-stack">
       <OverviewCard tone="neutral" title="Total Concepts" subtitle={`${concepts.mapped_questions.toLocaleString()}/${concepts.active_questions.toLocaleString()} active questions mapped (${concepts.mapping_pct}%).`} count={concepts.concepts}/>
       <OverviewCard tone="fix" title="Weak" subtitle="Repeated evidence currently needs repair." count={concepts.weak_only} onClick={()=>void openConcepts("weak")}/>
       <OverviewCard tone="soon" title="Retention Risk" subtitle="Learned before, but spaced recall needs proof." count={concepts.retention_risk} onClick={()=>void openConcepts("retention_risk")}/>
       <OverviewCard tone="good" title="Secure" subtitle="Multiple signals support current understanding." count={concepts.secure} onClick={()=>void openConcepts("secure")}/>
       <OverviewCard tone="good" title="Exam Ready" subtitle="Transfer plus delayed recall evidence is strong." count={concepts.exam_ready} onClick={()=>void openConcepts("exam_ready")}/>
       <OverviewCard tone="later" title="High-yield Unseen" subtitle="Important concepts still waiting for first evidence." count={concepts.high_yield_unseen} onClick={()=>void openConcepts("high_yield_unseen")}/>
     </div>{!concepts.reconciles&&<div className="error-box">Concept-state totals do not reconcile. Learning evidence needs review.</div>}</section>}
     <section className="learner-section"><div className="learner-section-head"><div><h2>Learning plan</h2><p>What needs action now, soon, and later.</p></div></div><div className="learner-overview-stack">
       <OverviewCard tone="neutral" title="Today" subtitle="See what changed in your learning plan." count={signals?.today_activity?.count??0} onClick={()=>setSection("today")}/>
       <OverviewCard tone="fix" title="Fix Now" subtitle="Mistakes, confusion and uncertain answers." count={rows.fix.length} onClick={()=>setSection("fix")}/>
       <OverviewCard tone="soon" title="Check Soon" subtitle="Fresh checks that will strengthen recall." count={rows.soon.length} onClick={()=>setSection("soon")}/>
       <OverviewCard tone="good" title="Improving" subtitle="Concepts with stronger recent evidence." count={rows.good.length} onClick={()=>setSection("good")}/>
       <OverviewCard tone="later" title="Scheduled for Later" subtitle="Spaced recall waiting for the right time." count={rows.later.length} onClick={()=>setSection("later")}/>
     </div></section>
     {workerHealth&&<details className="insights-how-details learner-section"><summary><span><b>Background AI health</b><small>Operational status only — this does not affect your mastery score.</small></span></summary><div className="insights-how-copy"><p><b>Semantic:</b> {healthText(workerHealth.workers.semantic)} · <b>Learning:</b> {healthText(workerHealth.workers.learning)} · <b>Quality:</b> {healthText(workerHealth.workers.quality)}</p><p><b>Queued:</b> {workerHealth.queued} · <b>Processing:</b> {workerHealth.processing} · <b>Retrying:</b> {workerHealth.retrying} · <b>Failed (7d):</b> {workerHealth.failed7d}</p>{workerHealth.oldestPendingAt&&<p>Oldest pending: {timeAgo(workerHealth.oldestPendingAt)}</p>}</div></details>}
     <details className="insights-how-details learner-section"><summary><span><b>How your learning plan works</b><small>Why something appears now, soon, or later.</small></span></summary><div className="insights-how-copy"><p><b>Weak</b> requires repeated negative evidence; a single mistake does not define the whole concept.</p><p><b>Retention Risk</b> means earlier understanding needs spaced confirmation.</p><p><b>Fix Now</b> prioritises mistakes, uncertainty and confusions. AI changes priority while core Daily capacity remains deterministic.</p></div></details>
   </>}
 </main>;
}
function Category({section,rows,onBack}:{section:Section;rows:Row[];onBack:()=>void}){const meta:Record<Section,[string,string]>={today:["Today","What changed in your learning plan."],fix:["Fix Now","Items that can improve your score now."],soon:["Check Soon","Fresh checks coming up."],good:["Improving","Recent evidence is better than before."],later:["Scheduled for Later","Checks waiting for the right recall time."]};const [title,subtitle]=meta[section],groups=rows.reduce<Record<string,Row[]>>((all,row)=>{(all[row.group]??=[]).push(row);return all},{});return <main className="top-level-parity learner-rebuild-page"><button className="learner-back" type="button" onClick={onBack}>← Learning Insights</button><PageHeader title={title} subtitle={subtitle}/>{rows.length?Object.entries(groups).map(([group,items])=><section className="learner-section" key={group}><div className="learner-section-head"><div><h2>{group}</h2><p>{items.length} item{items.length===1?"":"s"}</p></div></div><div className="learner-row-list">{items.map(row=><LearnerRow key={row.key} title={row.title} subtitle={row.detail} status={row.status} tone={row.tone} onClick={row.href?()=>location.assign(row.href!):undefined}/>)}</div></section>):<div className="learner-empty">Nothing is here right now.</div>}</main>}
function ConceptCategory({kind,items,loading,onBack}:{kind:ConceptKind;items:ConceptItem[];loading:boolean;onBack:()=>void}){const [title,subtitle]=conceptMeta[kind];return <main className="top-level-parity learner-rebuild-page"><button className="learner-back" type="button" onClick={onBack}>← Learning Insights</button><PageHeader title={title} subtitle={subtitle}/>{loading?<div className="loading-copy">Loading concept evidence…</div>:items.length?<section className="learner-section"><div className="learner-row-list">{items.slice(0,250).map(item=><LearnerRow key={item.concept_id} title={item.name} subtitle={`${item.skill_family||item.domain||"English"} · ${item.attempts} attempt${item.attempts===1?"":"s"}${item.wrong?` · ${item.wrong} wrong`:""}`} status={`${Math.round(Number(item.confidence_score)||0)}% evidence`} tone={kind==="weak"?"fix":kind==="retention_risk"||kind==="needs_validation"?"soon":kind==="secure"||kind==="exam_ready"?"good":"later"} onClick={item.question_id?()=>location.assign(href(item.question_id!,item.name)):undefined}/>)}</div>{items.length>250&&<div className="learner-empty">Showing the highest-priority 250 of {items.length.toLocaleString()} concepts.</div>}</section>:<div className="learner-empty">Nothing is here right now.</div>}</main>}
function cleanTitle(value:string){return String(value||"Learning update").replace(/background analysis|targeted|route event|semantic processing/gi,"").replace(/\s+→\s+/g," ").trim()||"Learning update"}
function activityText(x:Activity){if(x.type.includes("guess"))return"You marked this as guessed. A fresh understanding check was added.";if(x.type.includes("confusion"))return"You flagged a confusion for focused practice.";return String(x.detail||"Your learning plan was updated.").replace(/background analysis|targeted|route event|semantic processing/gi,"learning plan")}
function time(value:string){const d=new Date(value);return Number.isFinite(d.getTime())?d.toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"}):undefined}
function timeAgo(value:string){const t=new Date(value).getTime();if(!Number.isFinite(t))return"unknown";const mins=Math.max(0,Math.round((Date.now()-t)/60000));return mins<2?"just now":mins<60?`${mins} min ago`:`${Math.round(mins/60)} hr ago`}
function healthText(x:WorkerState){return x?.healthy?"Healthy":x?.status?`Needs attention (${x.status})`:"No recent scheduler run"}

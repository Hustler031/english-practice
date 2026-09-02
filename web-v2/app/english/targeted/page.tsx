"use client";

import Link from "next/link";
import { useCallback,useEffect,useMemo,useRef,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary={active:number;dueNow:number;confusions:number;needLearning:number;transferChecks:number;retentionChecks:number;recovered:number};
type Confusion={confusionId:string;status:string;primaryName:string;relatedName:string;primaryQuestionId?:string;relatedQuestionId?:string;note?:string;lastSignalAt:string};
type FocusRow={questionId:string;conceptId?:string;name:string;skillFamily?:string;state?:string;reason?:string;nextReview?:string};
type Recovered={concept_id?:string;conceptId?:string;name:string;at:string;source:string};
type Hub={ok:boolean;summary:Summary;confusions:Confusion[];needLearning:FocusRow[];transferChecks:FocusRow[];retentionChecks:FocusRow[];recovered:Recovered[]};
type Kind="confusion"|"need_learning"|"transfer_check"|"retention_check";
type View="fix-now"|"confusions"|"waiting";
type Practice={title:string;kind?:Kind;confusionId?:string;questionId?:string;nonce:string};
type QuestionLabel={questionId:string;displayName:string;topic?:string;questionType?:string;conceptId?:string;conceptName?:string};
type LabelsResponse={ok:boolean;items:QuestionLabel[]};
type ActionRow={key:string;title:string;reason:string;questionId?:string;kind?:Kind;confusionId?:string;nextReview?:string;tone:"signal"|"accent"|"warm"|"neutral"};

const freshNonce=()=>`${Date.now()}-${Math.random().toString(36).slice(2,9)}`;
const dueNow=(value?:string)=>!value||new Date(value).getTime()<=Date.now();

export default function TargetedMasteryPage(){
 const ready=useAuthGuard();
 const[hub,setHub]=useState<Hub|null>(null);
 const[labels,setLabels]=useState<Record<string,QuestionLabel>>({});
 const[practice,setPractice]=useState<Practice|null>(null);
 const[view,setView]=useState<View|null>(null);
 const[error,setError]=useState("");
 const[loading,setLoading]=useState(true);
 const queryHandled=useRef(false);

 const loadLabels=useCallback(async(next:Hub)=>{
  const ids=[
   ...next.needLearning.map(x=>x.questionId),...next.transferChecks.map(x=>x.questionId),...next.retentionChecks.map(x=>x.questionId),
   ...next.confusions.flatMap(x=>[x.primaryQuestionId,x.relatedQuestionId].filter(Boolean) as string[]),
  ];
  const unique=[...new Set(ids)].slice(0,120);if(!unique.length)return;
  try{
   const out=await rpc<LabelsResponse>("english_get_question_labels",{p_question_ids:unique});
   setLabels(Object.fromEntries((out.items||[]).map(item=>[item.questionId,item])));
  }catch{}
 },[]);

 const refresh=useCallback(async()=>{
  setError("");
  try{const next=await rpc<Hub>("english_get_targeted_mastery");setHub(next);void loadLabels(next);}
  catch(e:any){setError(learnerErrorMessage(e,"Could not load Targeted Mastery."));}
  finally{setLoading(false);}
 },[loadLabels]);
 useEffect(()=>{if(ready)void refresh()},[ready,refresh]);

 const load=useCallback(()=>{
  if(!practice)return Promise.resolve([]);
  if(practice.questionId)return rpc<any[]>("english_get_targeted_question",{p_question_id:practice.questionId});
  return rpc<any[]>("english_get_targeted_session",{p_count:15,p_kind:practice.kind??null,p_confusion_id:practice.confusionId??null,p_session_nonce:practice.nonce});
 },[practice]);
 const start=(title:string,kind?:Kind,confusionId?:string,questionId?:string)=>setPractice({title,kind,confusionId,questionId,nonce:freshNonce()});
 const nameFor=(row:FocusRow)=>labels[row.questionId]?.displayName||row.name||"English practice";
 const reasonFor=(row:FocusRow,kind:Kind)=>{
  const raw=String(row.reason||"").toLowerCase();
  if(raw.includes("guess"))return "One independent check remaining";
  if(raw.includes("context")||raw.includes("confusion"))return "Fresh check from something you noted";
  if(kind==="transfer_check")return "Fresh understanding check";
  if(kind==="retention_check")return dueNow(row.nextReview)?"Spaced recall is ready":"Waiting for the right recall time";
  return "Focused repair from recent evidence";
 };

 const fixRows=useMemo<ActionRow[]>(()=>{
  if(!hub)return[];
  const confusionRows=hub.confusions.map(c=>({key:`c-${c.confusionId}`,title:`${c.primaryName} vs ${c.relatedName}`,reason:"You flagged this confusion",questionId:c.primaryQuestionId||c.relatedQuestionId,kind:"confusion" as Kind,confusionId:c.confusionId,tone:"signal" as const}));
  const transferRows=hub.transferChecks.filter(r=>dueNow(r.nextReview)).map(r=>({key:`t-${r.questionId}`,title:nameFor(r),reason:reasonFor(r,"transfer_check"),questionId:r.questionId,kind:"transfer_check" as Kind,tone:"accent" as const}));
  const retentionRows=hub.retentionChecks.filter(r=>dueNow(r.nextReview)).map(r=>({key:`r-${r.questionId}`,title:nameFor(r),reason:reasonFor(r,"retention_check"),questionId:r.questionId,kind:"retention_check" as Kind,tone:"warm" as const}));
  const learningRows=hub.needLearning.filter(r=>dueNow(r.nextReview)).map(r=>({key:`n-${r.questionId}`,title:nameFor(r),reason:reasonFor(r,"need_learning"),questionId:r.questionId,kind:"need_learning" as Kind,tone:"neutral" as const}));
  return [...confusionRows,...transferRows,...retentionRows,...learningRows].slice(0,40);
 },[hub,labels]);
 const waitingRows=useMemo<ActionRow[]>(()=>hub?hub.retentionChecks.filter(r=>r.nextReview&&!dueNow(r.nextReview)).map(r=>({key:`w-${r.questionId}`,title:nameFor(r),reason:"Fresh proof completed · check due later",questionId:r.questionId,kind:"retention_check" as Kind,nextReview:r.nextReview,tone:"neutral" as const})):[],[hub,labels]);

 useEffect(()=>{
  if(!ready||!hub||queryHandled.current)return;queryHandled.current=true;
  const q=new URLSearchParams(window.location.search);const startMode=q.get("start"),confusion=q.get("confusion"),question=q.get("question"),nextView=q.get("view") as View|null;
  if(confusion){const c=hub.confusions.find(x=>x.confusionId===confusion);start(c?`${c.primaryName} vs ${c.relatedName}`:"Your Confusion","confusion",confusion);return;}
  if(question){start(labels[question]?.displayName||q.get("title")||"Focused Practice",undefined,undefined,question);return;}
  if(startMode==="focused"){start("Targeted Mastery");return;}
  if(nextView&&["fix-now","confusions","waiting"].includes(nextView))setView(nextView);
 },[ready,hub,labels]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(practice)return <QuizRunner title={practice.title} backHref="/english/targeted" load={load} module="targeted" onExit={()=>{setPractice(null);void refresh()}} onFinish={refresh}/>;
 if(view&&hub)return <TargetedDetail view={view} hub={hub} fixRows={fixRows} waitingRows={waitingRows} onBack={()=>setView(null)} onPractice={start}/>;

 const s=hub?.summary;
 return <main className="top-level-parity targeted-mastery-page">
  <section className="page-intro targeted-intro">
   <Link href="/english/practice" className="back-link">← Practice</Link>
   <span className="intelligence-kicker">Focused practice</span>
   <h1>Targeted Mastery</h1>
   <p>{s?`${s.dueNow} question${s.dueNow===1?"":"s"} need focused practice.`:"Loading your focused practice…"}</p>
   <small className="targeted-intro-note">From mistakes, uncertainty, or a confusion you noted.</small>
  </section>
  {error&&<div className="error-box">{error}</div>}
  {loading?<EnglishLoading text="Ranking focused practice…"/>:<>
   <section className="targeted-command-card learner-command-card">
    <div className="targeted-command-copy"><span className="targeted-command-label">Ready now</span><div className="targeted-due-line"><strong>{s?.dueNow??0}</strong><span>focused questions</span></div><p>Start with the items most likely to improve your score now.</p></div>
    <button className="btn primary targeted-start-button" disabled={!s?.active} onClick={()=>start("Targeted Mastery")}>Start Focused Practice</button>
   </section>

   <section className="targeted-learning-section tone-fix">
    <SectionHead title="FIX NOW" count={`${s?.dueNow??0} questions are ready now`} onOpen={()=>setView("fix-now")}/>
    {fixRows.slice(0,3).length?<div className="targeted-learning-preview">{fixRows.slice(0,3).map(row=><LearnerRow key={row.key} row={row} compact onPractice={()=>row.confusionId?start(row.title,"confusion",row.confusionId):start(row.title,row.kind,undefined,row.questionId)}/>)}</div>:<EmptyCopy text="Nothing needs immediate repair right now."/>}
    {!!fixRows.length&&<button className="targeted-practice-all" type="button" onClick={()=>start("Fix Now")}>Practice all <span>›</span></button>}
   </section>

   {!!hub?.confusions?.length&&<section className="targeted-learning-section tone-confusion">
    <SectionHead title="YOUR CONFUSIONS" count={`${s?.confusions??0} confusion pair${(s?.confusions??0)===1?"":"s"} to clear`} onOpen={()=>setView("confusions")}/>
    <p className="targeted-section-copy">Only the mix-ups you explicitly told the app about.</p>
   </section>}

   <section className="targeted-learning-section tone-waiting">
    <SectionHead title="WAITING FOR LATER" count={`${waitingRows.length} concept${waitingRows.length===1?"":"s"} scheduled for spaced checking`} onOpen={()=>setView("waiting")}/>
    <p className="targeted-section-copy">These are remembered — they are simply waiting for the right recall time.</p>
   </section>

   <Link href="/english/revision/ai-intelligence" className="targeted-learning-insights-link"><span><b>Learning Insights</b><small>See what needs attention and why</small></span><i>›</i></Link>
  </>}
 </main>;
}

function TargetedDetail({view,hub,fixRows,waitingRows,onBack,onPractice}:{view:View;hub:Hub;fixRows:ActionRow[];waitingRows:ActionRow[];onBack:()=>void;onPractice:(title:string,kind?:Kind,confusionId?:string,questionId?:string)=>void}){
 if(view==="fix-now")return <DetailShell title="Fix Now" subtitle="Practice the items that can improve your score now." onBack={onBack} action={fixRows.length?<button className="btn primary" onClick={()=>onPractice("Fix Now")}>Practice all</button>:null}>
  <section className="targeted-clean-list">{fixRows.length?fixRows.map(row=><LearnerRow key={row.key} row={row} onPractice={()=>row.confusionId?onPractice(row.title,"confusion",row.confusionId):onPractice(row.title,row.kind,undefined,row.questionId)}/>):<EmptyCopy text="Nothing needs immediate repair right now."/>}</section>
 </DetailShell>;
 if(view==="confusions")return <DetailShell title="Your Confusions" subtitle="Clear the meanings and rules you said get mixed up." onBack={onBack}>
  <section className="targeted-clean-list">{hub.confusions.length?hub.confusions.map(c=><article className="targeted-clean-row confusion-clean-row" key={c.confusionId}><div className="targeted-row-glyph signal">↔</div><div className="targeted-row-copy"><b>{c.primaryName} vs {c.relatedName}</b><p>{c.note?`“${c.note}”`:"You said these meanings or rules get mixed up."}</p><small>{confusionState(c.status)}</small></div><button type="button" onClick={()=>onPractice(`${c.primaryName} vs ${c.relatedName}`,"confusion",c.confusionId)}>Practice ›</button></article>):<EmptyCopy text="No unresolved confusion pairs right now."/>}</section>
 </DetailShell>;
 return <DetailShell title="Waiting for Later" subtitle="Nothing is forgotten here. These are simply waiting for the right spaced-recall time." onBack={onBack}>
  <section className="targeted-clean-list">{waitingRows.length?waitingRows.map(row=><LearnerRow key={row.key} row={{...row,reason:`Next check: ${friendlyDate(row.nextReview)}`}} onPractice={()=>onPractice(row.title,row.kind,undefined,row.questionId)} actionLabel="Open ›"/>):<EmptyCopy text="No spaced checks are waiting right now."/>}</section>
 </DetailShell>;
}

function DetailShell({title,subtitle,onBack,action,children}:{title:string;subtitle:string;onBack:()=>void;action?:React.ReactNode;children:React.ReactNode}){
 return <main className="top-level-parity targeted-mastery-page targeted-detail-page"><section className="page-intro targeted-detail-intro"><button className="back-link targeted-back-button" type="button" onClick={onBack}>← Targeted Mastery</button><span className="intelligence-kicker">Focused practice</span><div className="targeted-detail-title"><div><h1>{title}</h1><p>{subtitle}</p></div>{action}</div></section>{children}</main>;
}
function SectionHead({title,count,onOpen}:{title:string;count:string;onOpen:()=>void}){return <div className="targeted-section-head"><div><b>{title}</b><small>{count}</small></div><button type="button" onClick={onOpen}>Open ›</button></div>}
function LearnerRow({row,onPractice,compact=false,actionLabel="Practice ›"}:{row:ActionRow;onPractice:()=>void;compact?:boolean;actionLabel?:string}){return <article className={`targeted-clean-row ${compact?"compact":""}`}><div className={`targeted-row-glyph ${row.tone}`}>{row.tone==="signal"?"↔":row.tone==="accent"?"↗":row.tone==="warm"?"◷":"•"}</div><div className="targeted-row-copy"><b>{row.title}</b><p>{row.reason}</p></div><button type="button" onClick={onPractice}>{actionLabel}</button></article>}
function EmptyCopy({text}:{text:string}){return <div className="empty-state compact-empty"><p className="muted">{text}</p></div>}
function friendlyDate(value?:string){if(!value)return"Later";const d=new Date(value);if(!Number.isFinite(d.getTime()))return"Later";const now=new Date(),tomorrow=new Date(now);tomorrow.setDate(now.getDate()+1);if(d.toDateString()===tomorrow.toDateString())return"Tomorrow";if(d.toDateString()===now.toDateString())return"Later today";return d.toLocaleDateString(undefined,{day:"numeric",month:"short"})}
function confusionState(value:string){const v=String(value||"").toLowerCase();if(v==="testing")return"Ready for focused practice";if(v==="improving")return"Waiting for fresh proof";return"Ready for focused practice"}

"use client";

import Link from "next/link";
import { useCallback,useEffect,useMemo,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary={active:number;dueNow:number;confusions:number;needLearning:number;transferChecks:number;retentionChecks:number;recovered:number};
type Confusion={confusionId:string;status:string;strength:number;primaryName:string;relatedName:string;primaryQuestionId?:string;relatedQuestionId?:string;note?:string;lastSignalAt:string};
type FocusRow={questionId:string;conceptId?:string;name:string;skillFamily?:string;state?:string;confidence?:number;reason?:string;nextReview?:string};
type Recovered={concept_id?:string;conceptId?:string;name:string;at:string;source:string};
type Hub={ok:boolean;summary:Summary;confusions:Confusion[];needLearning:FocusRow[];transferChecks:FocusRow[];retentionChecks:FocusRow[];recovered:Recovered[]};
type Kind="confusion"|"need_learning"|"transfer_check"|"retention_check";
type View="confusions"|"need-learning"|"transfer-checks"|"retention-checks"|"recovered";
type Practice={title:string;kind?:Kind;confusionId?:string;nonce:string};

const freshNonce=()=>`${Date.now()}-${Math.random().toString(36).slice(2,9)}`;
const stateLabel=(value?:string)=>String(value||"learning").replaceAll("_"," ");
const shortReason=(value?:string)=>String(value||"").replace(/^Background analysis /,"Background · ").replace(/^Confidence signal /,"Confidence · ");

const viewMeta:Record<View,{title:string;eyebrow:string;description:string;kind?:Kind}>={
 confusions:{title:"My Confusions",eyebrow:"Explicit learner signal",description:"Only the things you explicitly said you mix up. Each repair stays visible until fresh and spaced proof is strong enough.",kind:"confusion"},
 "need-learning":{title:"Need Learning",eyebrow:"Focused repair backlog",description:"Concepts Central Intelligence has selected for repair. The overview shows only a small priority slice; this view lets you inspect the tracked set.",kind:"need_learning"},
 "transfer-checks":{title:"Transfer Checks",eyebrow:"Fresh proof",description:"Independent questions used after uncertainty, I Guessed, or a context signal so the system does not mistake recognition for mastery.",kind:"transfer_check"},
 "retention-checks":{title:"Retention Checks",eyebrow:"Spaced confirmation",description:"Previously learned concepts waiting for spaced confirmation. Scheduled items can remain here before they become due.",kind:"retention_check"},
 recovered:{title:"Recovered",eyebrow:"Recent repair evidence",description:"Concepts that recovered after sufficient evidence. Recovery is history, not a permanent weakness label."},
};

export default function TargetedMasteryPage(){
 const ready=useAuthGuard();
 const[hub,setHub]=useState<Hub|null>(null);
 const[practice,setPractice]=useState<Practice|null>(null);
 const[view,setView]=useState<View|null>(null);
 const[error,setError]=useState("");
 const[loading,setLoading]=useState(true);

 const refresh=useCallback(async()=>{
  setError("");
  try{setHub(await rpc<Hub>("english_get_targeted_mastery"));}
  catch(e:any){setError(learnerErrorMessage(e,"Could not load Targeted Mastery."));}
  finally{setLoading(false);}
 },[]);
 useEffect(()=>{if(ready)void refresh()},[ready,refresh]);

 const load=useCallback(()=>{
  if(!practice)return Promise.resolve([]);
  return rpc<any[]>("english_get_targeted_session",{
   p_count:15,
   p_kind:practice.kind??null,
   p_confusion_id:practice.confusionId??null,
   p_session_nonce:practice.nonce,
  });
 },[practice]);

 const s=hub?.summary;
 const start=(title:string,kind?:Kind,confusionId?:string)=>setPractice({title,kind,confusionId,nonce:freshNonce()});
 const previews=useMemo(()=>{
  if(!hub)return [] as {view:View;label:string;row:FocusRow}[];
  return [
   ...hub.transferChecks.slice(0,2).map(row=>({view:"transfer-checks" as View,label:"Transfer",row})),
   ...hub.retentionChecks.filter(row=>!row.nextReview||new Date(row.nextReview).getTime()<=Date.now()).slice(0,1).map(row=>({view:"retention-checks" as View,label:"Retention",row})),
   ...hub.needLearning.slice(0,3).map(row=>({view:"need-learning" as View,label:"Repair",row})),
  ].slice(0,4);
 },[hub]);

 if(!ready)return <EnglishLoading text="Checking session…"/>;
 if(practice)return <QuizRunner title={practice.title} backHref="/english/targeted" load={load} module="targeted" onExit={()=>{setPractice(null);void refresh()}} onFinish={refresh}/>;
 if(view&&hub)return <TargetedDetail view={view} hub={hub} onBack={()=>setView(null)} onPractice={start}/>;

 return <main className="top-level-parity targeted-mastery-page">
  <section className="page-intro targeted-intro">
   <Link href="/english/revision" className="back-link">← Revision</Link>
   <span className="intelligence-kicker">Central Intelligence</span>
   <h1>Targeted Mastery</h1>
   <p>Small, focused repair sets from your real learning evidence.</p>
  </section>
  {error&&<div className="error-box">{error}</div>}
  {loading?<EnglishLoading text="Ranking focused repair…"/>:<>
   <section className="targeted-command-card">
    <div className="targeted-command-copy">
     <span className="targeted-command-label">Ready for focused practice</span>
     <div className="targeted-due-line"><strong>{s?.dueNow??0}</strong><span>due now</span></div>
     <p>Confusions and fresh transfer proof are prioritised before the general repair backlog.</p>
     <small>{s?.active??0} concepts tracked in the wider repair pool</small>
    </div>
    <button className="btn primary targeted-start-button" disabled={!s?.active} onClick={()=>start("Targeted Mastery")}>Start focused set</button>
   </section>

   <section className="targeted-dashboard-section">
    <div className="targeted-dashboard-heading"><div><span className="section-cap">Focus areas</span><h2>Open only what you need</h2></div><small>Tap a card to inspect questions</small></div>
    <div className="targeted-nav-grid">
     <TargetNavCard glyph="↔" label="My Confusions" value={s?.confusions??0} hint="Your explicit mix-ups" tone="signal" onClick={()=>setView("confusions")}/>
     <TargetNavCard glyph="△" label="Need Learning" value={s?.needLearning??0} hint="Tracked repair backlog" onClick={()=>setView("need-learning")}/>
     <TargetNavCard glyph="↗" label="Transfer Checks" value={s?.transferChecks??0} hint="Fresh independent proof" tone="accent" onClick={()=>setView("transfer-checks")}/>
     <TargetNavCard glyph="◷" label="Retention Checks" value={s?.retentionChecks??0} hint="Spaced confirmation" onClick={()=>setView("retention-checks")}/>
     <TargetNavCard glyph="✓" label="Recovered" value={s?.recovered??0} hint="Recent repair evidence" tone="good" wide onClick={()=>setView("recovered")}/>
    </div>
   </section>

   {!!hub?.confusions?.length&&<section className="targeted-spotlight-card">
    <div className="targeted-spotlight-head"><div><span>My Confusions</span><b>Most direct learner signal</b></div><button type="button" onClick={()=>setView("confusions")}>View all ›</button></div>
    {hub.confusions.slice(0,2).map(c=><button className="targeted-confusion-preview" key={c.confusionId} onClick={()=>start(`${c.primaryName} ↔ ${c.relatedName}`,"confusion",c.confusionId)}>
      <span className="targeted-confusion-symbol">↔</span><span><b>{c.primaryName} <i>vs</i> {c.relatedName}</b>{c.note&&<small>“{c.note}”</small>}<em>{stateLabel(c.status)} · focused practice</em></span><i>›</i>
    </button>)}
   </section>}

   <section className="targeted-priority-card">
    <div className="targeted-spotlight-head"><div><span>Next focused actions</span><b>Priority preview</b></div><small>{previews.length?"Not the full backlog":"Nothing urgent here"}</small></div>
    {previews.length?<div className="targeted-preview-list">{previews.map(({view:target,label,row})=><button key={`${label}-${row.questionId}`} className="targeted-preview-row" onClick={()=>setView(target)}><span className="targeted-preview-tag">{label}</span><span className="targeted-preview-copy"><b>{row.name}</b><small>{row.questionId}{row.skillFamily?` · ${row.skillFamily}`:""}</small></span><i>›</i></button>)}</div>:<EmptyCopy text="No immediate transfer or repair preview is due right now."/>}
   </section>
  </>}
 </main>;
}

function TargetedDetail({view,hub,onBack,onPractice}:{view:View;hub:Hub;onBack:()=>void;onPractice:(title:string,kind?:Kind,confusionId?:string)=>void}){
 const meta=viewMeta[view];
 const s=hub.summary;
 const count=view==="confusions"?s.confusions:view==="need-learning"?s.needLearning:view==="transfer-checks"?s.transferChecks:view==="retention-checks"?s.retentionChecks:s.recovered;
 const rows=view==="need-learning"?hub.needLearning:view==="transfer-checks"?hub.transferChecks:view==="retention-checks"?hub.retentionChecks:[];
 return <main className="top-level-parity targeted-mastery-page targeted-detail-page">
  <section className="page-intro targeted-detail-intro">
   <button className="back-link targeted-back-button" type="button" onClick={onBack}>← Targeted Mastery</button>
   <span className="intelligence-kicker">{meta.eyebrow}</span>
   <div className="targeted-detail-title"><div><h1>{meta.title}</h1><p>{meta.description}</p></div><strong>{count}</strong></div>
  </section>
  {meta.kind&&count>0&&<section className="targeted-detail-action"><div><b>Focused practice</b><small>Fresh session · up to 15 questions</small></div><button className="btn primary" onClick={()=>onPractice(meta.title,meta.kind)}>Practice</button></section>}

  {view==="confusions"&&<section className="targeted-detail-list">{hub.confusions.length?hub.confusions.map(c=><article className="targeted-detail-row confusion-detail-row" key={c.confusionId}><div className="targeted-detail-row-top"><span className="targeted-detail-icon">↔</span><div><b>{c.primaryName} <i>vs</i> {c.relatedName}</b><small>{[c.primaryQuestionId,c.relatedQuestionId].filter(Boolean).join(" · ")}</small></div><span className="targeted-status-pill">{stateLabel(c.status)}</span></div>{c.note&&<p>“{c.note}”</p>}<button type="button" onClick={()=>onPractice(`${c.primaryName} ↔ ${c.relatedName}`,"confusion",c.confusionId)}>Practice this confusion <span>›</span></button></article>):<EmptyCopy text="No unresolved confusion pairs right now."/>}</section>}

  {(view==="need-learning"||view==="transfer-checks"||view==="retention-checks")&&<>
   <div className="targeted-detail-note">Showing the highest-priority {rows.length} items from this category. Question IDs are visible so the queue stays auditable.</div>
   <section className="targeted-detail-list">{rows.length?rows.map(row=><article className="targeted-detail-row" key={`${view}-${row.questionId}`}><div className="targeted-detail-row-top"><span className="targeted-detail-icon">{view==="transfer-checks"?"↗":view==="retention-checks"?"◷":"△"}</span><div><b>{row.name}</b><small>{row.questionId}{row.skillFamily?` · ${row.skillFamily}`:""}</small></div><span className="targeted-status-pill">{stateLabel(row.state)}</span></div><div className="targeted-detail-meta"><span>{Math.round(Number(row.confidence)||0)}% confidence</span>{row.nextReview&&<span>{dueText(row.nextReview)}</span>}</div>{row.reason&&<p>{shortReason(row.reason)}</p>}</article>):<EmptyCopy text={`No ${meta.title.toLowerCase()} are tracked right now.`}/>}</section>
  </>}

  {view==="recovered"&&<section className="targeted-detail-list recovered-detail-list">{hub.recovered.length?hub.recovered.map((r,i)=><article className="targeted-detail-row" key={`${r.concept_id||r.conceptId||r.name}-${i}`}><div className="targeted-detail-row-top"><span className="targeted-detail-icon recovered-icon">✓</span><div><b>{r.name}</b><small>{r.source.replaceAll("_"," ")} · {new Date(r.at).toLocaleDateString()}</small></div><span className="targeted-status-pill recovered-pill">Recovered</span></div></article>):<EmptyCopy text="Recovered concepts will appear here after fresh proof."/>}</section>}
 </main>;
}

function TargetNavCard({glyph,label,value,hint,tone="",wide=false,onClick}:{glyph:string;label:string;value:number;hint:string;tone?:string;wide?:boolean;onClick:()=>void}){
 return <button type="button" className={`targeted-nav-card ${tone} ${wide?"wide":""}`} onClick={onClick}><span className="targeted-nav-glyph">{glyph}</span><span className="targeted-nav-copy"><b>{label}</b><small>{hint}</small></span><strong>{value}</strong><i>›</i></button>;
}
function EmptyCopy({text}:{text:string}){return <div className="empty-state compact-empty"><p className="muted">{text}</p></div>}
function dueText(value:string){
 const at=new Date(value).getTime(),now=Date.now();
 if(!Number.isFinite(at))return "Scheduled";
 if(at<=now)return "Due now";
 const hours=Math.max(1,Math.round((at-now)/3600000));
 return hours<24?`Due in ~${hours}h`:`Due ${new Date(value).toLocaleDateString()}`;
}

"use client";

import Link from "next/link";
import { useEffect,useMemo,useState } from "react";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Summary={concepts:number;mapped_questions:number;unresolved_mappings:number;needs_review:number;seen:number;secure:number;exam_ready:number;weak:number;retention_risk:number};
type Row={concept_id:string;domain:string;skill_family:string;name:string;exam_relevance:string;coverage_state:string;confidence_score:number;attempts:number;wrong:number;next_review?:string};
type ContextRow={note_id:string;question_id:string;note:string;processing_status:string;ai_status?:string;diagnosis?:{type?:string;action?:string;related_terms?:string[];needs_ai?:boolean;processor?:string;model?:string};created_at:string};
type Activity={id:number;type:string;title:string;detail?:string;questionId?:string;conceptId?:string;route?:string;metadata?:Record<string,unknown>;at:string};
type TodayActivity={ok:boolean;count:number;items:Activity[]};
type Signals={context_total:number;context_done:number;context_pending:number;context_failed:number;guessed_total:number;guessed_open?:number;confusions_open?:number;context_targeted:number;recent_context:ContextRow[];today_activity?:TodayActivity};

const labels:Record<string,string>={exam_ready:"Exam-ready",secure:"Secure",weak:"Weak",retention_risk:"Retention risk",seen:"Learning",unseen:"Unseen"};

export default function AIIntelligencePage(){
  const ready=useAuthGuard();
  const [summary,setSummary]=useState<Summary|null>(null);
  const [signals,setSignals]=useState<Signals|null>(null);
  const [rows,setRows]=useState<Row[]>([]);
  const [kind,setKind]=useState("weak");
  const [open,setOpen]=useState<string|null>(null);
  const [todayOpen,setTodayOpen]=useState(false);
  const [error,setError]=useState("");
  const [loading,setLoading]=useState(true);

  useEffect(()=>{
    if(!ready)return;
    let live=true; setLoading(true); setError("");
    Promise.all([
      rpc<Summary>("english_get_concept_intelligence_summary"),
      rpc<Signals>("english_get_learning_signal_summary"),
      rpc<Row[]>("english_get_concept_intelligence_detail",{p_kind:kind})
    ]).then(([s,g,r])=>{
      if(!live)return; setSummary(s);setSignals(g);setRows(Array.isArray(r)?r:[]);
    }).catch((e:any)=>live&&setError(learnerErrorMessage(e,"Could not load Learning Intelligence.")))
      .finally(()=>live&&setLoading(false));
    return()=>{live=false};
  },[ready,kind]);

  const priorityRows=useMemo(()=>rows.slice(0,36),[rows]);
  const today=signals?.today_activity;
  const activities=Array.isArray(today?.items)?today.items:[];
  if(!ready)return <main className="top-level-parity"><div className="loading-copy">Checking session…</div></main>;

  return <main className="top-level-parity learning-intelligence-page">
    <div className="page-intro intelligence-intro">
      <Link href="/english/revision" className="back-link">← Revision</Link>
      <div className="intelligence-title-row"><div><span className="intelligence-kicker">Central Intelligence</span><h1>Learning Intelligence</h1><p>What needs attention, what is becoming secure, and how your signals are changing future practice.</p></div><span className="intelligence-health-dot" title="Concept intelligence active"/></div>
    </div>

    {error&&<div className="error-box">{error}</div>}

    <section className="intelligence-overview">
      <div className="intelligence-overview-copy"><small>Concept coverage</small><strong>{summary?.concepts??0}</strong><span>active concepts · {summary?.mapped_questions??0} mapped questions</span></div>
      <div className="intelligence-kpi-grid">
        <Metric label="Exam-ready" value={summary?.exam_ready??0} hint="Spaced + transfer proof" tone="good"/>
        <Metric label="Secure" value={summary?.secure??0} hint="Strong, still monitored"/>
        <Metric label="Needs work" value={summary?.weak??0} hint="Weak + retention risk" tone="warn"/>
        <Metric label="Retention risk" value={summary?.retention_risk??0} hint="Previously known, now uncertain" tone="bad"/>
      </div>
    </section>

    <section className="section-block intelligence-signals-section">
      <div className="section-title-line intelligence-today-head"><div><h2>Your learning signals</h2><p className="muted">Signals change future validation and routing; AI stays in the background.</p></div><button className={`today-info-button ${todayOpen?"active":""}`} type="button" onClick={()=>setTodayOpen(v=>!v)} aria-expanded={todayOpen}><span>Today’s Info</span><b>{today?.count??0}</b></button></div>
      {todayOpen&&<div className="today-activity-panel">
        <div className="today-activity-top"><div><b>Today’s learning actions</b><small>Only real routing, diagnosis and transfer actions are shown.</small></div><Link href="/english/targeted">Targeted ›</Link></div>
        {activities.length?<div className="today-activity-list">{activities.map(item=><div className="today-activity-row" key={item.id}><span className="activity-dot"/><div><b>{item.title}</b>{item.detail&&<p>{item.detail}</p>}<small>{item.questionId?`${item.questionId} · `:""}{item.route?`${item.route.replaceAll("_"," ")} · `:""}{new Date(item.at).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"})}</small></div></div>)}</div>:<div className="today-activity-empty">No background learning action was needed today yet.</div>}
      </div>}
      <div className="intelligence-signal-grid">
        <SignalStat label="Context used" value={signals?.context_done??0} detail={`${signals?.context_pending??0} background pending`}/>
        <SignalStat label="I Guessed" value={signals?.guessed_total??0} detail={`${signals?.guessed_open??0} awaiting fresh proof`}/>
        <SignalStat label="My Confusions" value={signals?.confusions_open??0} detail="open focused repairs"/>
      </div>
      <div className="intelligence-targeted-link"><Link href="/english/targeted"><span><b>Targeted Mastery</b><small>{signals?.context_targeted??0} context-routed items · confusion and transfer checks</small></span><i>›</i></Link></div>
      {!!signals?.recent_context?.length&&<details className="intelligence-details"><summary>Recent context signals</summary><div className="context-history-list">{signals.recent_context.map(row=><div className="context-history-row" key={row.note_id}><div><b>{row.question_id}</b><span>{row.note}</span></div><div className="context-history-meta"><span>{row.diagnosis?.type?.replaceAll("_"," ")||row.processing_status}</span>{row.diagnosis?.related_terms?.length?<small>{[...new Set(row.diagnosis.related_terms)].join(" · ")}</small>:null}{row.diagnosis?.processor==="luna_background"&&<small>Background interpreted</small>}</div></div>)}</div></details>}
    </section>

    <section className="section-block intelligence-priority-section">
      <div className="section-title-line intelligence-filter-head"><div><h2>Priority concepts</h2><p className="muted">Concepts are ranked by exam relevance and current evidence.</p></div></div>
      <div className="intelligence-filter-row" role="tablist" aria-label="Concept filter">
        {[["weak","Needs work"],["retention","Retention"],["coverage","Coverage"],["all","All"]].map(([value,label])=><button key={value} type="button" className={kind===value?"active":""} onClick={()=>{setKind(value);setOpen(null)}}>{label}</button>)}
      </div>
      {loading?<div className="loading-copy compact-loading">Refreshing concept evidence…</div>:priorityRows.length?<div className="intelligence-concept-list">{priorityRows.map(row=>{
        const expanded=open===row.concept_id; const state=labels[row.coverage_state]||row.coverage_state.replaceAll("_"," ");
        return <button className="intelligence-concept-row" key={row.concept_id} onClick={()=>setOpen(expanded?null:row.concept_id)} aria-expanded={expanded}>
          <div className="intelligence-concept-main"><div className="intelligence-concept-title"><b>{row.name}</b><span className={`state-dot state-${row.coverage_state}`}>{state}</span></div><small>{row.skill_family} · {row.exam_relevance} priority</small><div className="confidence-track"><i style={{width:`${Math.max(0,Math.min(100,Number(row.confidence_score)||0))}%`}}/></div>{expanded&&<div className="intelligence-concept-detail"><span><b>{Math.round(Number(row.confidence_score)||0)}%</b> confidence</span><span><b>{row.attempts}</b> attempts</span><span><b>{row.wrong}</b> wrong</span>{row.next_review&&<span>Next check: <b>{new Date(row.next_review).toLocaleDateString()}</b></span>}</div>}</div><span className="row-chevron">{expanded?"−":"›"}</span>
        </button>})}</div>:<div className="empty-state compact-empty"><p className="muted">No concepts in this view right now.</p></div>}
    </section>

    <section className="section-block intelligence-system-section">
      <details className="intelligence-details"><summary>System health & mapping</summary><div className="mapping-health-grid"><div><b>{summary?.mapped_questions??0}</b><span>mapped questions</span></div><div><b>{summary?.unresolved_mappings??0}</b><span>unresolved</span></div><div><b>{summary?.needs_review??0}</b><span>need review</span></div><div><b>{signals?.context_failed??0}</b><span>context failures</span></div></div><p className="muted">Private concept tables stay behind authenticated RPCs. Conservative mappings remain auditable instead of being silently forced.</p></details>
    </section>
  </main>;
}

function Metric({label,value,hint,tone=""}:{label:string;value:number;hint:string;tone?:string}){
  return <div className={`intelligence-kpi ${tone}`}><strong>{value}</strong><span>{label}</span><small>{hint}</small></div>;
}
function SignalStat({label,value,detail}:{label:string;value:number;detail:string}){
  return <div className="intelligence-signal-stat"><strong>{value}</strong><span>{label}</span><small>{detail}</small></div>;
}

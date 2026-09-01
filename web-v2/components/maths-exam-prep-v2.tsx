"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { MathsLoading } from "@/components/maths-frame";
import { mathsCoachRpc, startMathsCoachSession } from "@/lib/maths-coach-rpc";
import { startAiCalculationSprint } from "@/lib/maths-calculation-ai";
import { mathsErrorMessage, type MathsSession, subscribeMathsFresh } from "@/lib/maths-rpc";
import { supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type Track="academic"|"calculation";
type Reason="CAL"|"APP"|"CON"|"FOR"|"SILLY"|"TIME";
type SprintPoint={score:number;at:string};
type Readiness={
  ok:boolean;studyDay:number;examDay?:number;daysLeft?:number;planDays?:number;phase:number;phaseLabel:string;
  knowledge:{score:number;graded:number;correct:number;coldConfirmedFamilies:number};
  performance:{score:number;cleanCorrect:number;slowOrWrong:number};
  repair:{p0:number;due:number;persistentFamilies:number;diagnosisPending:number};
  leakage:Record<string,number>;biggestLeak?:string|null;
  sprint?:{count?:number;best?:number|null;median?:number|null;badDayFloor?:number|null;variance?:number|null;scores?:SprintPoint[]};
};
type CalcSkill={skill:string;total:number;memory:number;methods:number;drills:number;aiGenerated?:number;attempted?:number;accuracy?:number|null;medianSec?:number|null;baselineSec?:number|null;band?:string};
type CalcGroup={label:string;total:number;attempted:number;accuracy:number|null;band:string;rows:CalcSkill[]};
type Calculation={ok:boolean;total:number;aiGenerated?:number;slow:number;wrong:number;durationSec?:number;skills:CalcSkill[];todayFocus?:string[]};
type Active={ok:boolean;active:boolean;sessionId?:string;title?:string;mode?:string;track?:Track;currentIndex?:number;target?:number;remainingSeconds?:number|null;expired?:boolean;aiGenerated?:boolean};
type ExamState={ok:boolean;day:number;daysLeft:number;planDays:number;startDate:string;today:string};
type Weekly={ok:boolean;priorities?:{reason:string;count:number;action:string}[]};
type Data={readiness:Readiness;calculation:Calculation;active:Active;state:ExamState;weekly:Weekly|null};

const reasons:{id:Reason;label:string;sub:string}[]=[
  {id:"APP",label:"Approach",sub:"recognition + transfer"},{id:"CON",label:"Concept",sub:"concept repair"},{id:"FOR",label:"Formula",sub:"active recall + application"},
  {id:"SILLY",label:"Silly",sub:"trap control"},{id:"TIME",label:"Time",sub:"timed method repair"},{id:"CAL",label:"Calculation",sub:"separate speed track"},
];
const buckets=["Fractions / %","Squares / Roots","Cubes / Roots","Tables / ×","Division / Cancel","Approx / Simplify","Number Speed","Ratio / Proportion","SSC Mixed"];
function bucket(skill:string){const s=skill.toLowerCase();if(s.includes("fraction")||s.includes("percentage"))return"Fractions / %";if(s.includes("cube"))return"Cubes / Roots";if(s.includes("square")||s.includes("root"))return"Squares / Roots";if(s.includes("table")||s.includes("multiplication"))return"Tables / ×";if(s.includes("division")||s.includes("cancellation"))return"Division / Cancel";if(s.includes("approx")||s.includes("simpl")||s.includes("surd"))return"Approx / Simplify";if(s.includes("divisib")||s.includes("unit digit")||s.includes("remainder"))return"Number Speed";if(s.includes("ratio")||s.includes("proportion"))return"Ratio / Proportion";return"SSC Mixed";}
function bandRank(x?:string){return x==="Automatic"?4:x==="Strong"?3:x==="Almost there"?2:0;}
function grouped(skills:CalcSkill[]):CalcGroup[]{return buckets.map(label=>{const rows=skills.filter(x=>bucket(x.skill)===label);const total=rows.reduce((a,x)=>a+Number(x.total||0),0);const attempted=rows.reduce((a,x)=>a+Number(x.attempted||0),0);const accuracy=attempted?rows.reduce((a,x)=>a+Number(x.accuracy||0)*Number(x.attempted||0),0)/attempted:null;const measured=rows.filter(x=>Number(x.attempted||0)>0);const band=measured.length?[...measured].sort((a,b)=>bandRank(a.band)-bandRank(b.band))[0]?.band||"Needs work":"Not measured";return{label,total,attempted,accuracy,band,rows};}).filter(x=>x.total>0);}
function score(v:number|null|undefined){if(v==null||!Number.isFinite(Number(v)))return"—";const n=Number(v);return Number.isInteger(n)?String(n):n.toFixed(1);}
function clock(v:number|null|undefined){if(v==null||!Number.isFinite(Number(v)))return"";const n=Math.max(0,Math.ceil(Number(v)));return`${String(Math.floor(n/60)).padStart(2,"0")}:${String(n%60).padStart(2,"0")}`;}
function stats(r:Readiness){const pts=[...(r.sprint?.scores||[])].filter(x=>Number.isFinite(Number(x.score))).sort((a,b)=>Date.parse(b.at)-Date.parse(a.at));const last=pts[0]?.score??null;const five=pts.length?pts.slice(0,5).reduce((a,x)=>a+Number(x.score),0)/Math.min(5,pts.length):null;let streak=0;for(const p of pts){if(Number(p.score)<45)break;streak++;}return{last,five,streak};}
function bandClass(value:string){return value.toLowerCase().replace(/\s+/g,"-");}
async function activeSession():Promise<Active>{const {data,error}=await supabaseBrowser().rpc("maths_get_active_exam_session");if(error)throw error;return(data||{ok:true,active:false}) as Active;}
async function prepState():Promise<ExamState>{const {data,error}=await supabaseBrowser().rpc("maths_get_exam_prep_state");if(error)throw error;return data as ExamState;}

function Metric({label,value}:{label:string;value:string|number}){return <div className="mex2-metric"><small>{label}</small><b>{value}</b></div>;}

export default function MathsExamPreparationV2(){
  const ready=useAuthGuard();const router=useRouter();const[data,setData]=useState<Data|null>(null);const[error,setError]=useState("");const[busy,setBusy]=useState("");const[tab,setTab]=useState<Track>("academic");const[repairOpen,setRepairOpen]=useState(false);const[openCalc,setOpenCalc]=useState<string|null>(null);const[info,setInfo]=useState(false);

  useEffect(()=>{try{const t=new URLSearchParams(window.location.search).get("tab");if(t==="calculation")setTab("calculation");}catch{}},[]);
  const switchTab=(next:Track)=>{setTab(next);setOpenCalc(null);try{const u=new URL(window.location.href);if(next==="calculation")u.searchParams.set("tab","calculation");else u.searchParams.delete("tab");window.history.replaceState(window.history.state,"",`${u.pathname}${u.search}${u.hash}`);}catch{}};
  const load=useCallback(async()=>{const[readiness,calculation,active,state,weekly]=await Promise.all([
    mathsCoachRpc<Readiness>("maths_get_readiness"),mathsCoachRpc<Calculation>("maths_get_calculation_hub"),activeSession(),prepState(),mathsCoachRpc<Weekly>("maths_get_weekly_leakage").catch(()=>null),
  ]);setData({readiness,calculation,active,state,weekly});setError("");},[]);
  useEffect(()=>{if(!ready)return;let alive=true;void load().catch(e=>alive&&setError(mathsErrorMessage(e)));const unsubs=[subscribeMathsFresh<Readiness>("maths_get_readiness",undefined,x=>alive&&setData(p=>p?{...p,readiness:x}:p)),subscribeMathsFresh<Calculation>("maths_get_calculation_hub",undefined,x=>alive&&setData(p=>p?{...p,calculation:x}:p))];return()=>{alive=false;unsubs.forEach(x=>x());};},[ready,load]);

  async function start(kind:"academic"|"calculation"|"repair",reason?:Reason){if(busy)return;setBusy(kind+(reason||""));setError("");try{
    const live=await activeSession();if(live.active&&live.sessionId){setData(p=>p?{...p,active:live}:p);router.push(`/maths/exam/session?id=${encodeURIComponent(live.sessionId)}`);return;}
    let s:MathsSession;if(kind==="academic")s=await startMathsCoachSession("maths_start_sprint",{p_diagnostic:true});else if(kind==="calculation")s=await startAiCalculationSprint();else s=await startMathsCoachSession("maths_start_repair",{p_count:5,p_reason:reason||data?.readiness.biggestLeak||null});
    router.push(`${kind==="repair"?"/maths/session":"/maths/exam/session"}?id=${encodeURIComponent(s.sessionId)}`);
  }catch(e){setError(mathsErrorMessage(e));}finally{setBusy("");}}
  async function abandon(){if(!data?.active.sessionId||busy)return;setBusy("abandon");setError("");try{const{error}=await supabaseBrowser().rpc("maths_abandon_exam_session",{p_session_id:data.active.sessionId});if(error)throw error;await load();}catch(e){setError(mathsErrorMessage(e));}finally{setBusy("");}}

  if(!ready)return <MathsLoading text="Checking Maths session…"/>;if(!data&&!error)return <MathsLoading text="Preparing Exam mode…"/>;if(!data)return <div className="maths-error">{error||"Exam Preparation could not be loaded."}</div>;
  const ss=stats(data.readiness),calc=grouped(data.calculation.skills||[]),measured=calc.filter(x=>x.attempted>0).length,strong=calc.filter(x=>x.band==="Automatic"||x.band==="Strong").length,weak=calc.filter(x=>x.attempted>0&&x.band!=="Automatic"&&x.band!=="Strong").length;
  const active=data.active.active&&data.active.sessionId?data.active:null;const activeSame=active?.track===tab;const biggest=String(data.readiness.biggestLeak||"").toUpperCase() as Reason;const primaryReason=reasons.find(x=>x.id===biggest);
  const academicBlocked=!!active&&active.track!=="academic",calcBlocked=!!active&&active.track!=="calculation";

  return <section className="mex2-page">
    <header className="mex2-head"><Link href="/maths">← Home</Link><div><strong>Exam Preparation</strong><span>Day {data.state.day} · {data.state.daysLeft} days left · 45+ goal</span></div><button type="button" onClick={()=>setInfo(true)} aria-label="Exam Prep information">i</button></header>
    <div className="mex2-tabs" role="tablist"><button className={tab==="academic"?"active":""} onClick={()=>switchTab("academic")} type="button">Academic</button><button className={tab==="calculation"?"active":""} onClick={()=>switchTab("calculation")} type="button">Calculation</button></div>
    {error&&<div className="mex2-error" role="alert">{error}</div>}

    {active&&<section className="mex2-resume"><div><small>{active.track==="academic"?"ACADEMIC SPRINT":"CALCULATION SPRINT"} · timer running</small><strong>{active.title||"Timed Maths session"}</strong><span>Q {Number(active.currentIndex||0)+1}/{active.target||"—"}{active.remainingSeconds!=null?` · ${clock(active.remainingSeconds)} left`:""}</span></div><div><Link href={`/maths/exam/session?id=${encodeURIComponent(active.sessionId!)}`}>Resume</Link><button type="button" disabled={busy==="abandon"} onClick={()=>void abandon()}>{busy==="abandon"?"Ending…":"End"}</button></div></section>}

    {tab==="academic"?<>
      <section className="mex2-hero academic"><div className="mex2-kicker">SSC STANDARD · ACADEMIC ONLY</div><h1>25 Questions · 15 Minutes</h1><p>50 marks · −0.50 wrong · balanced academic section · 48h exact-question cooling</p>{activeSame?<Link className="mex2-primary" href={`/maths/exam/session?id=${encodeURIComponent(active!.sessionId!)}`}>Resume Academic Sprint</Link>:<button className="mex2-primary" type="button" disabled={!!busy||academicBlocked} onClick={()=>void start("academic")}>{busy==="academic"?"Starting…":academicBlocked?"End Calculation Sprint first":"Start Academic Sprint"}</button>}</section>
      <div className="mex2-metrics"><Metric label="Last" value={score(ss.last)}/><Metric label="5-Sprint Avg" value={score(ss.five)}/><Metric label="45+ Streak" value={ss.streak}/></div>
      <p className="mex2-note">Only completed Day-1-onward Academic Sprints affect these readiness scores. Calculation never inflates Academic readiness.</p>
      <section className="mex2-plan"><small>TODAY · DAY {data.state.day}</small>{biggest==="CAL"?<><strong>Calculation is costing academic marks</strong><p>Keep chapter learning separate; repair the speed leak in the Calculation tab.</p><button type="button" onClick={()=>switchTab("calculation")}>Open Calculation</button></>:primaryReason?<><strong>{primaryReason.label} is the biggest academic leak</strong><p>{primaryReason.sub}</p><button type="button" disabled={!!busy||!!active} onClick={()=>void start("repair",primaryReason.id)}>{busy.startsWith("repair")?"Starting…":"Repair 5"}</button></>:<><strong>Build your Day {data.state.day} baseline</strong><p>Finish one fresh Standard Sprint first; then the system will rank your marks leakage.</p><button type="button" disabled={!!busy||!!active} onClick={()=>void start("academic")}>Start baseline</button></>}</section>
      <section className="mex2-shortcuts"><Link href="/maths/chapters"><span>Academic Chapters</span><small>chapter / topic practice</small><b>›</b></Link><Link href="/maths/concepts"><span>Academic Concepts</span><small>saved concept questions only</small><b>›</b></Link></section>
      <section className="mex2-repair"><div><strong>Targeted Repair</strong><button type="button" aria-expanded={repairOpen} onClick={()=>setRepairOpen(x=>!x)}>{repairOpen?"Less":"More"}</button></div>{repairOpen&&<div className="mex2-repair-grid">{reasons.filter(x=>x.id!=="CAL").map(r=><button key={r.id} type="button" disabled={!!busy||!!active} onClick={()=>void start("repair",r.id)}><b>{r.id}</b><span>{r.label}</span></button>)}</div>}</section>
    </>:<>
      <section className="mex2-hero calculation"><div className="mex2-kicker">SSC CALCULATION SPEED · SEPARATE TRACK</div><h1>10:00 · Unlimited Stream</h1><p>Fresh SSC-style calculation micro-drills · AI generated + independent arithmetic critic · auto-refill while the timer runs</p>{activeSame?<Link className="mex2-primary" href={`/maths/exam/session?id=${encodeURIComponent(active!.sessionId!)}`}>Resume Calculation Sprint</Link>:<button className="mex2-primary" type="button" disabled={!!busy||calcBlocked} onClick={()=>void start("calculation")}>{busy==="calculation"?"Building quality-checked set…":calcBlocked?"End Academic Sprint first":"Start 10:00 Calculation Sprint"}</button>}<div className="mex2-quality"><span>2-pass QC</span><span>no concept questions</span><span>no Academic score impact</span></div></section>
      <div className="mex2-metrics"><Metric label="Measured skills" value={`${measured}/${calc.length}`}/><Metric label="Strong" value={strong}/><Metric label="Need work" value={weak}/></div>
      <section className="mex2-calc-focus"><small>WHAT IT TRAINS</small><strong>Arithmetic automaticity used inside SSC questions</strong><p>Fractions/percentages, squares/roots, cubes, tables & products, cancellation/division, approximation/simplification, number speed, ratio arithmetic and mixed SSC working.</p></section>
      <section className="mex2-calc-diagnostics">
        <div className="mex2-calc-title"><div><small>CALCULATION CHAPTERS</small><strong>Skill diagnostics</strong></div><span>Tap any row to expand</span></div>
        <div className="mex2-calc-accordion-list">{calc.map(x=>{const open=openCalc===x.label;return <article className={`mex2-calc-accordion ${open?"open":""}`} key={x.label}>
          <button type="button" aria-expanded={open} aria-controls={`calc-${x.label.replace(/[^a-z0-9]+/gi,"-").toLowerCase()}`} onClick={()=>setOpenCalc(open?null:x.label)}>
            <span className="mex2-calc-row-copy"><b>{x.label}</b><small>{x.attempted?`${x.attempted} measured${x.accuracy==null?"":` · ${x.accuracy.toFixed(0)}% accuracy`}`:`${x.total} available · build evidence`}</small></span>
            <strong className={`band-${bandClass(x.band)}`}>{x.band}</strong><i aria-hidden="true">⌄</i>
          </button>
          {open&&<div className="mex2-calc-accordion-body" id={`calc-${x.label.replace(/[^a-z0-9]+/gi,"-").toLowerCase()}`}>
            <div className="mex2-calc-body-summary"><span><small>Available</small><b>{x.total}</b></span><span><small>Measured</small><b>{x.attempted}</b></span><span><small>Accuracy</small><b>{x.accuracy==null?"—":`${x.accuracy.toFixed(0)}%`}</b></span></div>
            <div className="mex2-calc-subskills">{x.rows.map(r=><div key={r.skill}><span><b>{r.skill}</b><small>{Number(r.attempted||0)>0?`${r.attempted} measured · ${r.accuracy==null?"—":`${Number(r.accuracy).toFixed(0)}%`}`:`${r.total} available`}</small></span><span><b>{r.medianSec==null||Number(r.medianSec)<=0?"—":`${Number(r.medianSec).toFixed(1)}s`}</b><small>{r.baselineSec==null||Number(r.baselineSec)<=0?"median time":`target ${Number(r.baselineSec).toFixed(1)}s`}</small></span></div>)}</div>
          </div>}
        </article>;})}</div>
      </section>
    </>}

    {info&&<div className="mex2-modal-bg" onMouseDown={e=>{if(e.target===e.currentTarget)setInfo(false)}}><section className="mex2-modal" role="dialog" aria-modal="true"><header><div><strong>How Exam Prep learns</strong><span>Two tracks, one 45+ objective.</span></div><button type="button" onClick={()=>setInfo(false)}>×</button></header><p><b>Academic</b> measures SSC chapter performance and drives APP / CON / FOR / SILLY / TIME repair. A CAL miss can route you to Calculation, but Calculation attempts never enter Academic readiness.</p><p><b>Calculation</b> is a separate 10-minute automaticity stream. Generated items stay in the isolated CALCULATION_AI bank and cannot enter Daily, Chapters or Concepts.</p><div className="mex2-info-grid"><Metric label="Knowledge" value={`${score(data.readiness.knowledge.score)}%`}/><Metric label="Performance" value={`${score(data.readiness.performance.score)}%`}/><Metric label="Bad-day floor" value={score(data.readiness.sprint?.badDayFloor)}/><Metric label="P0 repairs" value={data.readiness.repair.p0}/></div></section></div>}
  </section>;
}

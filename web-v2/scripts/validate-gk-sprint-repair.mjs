import fs from "node:fs";
import path from "node:path";

const root=path.resolve(process.cwd(),"..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const must=(ok,msg)=>{if(!ok)throw new Error(`GK Sprint repair contract failed: ${msg}`)};
const has=(t,...xs)=>xs.every(x=>t.includes(x));

const migration=read("supabase/managed-migrations/20260831150000_gk_v2_sprint_repair_intelligence.sql");
const bridge=read("supabase/managed-migrations/20260831150500_gk_v2_sprint_repair_set_bridge.sql");
const sprint=read("web-v2/app/gk/sprint/page.tsx");
const launcher=read("web-v2/app/gk/sprint/repair/page.tsx");
const css=read("web-v2/app/gk/gk-sprint-repair.css");
const layout=read("web-v2/app/gk/layout.tsx");
const workflow=read(".github/workflows/validate-gk-v2.yml");

must(has(migration,"gk.exam_diagnostics","unique(session_id,concept_key)","analysis_generated_at","source_kind"),"idempotent derived exam diagnostics missing");
must(has(migration,"gk_start_section_sprint(p_count integer,p_source text)","TEACHER_PYQ","TOPIC_PYQ","MIXED_PYQ","content_lane"),"Teacher PYQ Sprint must reuse canonical memberships and Main lane");
must(has(migration,"gk_get_section_sprint_analysis","marksLostWrong","marksLostUnattempted","Slow Correct","Slow Wrong","Fast Wrong","repeatWeakness"),"structured Sprint loss analysis missing");
must(has(migration,"wrong_count*5","greatest(wrong_count+unattempted_count-1,0)*4","existing '||current_state||' state","Teacher PYQ available"),"deterministic explainable repair score missing");
must(has(migration,"own-response-median","conservative-defaults","time-heavy response","fast incorrect response"),"robust non-psychological response-time signals missing");
must(has(migration,"gk_get_sprint_repair_batch","not is_failed and teacher_pyq","failed_rank=1","content_lane"),"balanced canonical repair selection missing");
must(!migration.toLowerCase().includes("delete from gk.attempts")&&!migration.toLowerCase().includes("delete from gk.exposures")&&!migration.toLowerCase().includes("delete from gk.sessions"),"historical evidence deletion is forbidden");
for(const fn of ["gk_finish_section_sprint","gk_analyze_section_sprint"]){const start=migration.indexOf(`function public.${fn}`),end=migration.indexOf("$$;",start);const body=migration.slice(start,end);must(!body.includes("insert into gk.attempts")&&!body.includes("insert into gk.exposures")&&!body.includes("question_state"),`${fn} must not mutate adaptive learning evidence`);}
must(has(migration,"evidenceConfidence","Limited evidence","Developing evidence","Reliable evidence","greatest(p.exposure_count,case when p.attempts>0 then 1 else 0 end)"),"Progress evidence-confidence / attempted-as-seen guard missing");
must(has(bridge,"gk_create_sprint_repair_set","gk_get_sprint_repair_batch","gk.demand_sets","kind,'sprint_repair'"),"repair bridge must reuse canonical Demand selector container");
must(!bridge.includes("gk_submit_answer")&&!bridge.includes("gk_record_exposure"),"repair-set preparation must not mutate learning evidence");

must(has(sprint,"Exam Mixed","Teacher PYQ Sprint","25 Questions · 15 Minutes","gk_finish_section_sprint","gk_analyze_section_sprint","Result saved.","Start Smart Repair","Start Repair","Where marks were lost"),"Sprint result/repair UX contract missing");
must(sprint.indexOf("setResult(x.result)")<sprint.indexOf("loadAnalysis(session.sessionId,true)"),"result must become available before repair analysis begins");
must(!sprint.includes("gk_submit_answer")&&!sprint.includes("gk_record_exposure"),"timed Sprint UI must remain isolated from adaptive mutations");
must(has(launcher,"gk_create_sprint_repair_set",'mode:"demand"','window.location.replace(`/gk/quiz?'),"normal GK QuizEngine"),"repair launcher must converge into existing QuizEngine");
must(!launcher.includes("gk_submit_answer")&&!launcher.includes("gk_record_exposure"),"launcher must not become a second learning mutation path");
must(has(css,"var(--card)","var(--text)","var(--muted)","var(--line)","var(--primary)","@media(max-width:560px)"),"repair UI must remain theme/mobile safe");
must(layout.includes('./gk-sprint-repair.css'),"Sprint repair CSS is not loaded");
must(workflow.includes("gk-v2-sprint-repair-intelligence")&&workflow.includes("gk-ci-sprint-repair-assertions.sql"),"Sprint repair clean-room CI is not wired");

console.log("GK Sprint repair source contracts passed");

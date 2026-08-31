import fs from "node:fs";
import path from "node:path";

const root=path.resolve(process.cwd(),"..");
const read=(p)=>fs.readFileSync(path.join(root,p),"utf8");
const must=(ok,msg)=>{if(!ok)throw new Error(`GK final intelligence contract failed: ${msg}`)};
const has=(text,...needles)=>needles.every(x=>text.includes(x));

const foundation=read("supabase/managed-migrations/20260831133000_gk_v2_teacher_intelligence_and_exam_readiness.sql");
const teacherSelector=read("supabase/managed-migrations/20260831134000_gk_v2_teacher_series_selector.sql");
const sprintFix=read("supabase/managed-migrations/20260831134500_gk_v2_section_sprint_finalizer_fix.sql");
const quiz=read("web-v2/app/gk/quiz/page.tsx");
const teacher=read("web-v2/app/gk/teacher/page.tsx");
const progress=read("web-v2/app/gk/intelligence/page.tsx");
const sprint=read("web-v2/app/gk/sprint/page.tsx");
const layout=read("web-v2/app/gk/layout.tsx");
const workflow=read(".github/workflows/validate-gk-v2.yml");

must(has(foundation,"gk.question_source_memberships","gk.content_series","gk.question_enrichments","gk.concept_confusions","gk.canonical_duplicate_review"),"teacher provenance/enrichment tables missing");
must(has(foundation,"TEACHER_TOPIC_PYQ","TEACHER_MIXED_PYQ","GPT_BOOSTER"),"Topic/Mixed/GPT Booster provenance missing");
must(has(foundation,"gk.exam_sessions","gk.exam_answers","learningHistoryChanged"),"isolated Section Sprint evidence contract missing");
must(!foundation.includes("delete from gk.attempts")&&!foundation.includes("delete from gk.exposures")&&!foundation.includes("delete from gk.sessions"),"historical evidence must never be deleted");

must(has(teacherSelector,"select distinct m.question_id","gk.learning_profiles_v2","gk.question_payload_v2_read"),"Teacher selector must dedupe memberships into canonical Question_IDs and use authoritative profile");
must(!teacherSelector.includes("insert into gk.attempts")&&!teacherSelector.includes("insert into gk.question_state"),"Teacher selector must remain read-only");

must(has(quiz,'activeParams.get("teacherSeries")','"gk_get_teacher_batch"'),"Teacher series must reuse the canonical GK quiz runner");
must(has(quiz,"Statement\\s+\\d+","\\(\\d+\\)","hits.length>=2","hits[0].n===1"),"safe statement renderer variants/regression guard missing");
must(has(teacher,'href={qs({teacherSeries:series','/gk/quiz?'),"Teacher PYQ navigation must reuse existing quiz engine");

must(has(progress,"GK Readiness","Needs Attention","Teacher Content Completion","Question Bank Exposure","Knowledge Retention","Knowledge Story","SSC Coverage Matrix"),"insights-first Progress contracts missing");
must(has(sprint,"25 Questions · 15 Minutes","gk_start_section_sprint","gk_finish_section_sprint","answersRef.current"),"Section Sprint timer/resume/finalizer contracts missing");
must(!sprint.includes("gk_submit_answer")&&!sprint.includes("gk_record_exposure"),"timed exam mode must not write adaptive learning evidence");
must(has(sprintFix,"result_json","jsonb_array_elements_text(s.question_ids) as ids(question_id)","learningHistoryChanged"),"Section Sprint finalizer hardening missing");

must(has(layout,'href="/gk/teacher"','href="/gk/intelligence"','href="/gk/sprint"','p.get("tab")==="progress"'),"GK shell must expose Teacher/Progress/Sprint and redirect legacy Progress");
must(workflow.includes("2026083*_gk*.sql")&&workflow.includes("gk-ci-final-intelligence-assertions.sql"),"clean-room CI must include final GK migrations/assertions");

const forbidden=["web-v2/app/maths/","web-v2/lib/math"];
for(const item of forbidden)must(![foundation,teacherSelector,sprintFix,quiz,teacher,progress,sprint,layout].some(t=>t.includes(item)),`GK final files unexpectedly reference ${item}`);

console.log("GK final intelligence source contracts passed");

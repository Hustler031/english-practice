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
const questionText=read("web-v2/app/gk/question-text.tsx");
const teacher=read("web-v2/app/gk/teacher/page.tsx");
const progress=read("web-v2/app/gk/intelligence/page.tsx");
const sprint=read("web-v2/app/gk/sprint/page.tsx");
const layout=read("web-v2/app/gk/layout.tsx");
const navCss=read("web-v2/app/gk/gk-navigation-structure.css");
const practiceCss=read("web-v2/app/gk/gk-practice-hierarchy.css");
const workflow=read(".github/workflows/validate-gk-v2.yml");

must(has(foundation,"gk.question_source_memberships","gk.content_series","gk.question_enrichments","gk.concept_confusions","gk.canonical_duplicate_review"),"teacher provenance/enrichment tables missing");
must(has(foundation,"TEACHER_TOPIC_PYQ","TEACHER_MIXED_PYQ","GPT_BOOSTER"),"Topic/Mixed/GPT Booster provenance missing");
must(has(foundation,"gk.exam_sessions","gk.exam_answers","learningHistoryChanged"),"isolated Section Sprint evidence contract missing");
must(!foundation.includes("delete from gk.attempts")&&!foundation.includes("delete from gk.exposures")&&!foundation.includes("delete from gk.sessions"),"historical evidence must never be deleted");

must(has(teacherSelector,"select distinct m.question_id","gk.learning_profiles_v2","gk.question_payload_v2_read"),"Teacher selector must dedupe memberships into canonical Question_IDs and use authoritative profile");
must(!teacherSelector.includes("insert into gk.attempts")&&!teacherSelector.includes("insert into gk.question_state"),"Teacher selector must remain read-only");

must(has(quiz,'activeParams.get("teacherSeries")','"gk_get_teacher_batch"','QuestionText text={q.question}'),"Teacher series and structured text must reuse the canonical GK quiz runner");
must(has(questionText,"Assertion","Reason","Statement\\s+\\d+","\\(\\d+\\)","hits.length>=2","hits[0].n===1"),"shared assertion/reason + safe statement renderer regression guard missing");
must(has(teacher,'href={qs({teacherSeries:series','/gk/quiz?'),"Teacher PYQ navigation must reuse existing quiz engine");

must(has(progress,"GK Readiness","Needs Attention","Teacher Content Completion","Question Bank Exposure","Knowledge Retention","Knowledge Story","Subject readiness","gk-intel-fold"),"organized insights-first Progress contracts missing");
must(has(progress,'<a href="/gk/intelligence">← Progress</a>'),"Progress detail back navigation must force a reliable route reset");
must(has(sprint,"25 Questions · 15 Minutes","gk_start_section_sprint","gk_finish_section_sprint","answersRef.current","function leaveExam()",'QuestionText text={q.question}'),"Section Sprint timer/resume/back/structured question contracts missing");
must(!sprint.includes("gk_submit_answer")&&!sprint.includes("gk_record_exposure"),"timed exam mode must not write adaptive learning evidence");
must(has(sprintFix,"result_json","jsonb_array_elements_text(s.question_ids) as ids(question_id)","learningHistoryChanged"),"Section Sprint finalizer hardening missing");

must(has(layout,'href="/gk/sprint"','href="/gk/teacher"','"/gk/intelligence"','gk-shell-bottomnav','p.get("tab")==="progress"'),"GK shell must keep Sprint, Teacher in Practice, shared bottom Progress, and redirect legacy Progress");
must(!layout.includes('["demand","◆","On Demand"'),"On Demand must remain legacy-compatible but not primary navigation");
must(has(layout,"gk-practice-prelude","PRIMARY PRACTICE","Teacher PYQ first","GPT Booster","Weakness Fix","Confusion Cards","Reverse Recall","Exam Traps"),"Teacher-first Practice + future GPT Booster contract missing");
must(!layout.includes('href="/gk/teacher" className="gk-shell-intelligence"')&&!layout.includes('href="/gk/intelligence" className="gk-shell-intelligence"'),"Teacher and Progress must not duplicate bottom navigation in header");
must(has(navCss,"gk-shell-bottomnav","gk-intel-fold","gk-sprint-back"),"GK navigation/organization CSS contract missing");
must(has(practiceCss,"repeat(4,minmax(0,1fr))","nth-child(4)","gk-practice-teacher-hero","gk-booster-future","Smart practice tools","color-mix(in srgb,var(--bg) 96%"),"Practice hierarchy, obsolete-nav hiding, and theme-safe shell CSS missing");
must(workflow.includes("2026083*_gk*.sql")&&workflow.includes("gk-ci-final-intelligence-assertions.sql"),"clean-room CI must include final GK migrations/assertions");

const forbidden=["web-v2/app/maths/","web-v2/lib/math"];
for(const item of forbidden)must(![foundation,teacherSelector,sprintFix,quiz,questionText,teacher,progress,sprint,layout,navCss,practiceCss].some(t=>t.includes(item)),`GK final files unexpectedly reference ${item}`);

console.log("GK final intelligence source contracts passed");

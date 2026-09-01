import fs from "node:fs";
import path from "node:path";

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const exists=p=>fs.existsSync(path.join(root,p));
const coach=read("components/maths-coach.tsx");
const rpc=read("lib/maths-coach-rpc.ts");
const layout=read("app/maths/layout.tsx");
const homeRoute=read("app/maths/page.tsx");
const home=read("components/maths-home.tsx");
const calculation=read("app/maths/calculation/page.tsx");
const session=read("app/maths/session/page.tsx");
const progress=read("app/maths/progress/page.tsx");
const readiness=read("app/maths/readiness/page.tsx");
const examRoute=read("app/maths/exam/page.tsx");
const examSessionRoute=read("app/maths/exam/session/page.tsx");
const exam=read("components/maths-exam-prep.tsx");
const examSession=read("components/maths-exam-session.tsx");
const frame=read("components/maths-frame.tsx");
const warmup=read("components/maths-runtime-warmup.tsx");
const examCss=read("app/maths/maths-exam-prep.css");
const examMigration=read("../supabase/managed-migrations/20260901143000_maths_exam_prep_foundation.sql");
const examHardening=read("../supabase/managed-migrations/20260901153000_maths_exam_prep_runtime_hardening.sql");
const pkg=JSON.parse(read("package.json"));
const failures=[];
const has=(label,text,needle)=>{if(!text.includes(needle))failures.push(`${label}: missing ${needle}`)};

for(const route of ["readiness","repair","approach","sprint","mixed","exam","exam/session"]){
  const p=`app/maths/${route}/page.tsx`;
  if(!exists(p))failures.push(`Maths additive route missing: ${p}`);
}

has("Maths home route",homeRoute,"MathsHome");
for(const [label,text] of [
  ["Restored Maths calculation",calculation],
  ["Restored Maths session",session],
  ["Restored Maths progress",progress],
]) has(label,text,"MathsApp");
for(const marker of [
  "maths_get_home_snapshot","EXAM PREPARATION","/maths/exam","Quick Start","maths_start_daily",
  "/maths/exam/session","10[- ]min calculation drill",
]) has("Clean Maths home",home,marker);

has("Exam Preparation route",examRoute,"MathsExamPreparation");
has("Exam timed route",examSessionRoute,"MathsExamSessionPage");
for(const marker of [
  "25 Questions · 15 Minutes","45+ goal","5-Sprint Avg","45+ Streak","maths_get_readiness",
  "maths_get_calculation_hub","Fractions / %","Squares / Roots","Cubes / Roots","Tables / ×",
  "Division / Cancel","Approx / Simplify","Number Speed","Ratio / Proportion","SSC Mixed",
  "maths_get_active_exam_session","remainingSeconds","maths_start_sprint","maths_start_calculation","maths_start_repair",
  "CAL","APP","CON","FOR","SILLY","TIME",
]) has("Exam Preparation UI",exam,marker);
for(const marker of [
  "deadlineAt","maths_finish_session","maths_submit_answer","p_client_attempt_key","maths_get_sprint_analysis",
  "maths_get_sprint_review","maths_confirm_diagnosis","maths_get_calculation_summary","QuestionMap","Marked for review",
  "POSITION_PREFIX","maths_exam_runtime_checkpoint","checkpointChain","freshRpc","selectedOptionText","correctOptionText",
]) has("Exam timed session",examSession,marker);

for(const marker of [
  "Maths Performance Coach","Knowledge Readiness","Performance Readiness","Repair Queue",
  "10-Min Calculation Drill","25 Questions · 15 Minutes","Approach Cards","Mixed Practice",
  "SOLVE","LATER","SKIP","Why did I miss it?","SSC Fast Path","recoverableMarksEstimate",
  "badDayFloor","coldConfirmedFamilies","diagnosisPending"
]) has("Coach UI",coach,marker);
for(const rpcName of [
  "maths_get_readiness","maths_get_weekly_leakage","maths_get_repair_queue","maths_start_repair",
  "maths_start_mixed","maths_start_sprint","maths_start_calculation","maths_get_calculation_summary",
  "maths_get_sprint_analysis","maths_get_approach_hub","maths_record_approach_recall",
  "maths_confirm_diagnosis","maths_record_confidence","maths_record_selection",
  "maths_refill_calculation_session","maths_get_question_fast_path","maths_get_local_safe_start_v45"
]) has("Coach RPC",coach+rpc,rpcName);
for(const marker of ["deadlineAt","formatClock","maths_finish_session","maths_submit_answer","p_client_attempt_key"]) has("Timer/session",coach,marker);
for(const marker of ["mathsLocalSafe","coachCriticalWrites","maths_get_local_safe_start_v45"]) has("Local Safe",rpc,marker);

has("Dedicated readiness route",readiness,"MathsReadinessPage");
has("Maths coach CSS",layout,'"./maths-coach.css"');
has("English-parity Maths CSS",layout,'"./maths-english-parity.css"');
has("Exam Preparation CSS",layout,'"./maths-exam-prep.css"');
has("Exam route isolated in frame",frame,"maths-exam-route");
has("Exam session isolated in frame",frame,"maths-exam-session");
has("Exam focus shell CSS",examCss,"maths-app.maths-exam-route>.maths-header");
has("Exam warmup",warmup,"prefetchExam");
has("Timed warmup guard",warmup,"/maths/exam/session");

for(const marker of [
  "interval '48 hours'","hard_recent","maths_get_sprint_review","freshnessPolicy","coolingHours",
  "section_sprint","maths_start_sprint",
]) has("Exam Preparation migration",examMigration,marker);
if(!/order by\s+hard_recent asc,chapter_rn asc,h asc/i.test(examMigration))failures.push("Exam Preparation migration: fresh Sprint ordering contract missing");

for(const marker of [
  "hide_exam_answers","e - 'answer' - 'explanation' - 'memoryCue' - 'correctOption'",
  "'result','saved'","maths_get_active_exam_session","maths_exam_runtime_checkpoint",
  "sessions_one_active_timed_exam_per_user","selected_option_text","correct_option_text",
  "A timed Maths session is already active","deadlineAt","maths_start_calculation",
]) has("Exam runtime hardening migration",examHardening,marker);

if(pkg.scripts?.["contracts:maths"]!=="node scripts/validate-maths-contracts.mjs && node scripts/validate-maths-coach.mjs")failures.push("package.json: contracts:maths must include coach validator");
for(const file of [
  "20260831095812_maths_v2_performance_intelligence_foundation.sql",
  "20260831100518_maths_v2_performance_coach_practice.sql",
  "20260831103315_maths_v2_timer_identity_and_weekly_coach_hardening.sql",
  "20260831110000_maths_v2_question_fast_path_read.sql",
  "20260831111200_maths_v2_external_reviewed_canonical_ingest.sql",
  "20260901143000_maths_exam_prep_foundation.sql",
  "20260901153000_maths_exam_prep_runtime_hardening.sql",
]){
  if(!exists(`../supabase/managed-migrations/${file}`))failures.push(`Maths migration mirror missing: ${file}`);
}
const external=read("../supabase/managed-migrations/20260831111200_maths_v2_external_reviewed_canonical_ingest.sql");
for(const marker of ["maths_create_canonical_from_external_stage","review_created_canonical","external_review_confirmed","EXT_"])has("External canonical review",external,marker);
if(failures.length){console.error("Maths coach contract validation FAILED\n- "+failures.join("\n- "));process.exit(1)}
console.log("Maths coach contract validation PASS");

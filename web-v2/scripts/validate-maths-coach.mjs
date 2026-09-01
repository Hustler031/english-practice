import fs from "node:fs";
import path from "node:path";

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const exists=p=>fs.existsSync(path.join(root,p));
const coach=read("components/maths-coach.tsx");
const rpc=read("lib/maths-coach-rpc.ts");
const calcClient=read("lib/maths-calculation-ai.ts");
const layout=read("app/maths/layout.tsx");
const homeRoute=read("app/maths/page.tsx");
const home=read("components/maths-home.tsx");
const calculation=read("app/maths/calculation/page.tsx");
const session=read("app/maths/session/page.tsx");
const progress=read("app/maths/progress/page.tsx");
const readiness=read("app/maths/readiness/page.tsx");
const examRoute=read("app/maths/exam/page.tsx");
const examSessionRoute=read("app/maths/exam/session/page.tsx");
const exam=read("components/maths-exam-prep-v2.tsx");
const examSession=read("components/maths-exam-session-v2.tsx");
const frame=read("components/maths-frame.tsx");
const warmup=read("components/maths-runtime-warmup.tsx");
const examCss=read("app/maths/maths-exam-v2.css");
const accordionCss=read("app/maths/maths-exam-accordion.css");
const examMigration=read("../supabase/managed-migrations/20260901143000_maths_exam_prep_foundation.sql");
const examHardening=read("../supabase/managed-migrations/20260901153000_maths_exam_prep_runtime_hardening.sql");
const boundary=read("../supabase/managed-migrations/20260901172000_maths_academic_calculation_boundary.sql");
const aiCalc=read("../supabase/managed-migrations/20260901173000_maths_ai_calculation_sprint.sql");
const timedSecrecy=read("../supabase/managed-migrations/20260901174000_maths_all_timed_answer_secrecy.sql");
const edge=read("../supabase/functions/maths-ssc-calculation/index.ts");
const pkg=JSON.parse(read("package.json"));
const failures=[];
const has=(label,text,needle)=>{if(!text.includes(needle))failures.push(`${label}: missing ${needle}`)};

for(const route of ["readiness","repair","approach","sprint","mixed","exam","exam/session"]){const p=`app/maths/${route}/page.tsx`;if(!exists(p))failures.push(`Maths additive route missing: ${p}`);}
has("Maths home route",homeRoute,"MathsHome");
for(const [label,text] of [["Restored Maths session",session],["Restored Maths progress",progress]])has(label,text,"MathsApp");
has("Calculation route",calculation,"MathsCalculationRedirect");has("Calculation route",calculation,"/maths/exam?tab=calculation");
for(const marker of ["maths_get_home_snapshot","maths_get_exam_prep_state","EXAM PREPARATION","Day {exam?.day??1}","Quick Start","maths_start_daily","academic question bank only · Calculation excluded","/maths/exam/session"])has("Clean Maths home",home,marker);

has("Exam Preparation route",examRoute,"MathsExamPreparationV2");has("Exam timed route",examSessionRoute,"MathsExamSessionV2");
for(const marker of [
  'type Track="academic"|"calculation"','Academic','Calculation','SSC STANDARD · ACADEMIC ONLY','25 Questions · 15 Minutes','45+ goal','5-Sprint Avg','45+ Streak',
  '10:00 · Unlimited Stream','startAiCalculationSprint','AI generated + independent arithmetic critic','no Academic score impact','maths_get_exam_prep_state','maths_get_active_exam_session',
  'maths_get_readiness','maths_get_calculation_hub','maths_start_sprint','maths_start_repair','Academic Chapters','Academic Concepts','CAL','APP','CON','FOR','SILLY','TIME',
  'CALCULATION CHAPTERS','openCalc','aria-expanded={open}','mex2-calc-accordion','mex2-calc-subskills','medianSec','baselineSec'
])has("Exam Preparation V2 UI",exam,marker);
for(const marker of [
  'QuestionStrip','MapModal','answered','review','visited','current','Questions','maths_exam_runtime_checkpoint','checkpoint','maths_submit_answer','p_client_attempt_key',
  'refillAiCalculationSprint','adding more…','maths_get_sprint_analysis','maths_get_sprint_review','maths_confirm_diagnosis','maths_get_calculation_summary','result:"saved"'
])has("Exam timed V2 session",examSession,marker);
for(const marker of ['.mexq-strip button.answered','.mexq-strip button.review','.mexq-strip button.current','.mexq-nav button.questions','width:min(700px,100%)','env(safe-area-inset-bottom)','@media(max-width:420px)'])has("Exam V2 visual authority",examCss,marker);
for(const marker of ['.mex2-calc-accordion-list','.mex2-calc-accordion.open','.mex2-calc-accordion>button','.mex2-calc-accordion-body','.mex2-calc-subskills','@media(max-width:420px)','prefers-reduced-motion'])has("Calculation accordion polish",accordionCss,marker);

for(const marker of ["Maths Performance Coach","Knowledge Readiness","Performance Readiness","Repair Queue","10-Min Calculation Drill","25 Questions · 15 Minutes","Approach Cards","Mixed Practice","SOLVE","LATER","SKIP","Why did I miss it?","SSC Fast Path","recoverableMarksEstimate","badDayFloor","coldConfirmedFamilies","diagnosisPending"])has("Coach UI",coach,marker);
for(const rpcName of ["maths_get_readiness","maths_get_weekly_leakage","maths_get_repair_queue","maths_start_repair","maths_start_mixed","maths_start_sprint","maths_start_calculation","maths_get_calculation_summary","maths_get_sprint_analysis","maths_get_approach_hub","maths_record_approach_recall","maths_confirm_diagnosis","maths_record_confidence","maths_record_selection","maths_refill_calculation_session","maths_get_question_fast_path","maths_get_local_safe_start_v45"])has("Coach RPC",coach+rpc,rpcName);
for(const marker of ["mathsLocalSafe","coachCriticalWrites","maths_get_local_safe_start_v45"])has("Local Safe",rpc,marker);

has("Dedicated readiness route",readiness,"MathsReadinessPage");has("Maths coach CSS",layout,'"./maths-coach.css"');has("English-parity Maths CSS",layout,'"./maths-english-parity.css"');has("Exam legacy CSS",layout,'"./maths-exam-prep.css"');has("Exam V2 CSS",layout,'"./maths-exam-v2.css"');has("Exam accordion CSS last",layout,'"./maths-exam-accordion.css"');
if(layout.lastIndexOf('"./maths-exam-accordion.css"')<layout.lastIndexOf('"./maths-exam-v2.css"'))failures.push("Exam accordion CSS must load after Exam V2 CSS");
has("Exam route isolated in frame",frame,"maths-exam-route");has("Exam session isolated in frame",frame,"maths-exam-session");has("Exam warmup",warmup,"prefetchExam");has("Timed warmup guard",warmup,"/maths/exam/session");

for(const marker of ["interval '48 hours'","hard_recent","maths_get_sprint_review","freshnessPolicy","coolingHours","section_sprint","maths_start_sprint"])has("Exam Preparation migration",examMigration,marker);
for(const marker of ["maths_get_active_exam_session","maths_exam_runtime_checkpoint","sessions_one_active_timed_exam_per_user","selected_option_text","correct_option_text","deadlineAt"])has("Exam runtime hardening migration",examHardening,marker);

for(const marker of [
  "maths.exam_prep_config","date '2026-09-01'","maths_get_exam_prep_state","r.academic_eligible","_select_daily_ids_v45","Calculation training is separate from Academic Concepts",
  "not (r.bank_calculation or r.in_calc_set","s.set_id<>'CALC_TRAINING'","'calculation',0","lower(coalesce(s.mode,''))<>'calculation_speed'","'examDay'"
])has("Academic / Calculation boundary",boundary,marker);
for(const marker of [
  "maths.generated_calculation_meta","maths.calculation_ai_usage","CALCULATION_AI","maths_get_calculation_generation_context","quality_score","maths_create_ai_calculation_session",
  "maths_append_ai_calculation_items","maths_abandon_exam_session","'10-Min SSC Calculation Sprint'","'aiGenerated',true","'examPrep',true","maths._sprint_stability",
  "expected_answer_","option_count_","expected_<3 or expected_>60","end;\n$$;"
])has("AI Calculation backend",aiCalc,marker);
for(const marker of ["timed_ and not s.completed","'result',case when hide_answers then 'saved'","e-'answer'-'explanation'-'memoryCue'-'correctOption'","if timed_ then","'result','saved'"])has("All timed answer secrecy",timedSecrecy,marker);

for(const marker of ["maths-ssc-calculation","gpt-5.6-luna","OPENAI_API_KEY","FractionsPercentages","SSCMixed","INDEPENDENT arithmetic verifier","qualityScore","expectedSec","answerText","recentGenerated","maths_create_ai_calculation_session","maths_append_ai_calculation_items","maths_log_calculation_ai_usage",'sourceType:{type:"string",enum:["AI Generated SSC Calculation","AI Variant of Calculation Pattern"]}'])has("Calculation Edge quality gate",edge,marker);
for(const marker of ["maths-ssc-calculation","startAiCalculationSprint","refillAiCalculationSprint","mathsLocalSafe"])has("Calculation AI client",calcClient,marker);

if(pkg.scripts?.["contracts:maths"]!=="node scripts/validate-maths-contracts.mjs && node scripts/validate-maths-coach.mjs")failures.push("package.json: contracts:maths must include coach validator");
for(const file of [
  "20260831095812_maths_v2_performance_intelligence_foundation.sql","20260831100518_maths_v2_performance_coach_practice.sql","20260831103315_maths_v2_timer_identity_and_weekly_coach_hardening.sql","20260831110000_maths_v2_question_fast_path_read.sql","20260831111200_maths_v2_external_reviewed_canonical_ingest.sql",
  "20260901143000_maths_exam_prep_foundation.sql","20260901153000_maths_exam_prep_runtime_hardening.sql","20260901172000_maths_academic_calculation_boundary.sql","20260901173000_maths_ai_calculation_sprint.sql","20260901174000_maths_all_timed_answer_secrecy.sql"
]){if(!exists(`../supabase/managed-migrations/${file}`))failures.push(`Maths migration mirror missing: ${file}`);}
const external=read("../supabase/managed-migrations/20260831111200_maths_v2_external_reviewed_canonical_ingest.sql");for(const marker of ["maths_create_canonical_from_external_stage","review_created_canonical","external_review_confirmed","EXT_"])has("External canonical review",external,marker);

if(failures.length){console.error("Maths coach contract validation FAILED\n- "+failures.join("\n- "));process.exit(1)}
console.log("Maths coach contract validation PASS");
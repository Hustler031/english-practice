import fs from "node:fs";

const read=p=>fs.readFileSync(p,"utf8");
const rpc=read("lib/gk-rpc.ts");
const fresh=read("lib/gk-session-freshness.ts");
const quiz=read("app/gk/quiz/page.tsx");
const intel=read("app/gk/intelligence/page.tsx");
const teacher=read("app/gk/teacher/page.tsx");
const sprint=read("app/gk/sprint/page.tsx");
const layout=read("app/gk/layout.tsx");
const lively=read("app/gk/gk-lively-polish.css");
const explain=read("app/gk/gk-lively-quiz.module.css");
const failures=[];
const has=(label,text,needle)=>{if(!text.includes(needle))failures.push(`${label}: missing ${needle}`)};
const lacks=(label,text,needle)=>{if(text.includes(needle))failures.push(`${label}: must not contain ${needle}`)};

has("RPC cache policy",rpc,'LIVE_SESSION_READ=/(?:_batch|_session)$/');
has("RPC cache policy",rpc,'n.startsWith("gk_get_")&&!LIVE_SESSION_READ.test(n)');
has("Fresh sessions",fresh,'fresh-session-history:v2');
has("Fresh sessions",fresh,'supabaseBrowser().auth.getSession()');
has("Fresh sessions",fresh,'`${ROOT}:${uid}`');
has("Fresh sessions",fresh,'MAX_RECENT_SESSIONS=6');
has("Fresh sessions",fresh,'strictMode');
has("Fresh sessions",fresh,'loadFreshGkQuestions');
has("Fresh sessions",fresh,'n+excluded.length');
lacks("Fresh sessions",fresh,'localStorage.getItem(KEY)');

for(const rpcName of ["gk_get_batch","gk_get_scope_batch","gk_get_concept_batch","gk_get_teacher_batch"])has("Quiz fresh rotation",quiz,`\"${rpcName}\"`);
has("Quiz fresh rotation",quiz,'loadFreshGkQuestions');
has("Quiz calm transition",quiz,'gk-lively-quiz.module.css');
has("Quiz calm transition",quiz,'stageSettling');
has("Quiz explanation",quiz,'FeedbackSection title="Explanation"');
has("Quiz explanation",quiz,'FeedbackSection title="Related Facts"');
has("Quiz explanation",quiz,'FeedbackSection title="Exam Trap"');
has("Quiz explanation",quiz,'FeedbackSection title="Memory / Trick"');
has("Quiz explanation CSS",explain,'transition:opacity .11s ease');
lacks("Quiz explanation CSS",explain,'transform:translate');
has("Quiz reduced motion",explain,'prefers-reduced-motion:reduce');

has("Intelligence SWR",intel,'subscribeGkFresh<Dashboard>');
has("Intelligence navigation",intel,'<a href={`/gk/intelligence?subject=${encodeURIComponent(worst.subject)}`}');
has("Teacher SWR",teacher,'subscribeGkFresh<Library>');
has("Teacher navigation",teacher,'<a className="gk-intel-card gk-teacher-series"');
has("Sprint SWR",sprint,'subscribeGkFresh<Plan>');
has("Sprint pause",sprint,'pausedTotalMs');
has("Sprint pause",sprint,'function pauseExam()');
has("Sprint resume",sprint,'function resumeExam()');
has("Sprint persistence",sprint,'section-sprint:v2');
has("Sprint teacher source",sprint,'teacherSeries:"TEACHER_TOPIC_PYQ"');

has("Lively stylesheet",layout,'./gk-lively-polish.css');
for(const token of ['var(--card)','var(--text)','var(--muted)','var(--line)','var(--primary)','var(--ok)','var(--bad)','var(--warn)'])has("Theme-safe lively CSS",lively,token);
has("Light mode",lively,'[data-theme="light"]');
lacks("Theme-safe lively CSS",lively,'var(--panel,#151b24)');

if(failures.length){console.error("GK lively/cache/freshness contracts FAILED\n- "+failures.join("\n- "));process.exit(1)}
console.log("GK lively/cache/freshness contracts PASS");

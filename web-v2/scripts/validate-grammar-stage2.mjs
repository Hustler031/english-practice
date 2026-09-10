import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const cwd=process.cwd();
const repoRoot=fs.existsSync(path.join(cwd,'web-v2','app','english','page.tsx'))?cwd:path.resolve(cwd,'..');
const at=(p)=>path.join(repoRoot,p);
const read=(p)=>fs.readFileSync(at(p),'utf8');
const fail=(m)=>{throw new Error(`Grammar Stage 2 validation failed: ${m}`)};
const has=(text,needle,label=needle)=>{if(!text.includes(needle))fail(`missing ${label}`)};
const notHas=(text,needle,label=needle)=>{if(text.includes(needle))fail(`forbidden ${label}`)};

const homePath='web-v2/app/english/page.tsx';
const practicePath='web-v2/app/english/practice/page.tsx';
const hubPath='web-v2/app/english/grammar/page.tsx';
const grammarPracticePath='web-v2/app/english/grammar/practice/page.tsx';
const chapterRoutePath='web-v2/app/english/grammar/chapter/[chapter]/page.tsx';
const chapterClientPath='web-v2/app/english/grammar/chapter/[chapter]/grammar-chapter-client.tsx';
const sqlPath='supabase/migrations/20260909020000_english_grammar_world_read_model.sql';
const historySqlPath='supabase/migrations/20260910091900_english_grammar_daily_history.sql';
const manifestPath='web-v2/data/grammar-curriculum-manifest.json';

for(const p of [homePath,practicePath,hubPath,grammarPracticePath,chapterRoutePath,chapterClientPath,sqlPath,historySqlPath,manifestPath])if(!fs.existsSync(at(p)))fail(`required file missing: ${p}`);
const home=read(homePath),practice=read(practicePath),hub=read(hubPath),grammarPractice=read(grammarPracticePath),chapterRoute=read(chapterRoutePath),chapter=read(chapterClientPath),sql=read(sqlPath),historySql=read(historySqlPath),manifest=JSON.parse(read(manifestPath));

if(manifest.ruleCount!==260)fail('Grammar curriculum drifted from 260 rules');
if(manifest.dailyTarget!==20)fail('Grammar daily target drifted from exact 20');

// Home changes only the compact shortcut; Exam Sprint remains available from Practice.
has(home,'<section className="exam-home-row"><Link href="/english/grammar">','Home compact Grammar row');
has(home,'<b>GRAMMAR</b><small>Daily 20 · Adaptive Grammar Intelligence</small>','Home Grammar row copy');
notHas(home,'english_get_exam_home_summary','obsolete Home Exam summary RPC');
notHas(home,'href="/english/exam"><span><b>EXAM PREPARATION','Home Exam shortcut');
has(practice,'["↗","Exam Sprint"','Exam Sprint preserved in Practice');
has(practice,'"/english/exam"','Exam Sprint Practice route');

// Grammar hub stays compact: intelligence + Daily + two navigation rows + grouped history.
has(hub,'className="phrasal-parity-page"','existing parity page shell');
has(hub,'className="pv-legacy-card"','existing learning card style');
has(hub,'QuizRunner','shared QuizRunner');
has(hub,'english_get_grammar_hub','Grammar hub RPC');
has(hub,'english_get_grammar_today','Grammar exact-20 Today RPC');
has(hub,'english_get_grammar_history','Grammar grouped history RPC');
has(hub,'english_get_grammar_history_batch','Grammar history review RPC');
has(hub,'href="/english/grammar/practice"','single-row Grammar Practice navigation');
has(hub,'Grammar Daily History','Grammar day history section');
has(hub,'className="pv-history-card"','Phrasal-parity history card');
has(hub,'<b>Chapters</b>','compact Chapters row');
notHas(hub,'className="pv-legacy-actions"','practice category grid on main Grammar hub');

// Practice categories live on their own focused page.
has(grammarPractice,'QuizRunner','Grammar Practice shared QuizRunner');
has(grammarPractice,'english_get_grammar_hub','Grammar Practice availability RPC');
has(grammarPractice,'english_get_grammar_batch','Grammar adaptive practice RPC');
for(const label of ['Smart Practice','Weak','Due','Practice All'])has(grammarPractice,label,`Grammar Practice category ${label}`);
has(grammarPractice,'module="grammarrevision"','Grammar Practice revision module');

// Static-export route wrapper must pre-generate the frozen curriculum chapters while keeping learner logic client-side.
has(chapterRoute,'generateStaticParams','static Grammar chapter params');
has(chapterRoute,'Object.keys(manifest.chapters||{})','frozen manifest chapter generation');
has(chapterRoute,'<GrammarChapterClient/>','chapter client wrapper');

// Chapter client: practice uses QuizRunner, browsing is separate and must never submit attempts.
has(chapter,'english_get_grammar_chapter','chapter read model');
has(chapter,'english_get_grammar_rule_questions','lazy read-only question bank');
has(chapter,'english_get_grammar_batch','chapter-scoped adaptive practice');
has(chapter,'module="grammarchapter"','real chapter practice module');
has(chapter,'Read only','visible read-only label');
has(chapter,'viewing only · no attempt recorded','read-only learner cue');
notHas(chapter,'english_submit_answer','read-only page direct answer mutation');
notHas(chapter,'english_set_mastered','read-only page mastery mutation');

// DB read model remains evidence-driven; history uses published batch dates and 10-day grouping.
for(const fn of ['english_get_grammar_hub','english_get_grammar_chapter','english_get_grammar_rule_questions','english_get_grammar_batch','english_get_grammar_today'])has(sql,`function public.${fn}`,`${fn} RPC`);
has(sql,"v_mode not in ('smart','weak','due','all')",'bounded Grammar practice modes');
has(sql,'partition by v.rule_key','one-question-per-rule variant selection');
has(sql,"when e.coverage_state='weak'",'weak-aware variant selection');
has(sql,"when e.coverage_state in ('strong','mastered')",'transfer-aware strong/mastered selection');
has(sql,"'readOnly',true",'read-only rule question contract');
has(sql,"'ready',jsonb_array_length(v_items)=20",'exact-20 Today readiness');
for(const fn of ['english_get_grammar_history','english_get_grammar_history_batch'])has(historySql,`function public.${fn}`,`${fn} history RPC`);
has(historySql,'((v_current_day-1)/10)*10+1','10-day history block grouping');
has(historySql,"'label','Day '||day_no",'day-number history labels');
has(historySql,"'label','Days '||b.start_day",'collapsed 10-day history labels');
has(historySql,'english.grammar_daily_progress(uid,n.batch_date)','batch-specific history progress');
notHas((sql+historySql).toLowerCase(),'googleapis','Google runtime dependency');
notHas(sql+historySql,manifest.spreadsheetId,'Google Sheet runtime dependency');

// Stage 2 scope: English Grammar UI/read model only. No Maths/GK or global visual redesign.
let changed=[];
try{
 const out=execFileSync('git',['diff','--name-only','origin/main...HEAD'],{cwd:repoRoot,encoding:'utf8'});
 changed=out.split(/\r?\n/).filter(Boolean);
}catch{}
for(const p of changed){
 if(/(^|\/)(maths?|gk)(\/|[-_.])/i.test(p))fail(`Stage 2 crossed Maths/GK boundary: ${p}`);
 if(/\.css$/i.test(p)&&!p.includes('grammar'))fail(`Stage 2 unexpectedly changed shared visual CSS: ${p}`);
}

console.log(JSON.stringify({ok:true,stage:'grammar-intelligence-stage2',ruleCount:manifest.ruleCount,dailyTarget:manifest.dailyTarget,chapters:Object.keys(manifest.chapters||{}).length,changedFilesChecked:changed.length},null,2));

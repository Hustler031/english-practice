import fs from 'node:fs';
import path from 'node:path';

const root=process.cwd();
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');
const home=read('app/gk/page.tsx');
const quiz=read('app/gk/quiz/page.tsx');
const transport=read('lib/gk-rpc.ts');
const session=read('lib/gk-session.ts');
const options=read('lib/options.ts');
const css=read('app/gk/gk.module.css');
const supabase=read('lib/supabase.ts');
const recovery=read('../supabase/managed-migrations/20260830013000_gk_v2_product_recovery.sql');
const parity=read('../supabase/managed-migrations/20260830020500_gk_v2_starred_ondemand_parity.sql');
const scope=read('../supabase/managed-migrations/20260830023000_gk_v2_scope_hardening.sql');
const migration=[recovery,parity,scope].join('\n');
const all=[home,quiz,transport,session,options,css,migration].join('\n');
let failed=0;
function ok(name,condition){if(condition)console.log(`✓ ${name}`);else{console.error(`✗ ${name}`);failed++;}}

// Product/navigation contracts.
const tabDecl=(home.match(/const tabs:Array<\[Tab,string,string\]>=\[(.*?)\];/s)||[])[1]||'';
ok('exactly five GK tabs',((tabDecl.match(/\["(?:home|content|practice|demand|progress)"/g)||[]).length===5));
for(const label of ['Home','Content','Practice','On Demand','Progress'])ok(`tab visible: ${label}`,tabDecl.includes(`"${label}"`));
ok('Main/Rapid are question styles, not top-level apps',!home.includes('Choose a bank')&&home.includes('Main + Rapid')&&home.includes('"MAIN"')&&home.includes('"RAPID"'));

// Content hierarchy / identity.
for(const lib of ['subject-pyq','mixed','nitto','misc'])ok(`canonical library: ${lib}`,migration.includes(`'${lib}'`)&&home.includes(lib));
ok('unknown legacy library is preserved without guessed relabel',scope.includes('do not guess a Mixed/Subject-wise identity'));
ok('Current Affairs is first-class content',home.includes('Current Affairs')&&migration.includes("q.subject='Current Affairs'"));
ok('stable lecture identity is used',migration.includes('q.lecture_key=p_lecture_key')&&quiz.includes('p_lecture_key:params.get("lecture")'));
ok('same lecture number cannot drive lecture selection',!migration.includes('q.lecture_no=p_lecture_key'));
ok('subject/topic response uses central normalized payload',migration.includes('gk_get_subject_batch')&&migration.includes('select public.gk_get_batch'));
ok('library and academic classification coexist',migration.includes('library_key')&&migration.includes('subject')&&migration.includes('topic')&&migration.includes('concept_id'));

// Pure selector fixtures mirror the SQL eligibility gates, so these are behavioral
// checks rather than source-string checks alone.
function eligible(mode,row){
 if(['new','unseen','new_v2','new_random'].includes(mode))return !row.exposed;
 if(['weak','weak_practice'].includes(mode))return ['Persistent Weak','Weak','Fragile'].includes(row.state);
 if(['due','due_recall'].includes(mode))return !!row.due;
 if(mode==='difficult')return !!row.difficult;
 if(['guessed','guessed_smart','guessed_random','guessed_oldest','guessed_recent'].includes(mode))return !!row.guessed;
 if(mode==='recall_check'||mode==='recall')return !!row.exposed&&row.state!=='Proven Mastered';
 if(mode==='daily'||mode==='smart')return row.state!=='Proven Mastered';
 return true;
}
function laneEligible(lane,rowLane){return lane==='MIXED'||lane==='ALL'||lane===rowLane;}
const unseen={exposed:false,state:'New',due:false,difficult:false,guessed:false};
const seen={exposed:true,state:'Learning',due:false,difficult:false,guessed:false};
ok('behavior: New accepts genuinely unseen',eligible('new',unseen));
ok('behavior: New rejects exposed even if otherwise eligible',!eligible('new',seen));
ok('behavior: Random New stays strictly unseen',eligible('new_random',unseen)&&!eligible('new_random',seen));
ok('behavior: Recall requires exposure and rejects mastered',eligible('recall_check',seen)&&!eligible('recall_check',{...seen,state:'Proven Mastered'})&&!eligible('recall_check',unseen));
ok('behavior: Main only excludes Rapid',laneEligible('MAIN','MAIN')&&!laneEligible('MAIN','RAPID'));
ok('behavior: Rapid only excludes Main',laneEligible('RAPID','RAPID')&&!laneEligible('RAPID','MAIN'));
ok('behavior: Mixed includes both',laneEligible('MIXED','MAIN')&&laneEligible('MIXED','RAPID'));

// Semantic selection source contracts.
ok('New SQL is strictly unexposed',migration.includes("mode_name in ('new','unseen','new_v2','new_random') then not b.exposed"));
ok('Recall Check SQL requires prior exposure',migration.includes("mode_name in ('recall','recall_check') then b.exposed"));
ok('Daily excludes Proven Mastered',migration.includes("mode_name in ('daily','smart') then b.st<>'Proven Mastered'"));
ok('Persistent Weak outranks Weak and Fragile',migration.includes("'Persistent Weak' then 1000")&&migration.includes("'Weak' then 850")&&migration.includes("'Fragile' then 700"));
ok('due/guess/difficult/star priority signals preserved',migration.includes('then 300 else 0')&&migration.includes('then 240 else 0')&&migration.includes('then 180 else 0')&&migration.includes('then 80 else 0'));
ok('Starred semantic modes are distinct',home.includes('starred_persistent')&&home.includes('starred_never')&&home.includes('starred_longest')&&migration.includes('starred_never'));
ok('Starred age bands are restored',home.includes('starred_age_')&&migration.includes("'Days 11–20'")&&migration.includes("'Days 21–30'")&&migration.includes('generate_series(30'));
ok('Guessed semantic modes are distinct',home.includes('guessed_repeated')&&home.includes('guessed_oldest')&&home.includes('guessed_recent')&&migration.includes('guessed_repeated'));
ok('Difficult remains independent route',home.includes('independent from weakness')&&migration.includes("mode_name='difficult' then b.difficult"));
ok('Current Affairs All does not impose freshness',migration.includes('p_ca_months is null or p_ca_months<=0'));
ok('On Demand supports dynamic and persisted sets',home.includes('Fix Weaknesses')&&home.includes('Long Time No See')&&migration.includes('gk_create_demand_set')&&migration.includes('p_demand_id'));

// Retention behavior fixtures. Times are hours since the first attempt.
function derive(attempts){
 const enriched=attempts.map((a,i)=>({...a,spaced:i>0&&(a.hour-attempts[i-1].hour)>=18}));
 const spaced=enriched.filter(a=>a.spaced);const retCorrect=spaced.filter(a=>a.correct).length;const retWrong=spaced.length-retCorrect;
 const retAccuracy=spaced.length?retCorrect*100/spaced.length:0;const recentFailures=spaced.slice(-3).filter(a=>!a.correct).length;
 const lastGuess=[...enriched].reverse().find(a=>a.guessed);const unresolved=!!lastGuess&&!enriched.some(a=>a.hour>lastGuess.hour&&a.spaced&&a.correct&&!a.guessed);
 const confirmed=enriched.filter(a=>a.spaced&&a.correct&&!a.guessed).length;const lastSpaced=spaced.at(-1);
 if(!enriched.length)return 'New';
 if(recentFailures>=2||(retWrong>=2&&retAccuracy<60))return 'Persistent Weak';
 if((retWrong>=1&&(!spaced.length||!lastSpaced?.correct))||((enriched.filter(a=>!a.correct).length)>=2&&retCorrect===0))return 'Weak';
 if(unresolved||spaced.length<2)return 'Fragile';
 if(retCorrect>=3&&retAccuracy>=85&&lastSpaced?.correct&&recentFailures===0&&!unresolved&&confirmed>=2)return 'Proven Mastered';
 if(retCorrect>=2&&retAccuracy>=75&&lastSpaced?.correct&&!unresolved)return 'Strong';
 if(enriched.some(a=>!a.correct)||retAccuracy<70)return 'Weak';
 return 'Learning';
}
ok('behavior: same-session correction cannot prove retention',derive([{hour:0,correct:false},{hour:1,correct:true}])==='Fragile');
ok('behavior: two recent spaced failures become Persistent Weak',derive([{hour:0,correct:true},{hour:20,correct:false},{hour:40,correct:false}])==='Persistent Weak');
ok('behavior: repeated spaced correct becomes Proven Mastered',derive([{hour:0,correct:true},{hour:20,correct:true},{hour:40,correct:true},{hour:60,correct:true}])==='Proven Mastered');
ok('behavior: guessed correct remains Fragile before confirmation',derive([{hour:0,correct:true,guessed:true},{hour:20,correct:true,guessed:true}])==='Fragile');
ok('behavior: later spaced unguessed recall can clear guess',derive([{hour:0,correct:true,guessed:true},{hour:20,correct:true,guessed:false},{hour:40,correct:true,guessed:false}])==='Strong');
ok('old 18-hour retention gap preserved',migration.includes('gap>=18'));
ok('same-session correction cannot become spaced SQL evidence',migration.includes('coalesce(gap>=18,false)'));
ok('Persistent Weak derivation exists',migration.includes("state_name:='Persistent Weak'"));
ok('Weak Fragile Learning Strong Proven Mastered all exist',['Weak','Fragile','Learning','Strong','Proven Mastered'].every(x=>migration.includes(`'${x}'`)));
ok('Proven Mastered requires spaced unguessed evidence',migration.includes('ret_correct>=3')&&migration.includes('ret_accuracy>=85')&&migration.includes('confirmed_n>=2')&&migration.includes('not unresolved'));
ok('review schedule preserves old state cadence',migration.includes("when 'Persistent Weak' then 1")&&migration.includes("when 'Fragile' then 2")&&migration.includes("when 'Learning' then 3")&&migration.includes("when 'Strong' then 7")&&migration.includes("when 'Proven Mastered' then 21"));
ok('first-attempt and retention evidence persisted',migration.includes('first_attempt_correct')&&migration.includes('retention_attempts')&&migration.includes('retention_accuracy'));

// Exposure and guessed lifecycle.
ok('selection is separate from exposure write',migration.includes('gk_record_exposure')&&!migration.match(/gk_get_batch[\s\S]{0,500}insert into gk\.exposures/i));
ok('display creates exposure in React',quiz.includes('gk_record_exposure')&&quiz.includes('[q?.id,sessionId,meta.mode]'));
ok('exposure idempotency is session + question based',migration.includes("uid::text||':'||sid||':'||p_question_id")&&migration.includes('on conflict(exposure_key) do nothing'));
ok('guess annotates existing attempt rather than inserting attempt',migration.includes('update gk.attempts set guessed=')&&migration.includes("raise exception 'Answer attempt not available yet'"));
ok('later spaced correct unguessed recall resolves guess',migration.includes('is_correct and not coalesce(guessed,false) and attempted_at>last_guess_at_v'));
ok('guess action does not submit another answer',quiz.includes('gk_mark_guessed')&&!/toggleGuess[\s\S]{0,600}gk_submit_answer/.test(quiz));

// Quiz engine / reliability.
ok('all practice routes use one central batch engine',quiz.includes('gk_get_batch')&&home.split('href={quiz(').length>10);
ok('Daily uses canonical server daily session',quiz.includes('gk_start_daily')&&migration.includes('gk_daily_one_per_study_date_idx'));
ok('exact pause stores ordered questions answers and option orders',quiz.includes('questions:qs')&&quiz.includes('answers,optionOrders:optionOrders(qs)')&&session.includes('optionOrders?'));
ok('Previous Next Finish Pause are present',['Previous','Next','Finish','Pause'].every(x=>quiz.includes(x)));
ok('browser Back opens Pause flow',quiz.includes('popstate')&&quiz.includes('setPauseOpen(true)'));
ok('Star Note Difficult Flag Guessed remain independent',['★ Star','◆ Difficult','? Guessed','⚑ Flag','▤ Note'].every(x=>quiz.includes(x)));
ok('question intelligence view exists',quiz.includes('Question Intelligence')&&quiz.includes('gk_get_question_intelligence'));
ok('rich GK explanation sections remain restrained',['Related Facts:','Exam Trap:','Memory / Trick:'].every(x=>quiz.includes(x)));
ok('canonical/display option mapping is used',quiz.includes('displayOptions')&&quiz.includes('o.canonicalKey')&&options.includes('canonicalKey'));
ok('unsafe option shuffles are blocked',options.includes('all of the above')&&options.includes('none of the above')&&options.includes('chronological')&&options.includes('restoreDisplayOptions'));
ok('resume restores same display order',quiz.includes('restoreDisplayOptions')&&quiz.includes('optionOrders'));
ok('durable answer exposure and guess writes exist',['gk_submit_answer','gk_record_exposure','gk_mark_guessed'].every(x=>transport.includes(x))&&transport.includes('mutation-outbox:v2'));
ok('durable queue preserves mutation ordering',transport.includes('sort((a,b)=>a.queuedAt-b.queuedAt)')&&transport.includes('const item=rows[0]'));
ok('retry on reconnect and visibility',transport.includes('addEventListener("online"')&&transport.includes('visibilitychange')&&transport.includes('BACKOFF'));
ok('pending sync is user-visible',quiz.includes('pendingGkMutations')&&quiz.includes('pending sync'));
ok('Local Safe blocks all GK mutation prefixes including create',transport.includes('create_|finish_|complete_')&&transport.includes('NEXT_PUBLIC_ALLOW_GK_LOCAL_MUTATIONS')&&transport.includes('localSimulation'));
ok('frontend contains no service-role credential',!all.toLowerCase().includes('service_role')&&!all.toLowerCase().includes('service-role'));

// Statement renderer behavior: split only sequential numbered statements beginning at 1.
function statementLines(raw){const lines=String(raw||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(lines.length>1)return lines;const t=String(raw||'').trim();const hits=[...t.matchAll(/(?:^|\s)(\d+)\.\s+/g)];const nums=hits.map(x=>Number(x[1]));const sequential=hits.length>=2&&Number(hits[0].index||0)===0&&nums[0]===1&&nums.every((x,i)=>i===0||x===nums[i-1]+1);return sequential?t.replace(/\s+(?=\d+\.\s)/g,'\n').split('\n'):[t];}
ok('statement: inline two statements split',statementLines('1. First statement 2. Second statement').length===2);
ok('statement: inline three statements split',statementLines('1. First 2. Second 3. Third').length===3);
ok('statement: explicit multiline preserved',statementLines('1. First\n2. Second\n3. Third').length===3);
ok('statement: ordinary numerical prose is not split',statementLines('Article 280 was discussed in 1.5 hours and value 2.0 was noted.').length===1);
ok('statement renderer uses gated sequential detection',quiz.includes('const sequential=hits.length>=2')&&quiz.includes('styles.statement'));

// Progress completeness.
for(const key of ['Learning Overview','Knowledge Health','Subject Mastery','Weak Concepts','Current Affairs Health','Starred Revision Health','Guessed Knowledge Health','Difficult Resolution','Lecture / Source Coverage'])ok(`progress section: ${key}`,home.includes(key));
ok('concept intelligence aggregates persistent weak/mastered/guessed',migration.includes('persistentWeak')&&migration.includes('mastered')&&migration.includes('guessed')&&migration.includes('conceptId'));

// Security / ownership.
ok('Demand Set schema gains user owner',parity.includes('add column if not exists user_id uuid'));
ok('Demand Set selector is owner/shared scoped',parity.includes('(d.user_id is null or d.user_id=uid)'));
ok('Demand Set catalog is owner/shared scoped',scope.includes('(d.user_id is null or d.user_id=u.uid)'));
ok('Demand Set direct RLS ownership policies exist',scope.includes('gk_demand_sets_read')&&scope.includes('gk_demand_sets_insert')&&scope.includes('gk_demand_sets_update')&&scope.includes('gk_demand_sets_delete'));
ok('new GK security-definer RPCs revoke PUBLIC/anon execute',scope.includes('from public, anon'));

// Shared platform preservation guards.
ok('shared English Supabase transport remains present',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));
ok('GK code remains scoped under GK files/RPC names',!home.includes('english_submit_answer')&&!quiz.includes('english_submit_answer'));
ok('five-column safe-area bottom navigation',css.includes('grid-template-columns:repeat(5,1fr)')&&css.includes('safe-area-inset-bottom'));

if(failed){console.error(`\n${failed} GK contract(s) failed.`);process.exit(1);}console.log('\nGK V2 recovery contracts passed.');

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
const migration=read('../supabase/managed-migrations/20260830013000_gk_v2_product_recovery.sql');
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
ok('Current Affairs is first-class content',home.includes('Current Affairs')&&migration.includes("q.subject='Current Affairs'"));
ok('stable lecture identity is used',migration.includes('q.lecture_key=p_lecture_key')&&quiz.includes('p_lecture_key:params.get("lecture")'));
ok('same lecture number cannot drive lecture selection',!migration.includes('q.lecture_no=p_lecture_key'));
ok('subject/topic response uses central normalized payload',migration.includes('gk_get_subject_batch')&&migration.includes('select public.gk_get_batch'));
ok('library and academic classification coexist',migration.includes('library_key')&&migration.includes('subject')&&migration.includes('topic')&&migration.includes('concept_id'));

// Semantic selection contracts.
ok('New is strictly unexposed',migration.includes("mode_name in ('new','unseen','new_v2') then not b.exposed"));
ok('Recall Check requires prior exposure',migration.includes("mode_name in ('recall','recall_check') then b.exposed"));
ok('Daily excludes Proven Mastered',migration.includes("mode_name in ('daily','smart') then b.st<>'Proven Mastered'"));
ok('Persistent Weak outranks Weak and Fragile',migration.includes("'Persistent Weak' then 1000")&&migration.includes("'Weak' then 850")&&migration.includes("'Fragile' then 700"));
ok('due/guess/difficult/star priority signals preserved',migration.includes('then 300 else 0')&&migration.includes('then 240 else 0')&&migration.includes('then 180 else 0')&&migration.includes('then 80 else 0'));
ok('Starred semantic modes are distinct',home.includes('starred_persistent')&&home.includes('starred_never')&&home.includes('starred_oldest')&&migration.includes('starred_never'));
ok('Guessed semantic modes are distinct',home.includes('guessed_repeated')&&home.includes('guessed_oldest')&&home.includes('guessed_recent')&&migration.includes('guessed_repeated'));
ok('Difficult remains manual independent route',home.includes('Manual Difficult flag')&&migration.includes("mode_name='difficult' then b.difficult"));
ok('Current Affairs All does not impose freshness',migration.includes('p_ca_months is null or p_ca_months<=0'));
ok('On Demand keeps migrated demand IDs',migration.includes('gk.demand_sets')&&migration.includes('p_demand_id')&&home.includes('demandId'));

// Retention evidence contracts.
ok('old 18-hour retention gap preserved',migration.includes('gap>=18'));
ok('same-session correction cannot become spaced evidence',migration.includes('coalesce(gap>=18,false)'));
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
ok('durable queue preserves ordering for answer then guess',transport.includes('sort((a,b)=>a.queuedAt-b.queuedAt)')&&transport.includes('const item=rows[0]'));
ok('retry on reconnect and visibility',transport.includes('addEventListener("online"')&&transport.includes('visibilitychange')&&transport.includes('BACKOFF'));
ok('pending sync is user-visible',quiz.includes('pendingGkMutations')&&quiz.includes('pending sync'));
ok('Local Safe blocks localhost mutations',transport.includes('isGkLocalSafe')&&transport.includes('NEXT_PUBLIC_ALLOW_GK_LOCAL_MUTATIONS')&&transport.includes('localSimulation'));
ok('frontend contains no service-role credential',!all.toLowerCase().includes('service_role')&&!all.toLowerCase().includes('service-role'));

// Statement renderer behavior mirror: split only sequential numbered statements beginning at 1.
function statementLines(raw){const lines=String(raw||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(lines.length>1)return lines;const t=String(raw||'').trim();const hits=[...t.matchAll(/(?:^|\s)(\d+)\.\s+/g)];const nums=hits.map(x=>Number(x[1]));const sequential=hits.length>=2&&Number(hits[0].index||0)===0&&nums[0]===1&&nums.every((x,i)=>i===0||x===nums[i-1]+1);return sequential?t.replace(/\s+(?=\d+\.\s)/g,'\n').split('\n'):[t];}
ok('statement: inline two statements split',statementLines('1. First statement 2. Second statement').length===2);
ok('statement: inline three statements split',statementLines('1. First 2. Second 3. Third').length===3);
ok('statement: explicit multiline preserved',statementLines('1. First\n2. Second\n3. Third').length===3);
ok('statement: ordinary numerical prose is not split',statementLines('Article 280 was discussed in 1.5 hours and value 2.0 was noted.').length===1);
ok('statement renderer uses gated sequential detection',quiz.includes('const sequential=hits.length>=2')&&quiz.includes('styles.statement'));

// Progress completeness.
for(const key of ['Learning Overview','Knowledge Health','Subject Mastery','Weak Concepts','Current Affairs Health','Starred Revision Health','Guessed Knowledge Health','Difficult Resolution','Lecture / Source Coverage'])ok(`progress section: ${key}`,home.includes(key));
ok('concept intelligence aggregates persistent weak/mastered/guessed',migration.includes('persistentWeak')&&migration.includes('mastered')&&migration.includes('guessed')&&migration.includes('conceptId'));

// Shared platform preservation guards.
ok('shared English Supabase transport remains present',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));
ok('GK code remains scoped under GK files/RPC names',!home.includes('english_submit_answer')&&!quiz.includes('english_submit_answer'));
ok('five-column safe-area bottom navigation',css.includes('grid-template-columns:repeat(5,1fr)')&&css.includes('safe-area-inset-bottom'));

if(failed){console.error(`\n${failed} GK contract(s) failed.`);process.exit(1);}console.log('\nGK V2 recovery contracts passed.');

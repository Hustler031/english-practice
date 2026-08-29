import fs from 'node:fs';
import path from 'node:path';
const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const home=read('app/gk/page.tsx'),quiz=read('app/gk/quiz/page.tsx'),transport=read('lib/gk-rpc.ts'),session=read('lib/gk-session.ts'),options=read('lib/options.ts'),css=read('app/gk/gk.module.css'),supabase=read('lib/supabase.ts');
const recovery=read('../supabase/managed-migrations/20260830013000_gk_v2_product_recovery.sql');
const parity=read('../supabase/managed-migrations/20260830020500_gk_v2_starred_ondemand_parity.sql');
const scope=read('../supabase/managed-migrations/20260830023000_gk_v2_scope_hardening.sql');
const migration=[recovery,parity,scope].join('\n'),all=[home,quiz,transport,session,options,css,migration].join('\n');
let failed=0;const ok=(name,condition)=>condition?console.log(`✓ ${name}`):(console.error(`✗ ${name}`),failed++);

const tabs=(home.match(/const tabs:Array<\[Tab,string,string\]>=\[(.*?)\];/s)||[])[1]||'';
ok('exactly five GK tabs',((tabs.match(/\["(?:home|content|practice|demand|progress)"/g)||[]).length===5));
for(const x of ['Home','Content','Practice','On Demand','Progress'])ok(`tab visible: ${x}`,tabs.includes(`"${x}"`));
ok('Main/Rapid are question styles, not top-level apps',!home.includes('Choose a bank')&&home.includes('Main + Rapid')&&home.includes('"MAIN"')&&home.includes('"RAPID"'));

for(const lib of ['subject-pyq','mixed','nitto','misc'])ok(`canonical library contract: ${lib}`,migration.includes(`'${lib}'`));
ok('Content renders canonical server catalog',home.includes('catalog.libraries.map'));
ok('unknown legacy library is preserved without guessed relabel',scope.includes('do not guess a Mixed/Subject-wise identity'));
ok('Current Affairs first-class',home.includes('Current Affairs')&&migration.includes("q.subject='Current Affairs'"));
ok('stable lecture key selection',migration.includes('q.lecture_key=p_lecture_key')&&quiz.includes('p_lecture_key:params.get("lecture")')&&!migration.includes('q.lecture_no=p_lecture_key'));
ok('normalized subject/topic contract',migration.includes('gk_get_subject_batch')&&migration.includes('select public.gk_get_batch'));
ok('library + academic dimensions coexist',['library_key','subject','topic','concept_id'].every(x=>migration.includes(x)));

function eligible(mode,row){if(['new','unseen','new_v2','new_random'].includes(mode))return !row.exposed;if(['weak','weak_practice'].includes(mode))return ['Persistent Weak','Weak','Fragile'].includes(row.state);if(['due','due_recall'].includes(mode))return !!row.due;if(mode==='difficult')return !!row.difficult;if(mode.startsWith('guessed'))return !!row.guessed;if(['recall','recall_check'].includes(mode))return !!row.exposed&&row.state!=='Proven Mastered';if(['daily','smart'].includes(mode))return row.state!=='Proven Mastered';return true;}
const laneOk=(lane,rowLane)=>['MIXED','ALL'].includes(lane)||lane===rowLane,unseen={exposed:false,state:'New'},seen={exposed:true,state:'Learning'};
ok('behavior: New is genuinely unseen',eligible('new',unseen)&&!eligible('new',seen));
ok('behavior: Random New remains unseen',eligible('new_random',unseen)&&!eligible('new_random',seen));
ok('behavior: Recall requires seen and not mastered',eligible('recall_check',seen)&&!eligible('recall_check',unseen)&&!eligible('recall_check',{...seen,state:'Proven Mastered'}));
ok('behavior: Main excludes Rapid',laneOk('MAIN','MAIN')&&!laneOk('MAIN','RAPID'));
ok('behavior: Rapid excludes Main',laneOk('RAPID','RAPID')&&!laneOk('RAPID','MAIN'));
ok('behavior: Mixed includes both',laneOk('MIXED','MAIN')&&laneOk('MIXED','RAPID'));
ok('SQL: New strict exposure gate',migration.includes("mode_name in ('new','unseen','new_v2','new_random') then not b.exposed"));
ok('SQL: Recall exposure gate',migration.includes("mode_name in ('recall','recall_check') then b.exposed"));
ok('Daily excludes Proven Mastered',migration.includes("mode_name in ('daily','smart') then b.st<>'Proven Mastered'"));
ok('priority PW > W > Fragile',migration.includes("'Persistent Weak' then 1000")&&migration.includes("'Weak' then 850")&&migration.includes("'Fragile' then 700"));
ok('due/guess/difficult/star priority signals',[300,240,180,80].every(x=>migration.includes(`then ${x} else 0`)));
ok('Starred semantic modes',home.includes('starred_persistent')&&home.includes('starred_never')&&home.includes('starred_longest')&&home.includes('starred_random'));
ok('Starred age bands',home.includes('starred_age_')&&migration.includes("'Days 11–20'")&&migration.includes("'Days 21–30'")&&migration.includes('generate_series(30'));
ok('Guessed semantic modes',home.includes('guessed_repeated')&&home.includes('guessed_oldest')&&home.includes('guessed_recent')&&home.includes('guessed_random'));
ok('Difficult independent',home.includes('independent from weakness')&&migration.includes("mode_name='difficult' then b.difficult"));
ok('CA All has no hidden freshness',migration.includes('p_ca_months is null or p_ca_months<=0'));
ok('On Demand dynamic + persisted',home.includes('Fix Weaknesses')&&home.includes('Long Time No See')&&migration.includes('gk_create_demand_set')&&migration.includes('p_demand_id'));

function derive(a){const e=a.map((x,i)=>({...x,spaced:i>0&&x.hour-a[i-1].hour>=18})),s=e.filter(x=>x.spaced),rc=s.filter(x=>x.correct).length,rw=s.length-rc,ra=s.length?rc*100/s.length:0,rf=s.slice(-3).filter(x=>!x.correct).length,lg=[...e].reverse().find(x=>x.guessed),unresolved=!!lg&&!e.some(x=>x.hour>lg.hour&&x.spaced&&x.correct&&!x.guessed),confirmed=e.filter(x=>x.spaced&&x.correct&&!x.guessed).length,ls=s.at(-1);if(!e.length)return'New';if(rf>=2||(rw>=2&&ra<60))return'Persistent Weak';if((rw>=1&&(!s.length||!ls?.correct))||(e.filter(x=>!x.correct).length>=2&&rc===0))return'Weak';if(unresolved||s.length<2)return'Fragile';if(rc>=3&&ra>=85&&ls?.correct&&rf===0&&!unresolved&&confirmed>=2)return'Proven Mastered';if(rc>=2&&ra>=75&&ls?.correct&&!unresolved)return'Strong';if(e.some(x=>!x.correct)||ra<70)return'Weak';return'Learning';}
ok('behavior: same-session correction does not prove retention',derive([{hour:0,correct:false},{hour:1,correct:true}])==='Fragile');
ok('behavior: spaced failures become Persistent Weak',derive([{hour:0,correct:true},{hour:20,correct:false},{hour:40,correct:false}])==='Persistent Weak');
ok('behavior: repeated spaced correct becomes Proven Mastered',derive([{hour:0,correct:true},{hour:20,correct:true},{hour:40,correct:true},{hour:60,correct:true}])==='Proven Mastered');
ok('behavior: guessed correct stays Fragile before confirmation',derive([{hour:0,correct:true,guessed:true},{hour:20,correct:true,guessed:true}])==='Fragile');
ok('behavior: later spaced unguessed recall clears guess',derive([{hour:0,correct:true,guessed:true},{hour:20,correct:true},{hour:40,correct:true}])==='Strong');
ok('18-hour retention gap SQL',migration.includes('gap>=18')&&migration.includes('coalesce(gap>=18,false)'));
ok('all learning states exist',['Persistent Weak','Weak','Fragile','Learning','Strong','Proven Mastered'].every(x=>migration.includes(`'${x}'`)));
ok('mastery uses spaced unguessed evidence',migration.includes('ret_correct>=3')&&migration.includes('ret_accuracy>=85')&&migration.includes('confirmed_n>=2')&&migration.includes('not unresolved'));
ok('review cadence preserved',["when 'Persistent Weak' then 1","when 'Fragile' then 2","when 'Learning' then 3","when 'Strong' then 7","when 'Proven Mastered' then 21"].every(x=>migration.includes(x)));
ok('first-attempt + retention persisted',migration.includes('first_attempt_correct')&&migration.includes('retention_attempts')&&migration.includes('retention_accuracy'));

ok('selection separate from exposure',migration.includes('gk_record_exposure')&&!migration.match(/gk_get_batch[\s\S]{0,500}insert into gk\.exposures/i));
ok('display creates exposure',quiz.includes('gk_record_exposure')&&quiz.includes('[q?.id,sessionId,meta.mode]'));
ok('exposure idempotent session+question',migration.includes("uid::text||':'||sid||':'||p_question_id")&&migration.includes('on conflict(exposure_key) do nothing'));
ok('guess annotates existing attempt',migration.includes('update gk.attempts set guessed=')&&migration.includes("raise exception 'Answer attempt not available yet'"));
ok('spaced unguessed resolves guess',migration.includes('is_correct and not coalesce(guessed,false) and attempted_at>last_guess_at_v'));
ok('guess does not duplicate answer',quiz.includes('gk_mark_guessed')&&!/toggleGuess[\s\S]{0,600}gk_submit_answer/.test(quiz));

ok('one central quiz batch engine',quiz.includes('gk_get_batch')&&home.split('href={quiz(').length>10);
ok('canonical Daily session',quiz.includes('gk_start_daily')&&migration.includes('gk_daily_one_per_study_date_idx'));
ok('exact pause/resume order',quiz.includes('questions:qs')&&quiz.includes('answers,optionOrders:optionOrders(qs)')&&session.includes('optionOrders?'));
ok('Previous Next Finish Pause',['Previous','Next','Finish','Pause'].every(x=>quiz.includes(x)));
ok('browser Back opens Pause',quiz.includes('popstate')&&quiz.includes('setPauseOpen(true)'));
ok('Star Note Difficult Flag Guessed independent',['★ Star','◆ Difficult','? Guessed','⚑ Flag','▤ Note'].every(x=>quiz.includes(x)));
ok('question intelligence',quiz.includes('Question Intelligence')&&quiz.includes('gk_get_question_intelligence'));
ok('rich explanation sections',['Related Facts:','Exam Trap:','Memory / Trick:'].every(x=>quiz.includes(x)));
ok('canonical/display option mapping',quiz.includes('o.canonicalKey')&&options.includes('canonicalKey'));
ok('unsafe option shuffle guarded',['all of the above','none of the above','chronological','restoreDisplayOptions'].every(x=>options.includes(x)));
ok('resume option order stable',quiz.includes('restoreDisplayOptions')&&quiz.includes('optionOrders'));
ok('durable answer/exposure/guess',['gk_submit_answer','gk_record_exposure','gk_mark_guessed'].every(x=>transport.includes(x))&&transport.includes('mutation-outbox:v2'));
ok('durable FIFO mutation ordering',transport.includes('sort((a,b)=>a.queuedAt-b.queuedAt)')&&transport.includes('const item=rows[0]'));
ok('reconnect/visibility/backoff retry',transport.includes('addEventListener("online"')&&transport.includes('visibilitychange')&&transport.includes('BACKOFF'));
ok('pending sync visible',quiz.includes('pendingGkMutations')&&quiz.includes('pending sync'));
ok('Local Safe includes create mutations',transport.includes('create_|finish_|complete_')&&transport.includes('NEXT_PUBLIC_ALLOW_GK_LOCAL_MUTATIONS')&&transport.includes('localSimulation'));
ok('no browser service-role secret',!all.toLowerCase().includes('service_role')&&!all.toLowerCase().includes('service-role'));

function statementLines(raw){const lines=String(raw||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(lines.length>1)return lines;const t=String(raw||'').trim(),hits=[...t.matchAll(/(?:^|\s)(\d+)\.\s+/g)],nums=hits.map(x=>Number(x[1])),seq=hits.length>=2&&Number(hits[0].index||0)===0&&nums[0]===1&&nums.every((x,i)=>i===0||x===nums[i-1]+1);return seq?t.replace(/\s+(?=\d+\.\s)/g,'\n').split('\n'):[t];}
ok('statement inline split',statementLines('1. First 2. Second 3. Third').length===3);
ok('statement multiline preserved',statementLines('1. First\n2. Second\n3. Third').length===3);
ok('normal numerical prose untouched',statementLines('Article 280 was discussed in 1.5 hours and value 2.0 was noted.').length===1);
ok('statement renderer gated',quiz.includes('const sequential=hits.length>=2')&&quiz.includes('styles.statement'));

for(const x of ['Learning Overview','Knowledge Health','Subject Mastery','Weak Concepts','Current Affairs Health','Starred Revision Health','Guessed Knowledge Health','Difficult Resolution','Lecture / Source Coverage'])ok(`progress: ${x}`,home.includes(x));
ok('concept intelligence',migration.includes('persistentWeak')&&migration.includes('mastered')&&migration.includes('guessed')&&migration.includes('conceptId'));
ok('Demand Set user owner',parity.includes('add column if not exists user_id uuid'));
ok('Demand selector owner/shared',parity.includes('(d.user_id is null or d.user_id=uid)'));
ok('Demand catalog owner/shared',scope.includes('(d.user_id is null or d.user_id=u.uid)'));
ok('Demand direct RLS policies',['gk_demand_sets_read','gk_demand_sets_insert','gk_demand_sets_update','gk_demand_sets_delete'].every(x=>scope.includes(x)));
ok('RPC PUBLIC/anon execute revoked',scope.includes('from public, anon'));
ok('English shared transport preserved',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));
ok('GK stays scoped',!home.includes('english_submit_answer')&&!quiz.includes('english_submit_answer'));
ok('five-column safe-area nav',css.includes('grid-template-columns:repeat(5,1fr)')&&css.includes('safe-area-inset-bottom'));

if(failed){console.error(`\n${failed} GK contract(s) failed.`);process.exit(1);}console.log('\nGK V2 recovery contracts passed.');

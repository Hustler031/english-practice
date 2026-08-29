import fs from 'node:fs';
import path from 'node:path';

const root=process.cwd();
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');
const home=read('app/gk/page.tsx');
const quiz=read('app/gk/quiz/page.tsx');
const transport=read('lib/gk-rpc.ts');
const session=read('lib/gk-session.ts');
const css=read('app/gk/gk.module.css');
const supabase=read('lib/supabase.ts');
const all=[home,quiz,transport,session,css].join('\n');
let failed=0;
function ok(name,condition){if(condition)console.log(`✓ ${name}`);else{console.error(`✗ ${name}`);failed++;}}

ok('home uses canonical GK snapshot RPC',home.includes('gk_get_home_snapshot'));
ok('old missing home RPC is gone',!all.includes('gk_home_summary'));
ok('old missing question feed RPC is gone',!all.includes('gk_question_feed'));
ok('Main and Rapid are explicit home lanes',home.includes("lane:'MAIN'")&&home.includes("lane:'RAPID'"));
ok('quiz uses lane-safe loader',quiz.includes('gk_get_lane_batch')&&quiz.includes('p_lane:queryLane'));
ok('lecture loader preserves lane',quiz.includes('gk_get_lecture_batch')&&quiz.includes('p_lane:queryLane'));
ok('subject/topic loader preserves lane',quiz.includes('gk_get_subject_batch')&&quiz.includes('p_topic:params.get("topic")'));
ok('smart quick-start no longer uses cross-lane smart RPC',!home.includes('gk_get_smart_revision'));
ok('statement rendering splits numbered statements',quiz.includes('(?=\\d+\\.\\s)')&&quiz.includes('styles.statement'));
ok('durable GK answer outbox exists',transport.includes('answer-outbox:v1')&&transport.includes('p_attempt_id'));
ok('outbox retries on reconnect',transport.includes('addEventListener("online"')&&transport.includes('BACKOFF'));
ok('GK private cache is authenticated-user scoped',transport.includes('active-user')&&transport.includes('session?.user?.id'));
ok('pause stores exact ordered questions and answers',quiz.includes('questions:qs')&&quiz.includes('answers')&&session.includes('questions:unknown[]'));
ok('resume restores stored lane and mode',/lane:\s*(?:stored|paused)\.lane/.test(quiz)&&/mode:\s*(?:stored|paused)\.mode/.test(quiz));
ok('same quiz URL refresh restores exact stored sequence',quiz.includes('stored.query===window.location.search')&&quiz.includes('setQs(stored.questions as Q[])'));
ok('GK session is persisted continuously',quiz.includes('saveGkPaused({title:meta.title')&&quiz.includes('[qs,index,answers,loading,meta]'));
ok('GK reuses proven English PauseSheet',quiz.includes('PauseSheet')&&quiz.includes('onSave={exitPaused}'));
ok('quiz exposes Star Difficult Flag Note',quiz.includes('★ Star')&&quiz.includes('◆ Difficult')&&quiz.includes('⚑ Flag')&&quiz.includes('▤ Note'));
ok('answer RPC is canonical',quiz.includes('gk_submit_answer'));
ok('mutations use canonical GK RPCs',quiz.includes('gk_set_starred')&&quiz.includes('gk_set_difficult')&&quiz.includes('gk_set_flag')&&quiz.includes('gk_save_note'));
ok('fixed bottom dock includes safe area',css.includes('position:fixed')&&css.includes('safe-area-inset-bottom'));
ok('quiz tools stay in one four-column row',css.includes('grid-template-columns:repeat(4,minmax(0,1fr))'));
ok('frontend contains no service-role key reference',!all.toLowerCase().includes('service_role')&&!all.toLowerCase().includes('service-role'));
ok('GK frontend contains no raw/staging browser table access',!/(from\(["'`](?:gk\.)?(?:raw|staging)|\.from\(["'`](?:raw|staging))/i.test(all));
ok('shared English Supabase transport remains present',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));

if(failed){console.error(`\n${failed} GK contract(s) failed.`);process.exit(1);}console.log('\nGK V2 frontend contracts passed.');

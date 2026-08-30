import fs from 'node:fs';
import path from 'node:path';

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const home=read('app/gk/page.tsx');
const quiz=read('app/gk/quiz/page.tsx');
const transport=read('lib/gk-rpc.ts');
const session=read('lib/gk-session.ts');
const options=read('lib/options.ts');
const css=read('app/gk/gk.module.css');
const supabase=read('lib/supabase.ts');
const migration=read('../supabase/managed-migrations/20260830025704_gk_v2_local_safe_read_surface.sql');
const all=[home,quiz,transport,session,options,css,migration].join('\n');

let failed=0;
const ok=(name,condition)=>condition?console.log(`✓ ${name}`):(console.error(`✗ ${name}`),failed++);

const tabs=(home.match(/const tabs:Array<\[Tab,string,string\]>=\[(.*?)\];/s)||[])[1]||'';
ok('exactly five GK tabs',((tabs.match(/\["(?:home|content|practice|demand|progress)"/g)||[]).length===5));
for(const x of ['Home','Content','Practice','On Demand','Progress'])ok(`tab visible: ${x}`,tabs.includes(`"${x}"`));
ok('Main/Rapid are question styles',home.includes('Main + Rapid')&&home.includes('"MAIN"')&&home.includes('"RAPID"'));

for(const lib of ['subject-pyq','mixed','nitto','misc'])ok(`canonical library contract: ${lib}`,migration.includes(`'${lib}'`));
ok('library identity is derived read-only',migration.includes('gk.derive_library_key')&&!migration.includes('alter table gk.questions'));
ok('stable lecture key selection',migration.includes('q.lecture_key=p_lecture_key')&&quiz.includes('p_lecture_key:')&&quiz.includes('get("lecture")'));
ok('library + academic dimensions coexist',['subject','topic','concept_id','library_key'].every(x=>migration.includes(x)));
ok('Current Affairs first-class',home.includes('Current Affairs')&&migration.includes("q.subject='Current Affairs'"));

const requiredReads=[
 'gk_get_batch','gk_get_catalog','gk_get_concept_catalog','gk_get_concept_batch',
 'gk_get_home_snapshot','gk_get_starred_hub','gk_get_on_demand_hub',
 'gk_get_progress','gk_get_question_intelligence'
];
for(const fn of requiredReads)ok(`read RPC present: ${fn}`,migration.includes(`function public.${fn}`));

ok('migration performs no table mutation',!/\balter\s+table\b|\binsert\s+into\b|\bupdate\s+gk\.|\bdelete\s+from\b|\btruncate\b|\bdo\s+\$\$/i.test(migration));
ok('selector is VOLATILE for random modes',/function public\.gk_get_batch[\s\S]*?language plpgsql\s+volatile security definer/i.test(migration));
ok('New uses true exposure evidence',migration.includes("mode_name in ('new','unseen','new_v2','new_random') then not b.exposed"));
ok('Recall requires exposure',migration.includes("mode_name in ('recall','recall_check') then b.exposed"));
ok('Daily/Smart excludes Proven Mastered',migration.includes("mode_name in ('daily','smart') then b.st<>'Proven Mastered'"));
ok('Persistent Weak priority dominates',migration.includes("'Persistent Weak' then 1000")&&migration.includes("'Weak' then 850")&&migration.includes("'Fragile' then 700"));
ok('due/guess/difficult/star priority signals',[300,240,180,80].every(x=>migration.includes(`then ${x} else 0`)));
ok('Long Time No See rotates oldest exposure',migration.includes("mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen_evidence,to_timestamp(0)))"));
ok('Starred semantic modes',home.includes('starred_persistent')&&home.includes('starred_never')&&home.includes('starred_longest')&&home.includes('starred_random'));
ok('legacy Starred Earlier mode',home.includes('"starred_earlier"')&&migration.includes("mode_name='starred_earlier' then b.starred and b.starred_at is null"));
ok('Guessed semantic modes',home.includes('guessed_repeated')&&home.includes('guessed_oldest')&&home.includes('guessed_recent')&&home.includes('guessed_random'));
ok('Difficult independent',home.includes('independent from weakness')&&migration.includes("mode_name='difficult' then b.difficult"));
ok('CA All has no hidden freshness',migration.includes('p_ca_months is null or p_ca_months<=0'));

ok('exact concept batch delegates to central selector',migration.includes('public.gk_get_batch(p_mode,100,p_lane,s.subject,s.topic,null,null,null,null,null)'));
ok('concept batch filters canonical id',migration.includes("item->>'concept_id'=p_concept_id"));
ok('concept catalog exposes learning dimensions',['rapidRecall','weak','unseen','mastered'].every(x=>migration.includes(`'${x}'`)));
ok('quiz routes canonical concept id',quiz.includes('gk_get_concept_batch')&&quiz.includes('p_concept_id:concept'));

ok('one central quiz batch engine',quiz.includes('gk_get_batch')&&home.split('href={quiz(').length>10);
ok('localhost Daily uses safe read selector',quiz.includes('activeParams.get("source")==="daily"&&!isGkLocalSafe()')&&quiz.includes('p_mode:mode'));
ok('display exposure is mutation-routed',quiz.includes('gk_record_exposure')&&transport.includes('MUTATION'));
ok('Local Safe intercepts writes',transport.includes('isGkLocalSafe()')&&transport.includes('localSimulation')&&transport.includes('NEXT_PUBLIC_ALLOW_GK_LOCAL_MUTATIONS'));
ok('Local Safe includes create/finish mutations',transport.includes('create_|finish_|complete_'));
ok('durable answer/exposure/guess outbox',['gk_submit_answer','gk_record_exposure','gk_mark_guessed'].every(x=>transport.includes(x))&&transport.includes('mutation-outbox:v2'));
ok('FIFO retry ordering',transport.includes('sort((a,b)=>a.queuedAt-b.queuedAt)')&&transport.includes('const item=rows[0]'));
ok('reconnect/visibility/backoff retry',transport.includes('addEventListener("online"')&&transport.includes('visibilitychange')&&transport.includes('BACKOFF'));
ok('pending sync visible',quiz.includes('pendingGkMutations')&&quiz.includes('pending sync'));

ok('exact pause/resume order',quiz.includes('questions:qs')&&quiz.includes('answers,optionOrders:optionOrders(qs)')&&session.includes('optionOrders?'));
ok('Previous Next Finish Pause',['Previous','Next','Finish','Pause'].every(x=>quiz.includes(x)));
ok('browser Back opens Pause',quiz.includes('popstate')&&quiz.includes('setPauseOpen(true)'));
ok('Star Note Difficult Flag Guessed independent',['★ Star','◆ Difficult','? Guessed','⚑ Flag','▤ Note'].every(x=>quiz.includes(x)));
ok('question intelligence',quiz.includes('Question Intelligence')&&quiz.includes('gk_get_question_intelligence'));
ok('rich explanation sections',['Related Facts:','Exam Trap:','Memory / Trick:'].every(x=>quiz.includes(x)));
ok('canonical/display option mapping',quiz.includes('o.canonicalKey')&&options.includes('canonicalKey'));
ok('unsafe option shuffle guarded',['all of the above','none of the above','chronological','restoreDisplayOptions'].every(x=>options.includes(x)));
ok('resume option order stable',quiz.includes('restoreDisplayOptions')&&quiz.includes('optionOrders'));

function statementLines(raw){
 const lines=String(raw||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
 if(lines.length>1)return lines;
 const t=String(raw||'').trim(),hits=[...t.matchAll(/(?:^|\s)(\d+)\.\s+/g)],nums=hits.map(x=>Number(x[1]));
 const seq=hits.length>=2&&Number(hits[0].index||0)===0&&nums[0]===1&&nums.every((x,i)=>i===0||x===nums[i-1]+1);
 return seq?t.replace(/\s+(?=\d+\.\s)/g,'\n').split('\n'):[t];
}
ok('statement inline split',statementLines('1. First 2. Second 3. Third').length===3);
ok('statement multiline preserved',statementLines('1. First\n2. Second\n3. Third').length===3);
ok('normal numerical prose untouched',statementLines('Article 280 was discussed in 1.5 hours and value 2.0 was noted.').length===1);
ok('statement renderer gated',quiz.includes('const sequential=hits.length>=2')&&quiz.includes('styles.statement'));

for(const x of ['Learning Overview','Knowledge Health','Subject Mastery','Weak Concepts','Current Affairs Health','Starred Revision Health','Guessed Knowledge Health','Difficult Resolution','Lecture / Source Coverage'])ok(`progress: ${x}`,home.includes(x));
ok('first-attempt metric is raw first-answer evidence',migration.includes('distinct on (a.question_id)')&&migration.includes('order by a.question_id,a.attempted_at,a.attempt_id'));
ok('progress exposes Persistent Weak Concepts KPI',migration.includes('"persistentWeakConcepts"')&&home.includes('Persistent Weak Concepts'));
ok('Guessed health includes history/repeated/unresolved',migration.includes("'historicallyGuessed'")&&migration.includes("'unresolved'")&&migration.includes("'repeated'"));
ok('Starred health includes focus/difficult/mastered',migration.includes("'starredHealth'")&&migration.includes("'focus'")&&migration.includes("'difficult'")&&migration.includes("'mastered'"));
ok('Difficult resolution semantics',migration.includes("'resolvedStrong'")&&migration.includes("'needsFocus'"));

ok('RPC execute revoked from public/anon',migration.includes('from public,anon'));
ok('RPC execute granted authenticated',migration.includes('to authenticated'));
ok('English shared transport preserved',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));
ok('GK stays scoped',!home.includes('english_submit_answer')&&!quiz.includes('english_submit_answer'));
ok('no browser service-role secret',!all.toLowerCase().includes('service_role')&&!all.toLowerCase().includes('service-role'));
ok('five-column safe-area nav',css.includes('grid-template-columns:repeat(5,1fr)')&&css.includes('safe-area-inset-bottom'));

if(failed){console.error(`\n${failed} GK contract(s) failed.`);process.exit(1);}
console.log('\nGK V2 localhost-safe contracts passed.');

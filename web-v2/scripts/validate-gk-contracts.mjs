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
const base=read('../supabase/managed-migrations/20260830025704_gk_v2_local_safe_read_surface.sql');
const views=read('../supabase/managed-migrations/20260830032146_gk_v2_view_parity_reads.sql');
const starredGroups=read('../supabase/managed-migrations/20260830032730_gk_v2_starred_group_view_parity.sql');
const migration=[base,views,starredGroups].join('\n');
const all=[home,quiz,transport,session,options,css,migration].join('\n');
let failed=0;
const ok=(name,condition)=>condition?console.log(`✓ ${name}`):(console.error(`✗ ${name}`),failed++);

const tabs=(home.match(/const tabs:Array<\[Tab,string,string\]>=\[(.*?)\];/s)||[])[1]||'';
ok('exactly five GK tabs',((tabs.match(/\["(?:home|content|practice|demand|progress)"/g)||[]).length===5));
for(const x of ['Home','Content','Practice','On Demand','Progress'])ok(`tab visible: ${x}`,tabs.includes(`"${x}"`));
ok('Main/Rapid remain question styles',home.includes('Main + Rapid')&&home.includes('"MAIN"')&&home.includes('"RAPID"'));

for(const lib of ['subject-pyq','mixed','nitto','misc'])ok(`canonical library: ${lib}`,migration.includes(`'${lib}'`));
ok('library identity remains read-derived',base.includes('gk.derive_library_key')&&!base.includes('alter table gk.questions'));
ok('stable lecture identity',base.includes('q.lecture_key=p_lecture_key')&&quiz.includes('p_lecture_key:'));
ok('Content restores four-card library hub',home.includes('styles.contentHub')&&home.includes('catalog.libraries.map'));
ok('Content restores dedicated Current Affairs view',home.includes('Current Affairs Intelligence')&&home.includes('view:"ca"'));
ok('Content restores lecture detail layer',home.includes('lectureKey=params.get("lecture")')&&home.includes('Main Quiz')&&home.includes('Rapid Recall excluded'));
ok('lecture parts are real deterministic RPC slices',views.includes('function public.gk_get_lecture_part_batch')&&views.includes('ord>((part_no-1)*part_size)')&&quiz.includes('gk_get_lecture_part_batch'));
ok('Content scope supports true All beyond 100',views.includes('function public.gk_get_scope_batch')&&views.includes('least(1000')&&quiz.includes('gk_get_scope_batch'));

ok('Practice root restores focused action grid',home.includes('styles.actionGrid')&&home.includes('Random Practice')&&home.includes('Recall Check')&&home.includes('Due Recall'));
ok('New Practice is dedicated hierarchy',home.includes('function NewPracticeView')&&home.includes('Browse New')&&home.includes('new-subjects')&&home.includes('new-libraries')&&home.includes('new-ca'));
ok('New hub is raw-exposure based',views.includes('function public.gk_get_new_practice_hub')&&views.includes('not exists(select 1 from gk.exposures'));
ok('Starred is dedicated progressive view',home.includes('function StarredView')&&home.includes('Normal Starred')&&home.includes('Smart Starred')&&home.includes('Day-wise Starred'));
ok('Starred day group has real random/smart/all selector',starredGroups.includes('function public.gk_get_starred_group_batch')&&starredGroups.includes("kind_name='random'")&&starredGroups.includes("kind_name='smart'"));
ok('Guessed is dedicated knowledge library',home.includes('function GuessedView')&&home.includes('Unresolved knowledge')&&views.includes('function public.gk_get_guessed_hub'));
ok('On Demand restores flagged-content lane',home.includes('Review Flagged Content')&&home.includes('function FlaggedView')&&views.includes('function public.gk_get_flagged_content'));

ok('base read migration performs no table mutation',!/\balter\s+table\b|\binsert\s+into\b|\bupdate\s+gk\.|\bdelete\s+from\b|\btruncate\b|\bdo\s+\$\$/i.test(base));
ok('view parity migration performs no table mutation',!/\balter\s+table\b|\binsert\s+into\b|\bupdate\s+gk\.|\bdelete\s+from\b|\btruncate\b|\bdo\s+\$\$/i.test(views));
ok('starred parity migration performs no table mutation',!/\balter\s+table\b|\binsert\s+into\b|\bupdate\s+gk\.|\bdelete\s+from\b|\btruncate\b|\bdo\s+\$\$/i.test(starredGroups));
ok('central random selector is VOLATILE',/function public\.gk_get_batch[\s\S]*?language plpgsql\s+volatile security definer/i.test(base));
ok('New uses true exposure evidence',base.includes("mode_name in ('new','unseen','new_v2','new_random') then not b.exposed"));
ok('Recall requires exposure',base.includes("mode_name in ('recall','recall_check') then b.exposed"));
ok('Daily/Smart excludes Proven Mastered',base.includes("mode_name in ('daily','smart') then b.st<>'Proven Mastered'"));
ok('Persistent Weak priority dominates',base.includes("'Persistent Weak' then 1000")&&base.includes("'Weak' then 850")&&base.includes("'Fragile' then 700"));
ok('Long Time No See rotates oldest exposure',base.includes("mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen_evidence,to_timestamp(0)))"));
ok('Difficult stays independent manual flag',base.includes("mode_name='difficult' then b.difficult")&&home.includes('personal Difficult marks'));
ok('CA All has no hidden freshness',base.includes('p_ca_months is null or p_ca_months<=0'));

ok('exact concept selector preserved',base.includes('function public.gk_get_concept_batch')&&base.includes("item->>'concept_id'=p_concept_id"));
ok('Weak Concepts still route exact concept id',home.includes('concept:x.conceptId')&&quiz.includes('gk_get_concept_batch'));

ok('one React QuizEngine owns HOW',quiz.includes('gk_get_batch')&&quiz.includes('gk_get_scope_batch')&&quiz.includes('gk_get_lecture_part_batch'));
ok('localhost Daily uses safe read selector',quiz.includes('activeParams.get("source")==="daily"&&!isGkLocalSafe()'));
ok('display exposure remains mutation-routed',quiz.includes('gk_record_exposure')&&transport.includes('MUTATION'));
ok('Local Safe intercepts writes',transport.includes('isGkLocalSafe()')&&transport.includes('localSimulation')&&transport.includes('NEXT_PUBLIC_ALLOW_GK_LOCAL_MUTATIONS'));
ok('durable answer/exposure/guess outbox',['gk_submit_answer','gk_record_exposure','gk_mark_guessed'].every(x=>transport.includes(x))&&transport.includes('mutation-outbox:v2'));
ok('FIFO retry ordering',transport.includes('sort((a,b)=>a.queuedAt-b.queuedAt)')&&transport.includes('const item=rows[0]'));
ok('reconnect/visibility/backoff retry',transport.includes('addEventListener("online"')&&transport.includes('visibilitychange')&&transport.includes('BACKOFF'));

ok('exact pause/resume order',quiz.includes('questions:qs')&&quiz.includes('answers,optionOrders:optionOrders(qs)')&&session.includes('optionOrders?'));
ok('Previous Next Finish Pause',['Previous','Next','Finish','Pause'].every(x=>quiz.includes(x)));
ok('browser Back opens Pause',quiz.includes('popstate')&&quiz.includes('setPauseOpen(true)'));
ok('Pause stays in fixed quiz tools',quiz.includes('styles.dockTools')&&quiz.includes('>Ⅱ Pause</button>')&&!quiz.includes('styles.pauseTop'));
ok('fixed dock keeps Star Flag Difficult Pause only',quiz.includes('styles.dockTools')&&['Star','Flag','Difficult','Pause'].every(x=>quiz.includes(x))&&!/dockTools[\s\S]{0,1000}(?:Note|Guessed)/.test(quiz));
ok('Note is post-answer below explanation',quiz.includes('styles.explanationNoteRow')&&quiz.includes('styles.noteAfter')&&quiz.includes('Add Note'));
ok('Guessed returns to post-answer panel',quiz.includes('styles.guessAfter')&&quiz.includes('I guessed this')&&quiz.includes('gk_mark_guessed'));
ok('answer panel restores headed sections',['Explanation','Related Facts','Exam Trap','Memory / Trick','Source'].every(x=>quiz.includes(x))&&quiz.includes('FeedbackSection'));
ok('Question Intelligence stays separate',quiz.includes('Question Intelligence')&&quiz.includes('gk_get_question_intelligence'));
ok('question header avoids old V2 debug-chip clutter',!quiz.includes('<span className={styles.chip}>{q.id}</span>'));
ok('canonical/display option mapping',quiz.includes('o.canonicalKey')&&options.includes('canonicalKey'));
ok('unsafe option shuffle guarded',['all of the above','none of the above','chronological','restoreDisplayOptions'].every(x=>options.includes(x)));
ok('resume option order stable',quiz.includes('restoreDisplayOptions')&&quiz.includes('optionOrders'));

function statementLines(raw){const lines=String(raw||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(lines.length>1)return lines;const t=String(raw||'').trim(),hits=[...t.matchAll(/(?:^|\s)(\d+)\.\s+/g)],nums=hits.map(x=>Number(x[1])),seq=hits.length>=2&&Number(hits[0].index||0)===0&&nums[0]===1&&nums.every((x,i)=>i===0||x===nums[i-1]+1);return seq?t.replace(/\s+(?=\d+\.\s)/g,'\n').split('\n'):[t];}
ok('statement inline split',statementLines('1. First 2. Second 3. Third').length===3);
ok('statement multiline preserved',statementLines('1. First\n2. Second\n3. Third').length===3);
ok('normal numerical prose untouched',statementLines('Article 280 was discussed in 1.5 hours and value 2.0 was noted.').length===1);
ok('statement renderer gated',quiz.includes('const sequential=hits.length>=2')&&quiz.includes('styles.statement'));

for(const x of ['Learning Overview','Knowledge Health','Subject Mastery','Weak Concepts','Current Affairs Health','Starred Revision Health','Guessed Knowledge Health','Difficult Resolution','Lecture / Source Coverage'])ok(`progress: ${x}`,home.includes(x));
ok('first-attempt metric is raw first-answer evidence',base.includes('distinct on (a.question_id)')&&base.includes('order by a.question_id,a.attempted_at,a.attempt_id'));
ok('Progress exposes Persistent Weak Concepts',base.includes('"persistentWeakConcepts"')&&home.includes('Persistent Weak Concepts'));

ok('new RPCs revoke public/anon',views.includes('from public,anon')&&starredGroups.includes('from public,anon'));
ok('new RPCs grant authenticated',views.includes('to authenticated')&&starredGroups.includes('to authenticated'));
ok('English shared transport preserved',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));
ok('GK stays scoped',!home.includes('english_submit_answer')&&!quiz.includes('english_submit_answer'));
ok('no browser service-role secret',!all.toLowerCase().includes('service_role')&&!all.toLowerCase().includes('service-role'));
ok('five-column safe-area nav',css.includes('grid-template-columns:repeat(5,1fr)')&&css.includes('safe-area-inset-bottom'));
ok('quiz dock has four-tool grid',css.includes('grid-template-columns:repeat(4,minmax(0,1fr))'));

if(failed){console.error(`\n${failed} GK contract(s) failed.`);process.exit(1);}
console.log('\nGK V2 old-app architecture contracts passed.');

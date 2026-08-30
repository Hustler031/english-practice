import fs from 'node:fs';
import path from 'node:path';

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const base=read('../supabase/managed-migrations/20260830025704_gk_v2_local_safe_read_surface.sql');
const views=read('../supabase/managed-migrations/20260830032146_gk_v2_view_parity_reads.sql');
const starredGroups=read('../supabase/managed-migrations/20260830032730_gk_v2_starred_group_view_parity.sql');
const home=read('app/gk/page.tsx');
const quiz=read('app/gk/quiz/page.tsx');
const types=read('lib/gk-types.ts');
let failed=0;
const ok=(name,condition)=>condition?console.log(`✓ ${name}`):(console.error(`✗ ${name}`),failed++);

for(const [name,sql] of [['base',base],['views',views],['starred groups',starredGroups]])ok(`${name} migration has no evidence/state data mutation`,!/\binsert\s+into\b|\bupdate\s+gk\.|\bdelete\s+from\b|\btruncate\b|\bdo\s+\$\$/i.test(sql));
ok('random selector is VOLATILE',/create or replace function public\.gk_get_batch[\s\S]*?language plpgsql\s+volatile security definer/i.test(base));
ok('Long Time No See keeps oldest/never-seen rotation',base.includes("mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen_evidence,to_timestamp(0)))"));
ok('Long Time No See counter is true never-exposed count',base.includes("'longUnseen',(select count(*) from b where not exposed)"));
ok('legacy Starred missing dates are Earlier',base.includes("'Earlier'::text label")&&base.includes('from rows where starred_at is null'));
ok('Starred type permits undated group',types.includes('ageFrom:number|null')&&types.includes('ageTo:number|null'));
ok('Starred focus includes unresolved guesses',base.includes("or next_review<=now() or unconfirmed_guess"));
ok('Home first accuracy uses earliest raw attempt',base.includes('distinct on (a.question_id)')&&base.includes('order by a.question_id,a.attempted_at,a.attempt_id'));
ok('rich payload derives retention without state rewrite',base.includes('question_payload_v2_read')&&base.includes("'retentionAccuracy',case when coalesce(s.retention_attempts,0)>0"));
ok('raw exposures drive unseen/coverage',base.includes('from gk.exposures')&&base.includes('not b.exposed'));
ok('New hub also uses raw exposure truth',views.includes('gk_get_new_practice_hub')&&views.includes('not exists(select 1 from gk.exposures'));
ok('lecture parts do not manufacture exposure',views.includes('gk_get_lecture_part_batch')&&!/gk_get_lecture_part_batch[\s\S]*insert into gk\.exposures/i.test(views));
ok('scope All raises only read limit',views.includes('least(1000')&&!views.includes('alter table'));
ok('Starred group random/smart remain read-only',starredGroups.includes("kind_name='random'")&&starredGroups.includes("kind_name='smart'"));

ok('Progress exposes Persistent Weak Concepts',base.includes('"persistentWeakConcepts"')&&home.includes('Persistent Weak Concepts'));
ok('Guessed Health includes history/repeated/unresolved',base.includes("'historicallyGuessed'")&&base.includes("'unresolved'")&&base.includes("'repeated'"));
ok('Starred Health exposes focus/difficult/mastered',base.includes("'starredHealth'")&&base.includes("'focus'")&&base.includes("'difficult'")&&base.includes("'mastered'"));
ok('Difficult resolution exposes resolved/needs-focus',base.includes("'resolvedStrong'")&&base.includes("'needsFocus'"));

ok('exact concept batch delegates to central selector',base.includes('public.gk_get_batch(p_mode,100,p_lane,s.subject,s.topic,null,null,null,null,null)'));
ok('concept batch filters exact canonical concept_id',base.includes("item->>'concept_id'=p_concept_id"));
ok('quiz routes concept through exact wrapper',quiz.includes('gk_get_concept_batch')&&quiz.includes('p_concept_id:concept'));
ok('Weak Concepts keep exact concept practice',home.includes('concept:x.conceptId'));

ok('Current Affairs exposes All 1M 3M 6M',home.includes('["all","All"]')&&home.includes('["1m","1 Month"]')&&home.includes('["3m","3 Months"]')&&home.includes('["6m","6 Months"]'));
ok('Current Affairs supports Smart and Random',home.includes('mode:"current_smart"')&&home.includes('mode:"current_random"'));
ok('New Current Affairs is exposure-safe',home.includes('view:"new-ca"')&&home.includes('subject:"Current Affairs"'));
ok('GK tab reads remain scoped',home.includes('if(tab==="content")')&&home.includes('if(tab==="practice")')&&home.includes('if(tab==="demand")')&&home.includes('if(tab==="progress")'));

ok('read RPCs authenticated-only',base.includes('from public,anon')&&views.includes('from public,anon')&&starredGroups.includes('from public,anon')&&base.includes('to authenticated')&&views.includes('to authenticated')&&starredGroups.includes('to authenticated'));

const attempts=[{q:'A',at:1,ok:false},{q:'A',at:2,ok:true},{q:'B',at:1,ok:true},{q:'B',at:2,ok:true},{q:'C',at:1,ok:true}];
const first=new Map();for(const a of attempts){if(!first.has(a.q))first.set(a.q,a.ok);}
const firstAccuracy=[...first.values()].filter(Boolean).length*100/first.size;
const cumulative=attempts.filter(x=>x.ok).length*100/attempts.length;
ok('behavior: first-attempt accuracy differs from cumulative accuracy',Math.round(firstAccuracy*10)/10===66.7&&cumulative===80);

if(failed){console.error(`\n${failed} GK evidence parity contract(s) failed.`);process.exit(1);}
console.log('\nGK evidence/read parity contracts passed.');

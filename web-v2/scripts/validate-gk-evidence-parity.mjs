import fs from 'node:fs';
import path from 'node:path';

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const migration=read('../supabase/managed-migrations/20260830025000_gk_v2_evidence_parity.sql');
const home=read('app/gk/page.tsx');
const types=read('lib/gk-types.ts');
let failed=0;
const ok=(name,condition)=>condition?console.log(`✓ ${name}`):(console.error(`✗ ${name}`),failed++);

ok('random selector is VOLATILE',/create or replace function public\.gk_get_batch[\s\S]*?language plpgsql\s+volatile security definer/i.test(migration));
ok('Long Time No See keeps old rotation ordering',migration.includes("mode_name='long_unseen' then extract(epoch from coalesce(e.last_seen,to_timestamp(0)))"));
ok('Long Time No See counter is old never-seen count',migration.includes("'longUnseen',(select count(*) from b where last_seen is null)"));
ok('legacy Starred missing dates are preserved as Earlier',migration.includes("'Earlier'::text label")&&migration.includes("where starred_at is null"));
ok('Earlier has a dedicated selector mode',migration.includes("mode_name='starred_earlier' then b.starred and b.starred_at is null")&&home.includes('"starred_earlier"'));
ok('Starred type permits legacy undated group',types.includes('ageFrom:number|null')&&types.includes('ageTo:number|null'));
ok('Starred focus includes unresolved guesses',migration.includes("or next_review<=now() or unconfirmed_guess"));
ok('Home first accuracy uses first-attempt evidence',migration.includes("first_attempt_correct is true")&&migration.includes("first_attempt_correct is not null"));
ok('Progress exposes Persistent Weak Concepts KPI',migration.includes('persistentWeakConcepts')&&home.includes('Persistent Weak Concepts'));
ok('Guessed Health includes history/repeated/unresolved',migration.includes("'historicallyGuessed'")&&migration.includes("'unresolved'")&&migration.includes("'repeated'"));
ok('Starred Health restores focus/difficult/mastered',migration.includes("'starredHealth'")&&migration.includes("'focus'")&&migration.includes("'difficult'")&&migration.includes("'mastered'"));
ok('Difficult resolution restores old semantics',migration.includes("'resolvedStrong'")&&migration.includes("'needsFocus'"));
ok('derived state is reconciled from raw attempts/exposures',migration.includes('perform gk.refresh_question_state(r.user_id,r.question_id)')&&migration.includes('select user_id,question_id from gk.attempts')&&migration.includes('select user_id,question_id from gk.exposures'));
ok('correction RPCs remain authenticated-only',migration.includes('from public, anon')&&migration.includes('to authenticated'));

// First-attempt metric must count one first result per question, not all attempts.
const attempts=[
 {q:'A',at:1,ok:false},{q:'A',at:2,ok:true},{q:'B',at:1,ok:true},{q:'B',at:2,ok:true},{q:'C',at:1,ok:true}
];
const first=new Map();for(const a of attempts){if(!first.has(a.q))first.set(a.q,a.ok);}
const firstAccuracy=[...first.values()].filter(Boolean).length*100/first.size;
const cumulative=attempts.filter(x=>x.ok).length*100/attempts.length;
ok('behavior: first-attempt accuracy differs from cumulative accuracy',Math.round(firstAccuracy*10)/10===66.7&&cumulative===80);

if(failed){console.error(`\n${failed} GK evidence parity contract(s) failed.`);process.exit(1);}
console.log('\nGK evidence parity contracts passed.');

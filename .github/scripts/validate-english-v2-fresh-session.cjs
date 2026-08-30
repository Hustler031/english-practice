const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(text,needle,label)=>text.includes(needle)?ok(label):fail(`${label} — missing ${needle}`);
const reject=(text,needle,label)=>!text.includes(needle)?ok(label):fail(`${label} — forbidden ${needle}`);
const assert=(condition,label)=>condition?ok(label):fail(label);

const supabase=read('web-v2/lib/supabase.ts');
const runner=read('web-v2/components/quiz-runner.tsx');
const daily=read('web-v2/app/english/daily/page.tsx');
const hindu=read('web-v2/app/english/hindu/page.tsx');
const bank=read('web-v2/app/english/bank/page.tsx');
const extra=read('web-v2/app/english/extra/page.tsx');
const sources=read('web-v2/app/english/sources/page.tsx');
const demand=read('web-v2/app/english/demand/page.tsx');
const saved=read('web-v2/app/english/saved/page.tsx');
const phrasal=read('web-v2/app/english/phrasal/page.tsx');
const migration1=read('supabase/managed-migrations/20260830180000_english_quiz_session_freshness.sql');
const migration2=read('supabase/managed-migrations/20260830181000_english_source_group_fresh_session.sql');
const sql=migration1+'\n'+migration2;

// Central cache/session policy.
[
  'english_get_revision_batch','english_get_difficult_items','english_get_saved_revision_batch',
  'english_get_new_practice_batch','english_get_topic_batch','english_get_source_batch',
  'english_get_source_group_batch','english_get_starred_batch','english_get_phrasal_batch',
  'english_get_today_extra_batch','english_get_bank_coverage_batch','english_get_demand_batch'
].forEach(name=>need(supabase,`case \"${name}\"`,`${name} classified centrally`));
need(supabase,'if (sessionReadPolicy(name, args)) return false;','fresh/session reads are excluded from generic cache');
need(supabase,'english_start_fresh_session','fresh launches use one live backend gateway');
need(supabase,'prepareFreshSession(maxMs = 1400)','new sessions give the answer outbox a bounded drain opportunity');
need(supabase,'pendingQuestionIds()','pending durable answers participate in immediate exclusion');
need(supabase,'recordLocalSession(policy.lane, fresh)','served session IDs are retained locally as a pending-sync fallback');
need(supabase,'freshInflight','duplicate simultaneous fresh launches are coalesced');
need(supabase,'if (readOutbox().length) { scheduleCacheRefresh(2500); return; }','dashboard refresh waits while answer durability is pending');
need(supabase,'entries.slice(0, 8)','post-answer informational refresh fan-out is bounded');
need(supabase,'learnerErrorMessage','database/network engine errors are normalized for learners');
need(supabase,'Local answer storage is unavailable','local outbox persistence failure remains actionable');

// Fixed/repeat lanes remain outside the rotating gateway.
reject(supabase,'case \"english_resume_daily\"','Daily is not treated as a fresh rotating session');
reject(supabase,'case \"english_get_hindu_quiz\"','Hindu Today remains a fixed/repeat set');
reject(supabase,'case \"english_get_phrasal_today\"','Phrasal Today remains fixed');
reject(supabase,'case \"english_get_phrasal_history_batch\"','Phrasal History remains fixed/history');
reject(supabase,'case \"english_get_saved_history_batch\"','My Saved History remains fixed/history');
need(supabase,'mode === \"all\" ? null','Demand Practice All bypasses rotation for deterministic resume');
need(supabase,'english_get_bank_coverage_seen_batch','Bank seen-practice remains an intentional live repeat lane');
need(supabase,'english_get_bank_coverage_review_batch','Bank Today Review remains an intentional live repeat lane');

// Backend ledger + rotation contracts.
need(sql,'create table if not exists english.quiz_sessions','fresh sessions are auditable');
need(sql,'create table if not exists english.quiz_session_exposures','served Question_ID exposure is auditable');
need(sql,'unique(user_id, session_id, question_id)','one session cannot record a duplicate Question_ID');
need(sql,'select distinct on (qid)','batch payload is deduplicated before selection');
need(sql,'latest_global','immediately previous study session is a hard cooldown input');
need(sql,'latest_lane','immediately previous same-lane session is a hard cooldown input');
need(sql,'p_client_exclude','pending/local served questions can be excluded before durable attempts arrive');
need(sql,'p_strict_unseen and (ever_served','strict unseen does not refill from previously served questions');
need(sql,'priority_band','learning priority is preserved inside freshness bands');
need(sql,'last_activity asc','least-recent activity wins within comparable freshness/priority');
need(sql,"lane:='extra'",'Extra Practice has its own freshness lane');
need(sql,'english.extra_practice_candidates','Extra preserves its dedicated learning-priority candidate selector');
need(sql,'english.bank_unseen_candidates','Bank Coverage unseen uses a strict unseen candidate selector');
need(sql,'english.source_group_candidates','grouped Sources/PDF candidates are selected server-side');
need(sql,"when 'english_get_source_group_batch'",'grouped Sources/PDF launches use the central exposure ledger');
need(sql,"if m='all' then raise exception 'Demand Practice All is a fixed/resume lane'",'backend protects fixed Demand Practice All semantics');
need(sql,'english_complete_fresh_session','completed fresh-session context is persisted');
need(sql,'record_session:=not english.request_is_local_safe()','localhost production-safe testing cannot write exposure evidence');
reject(sql,'delete from english.attempts','migration never deletes attempt history');
reject(sql,'truncate english.attempts','migration never resets attempt history');
reject(sql,'delete from english.question_state','migration never deletes learning state');

// Sources/PDF no longer fans out independent served sessions then slices locally.
need(sources,'english_get_source_group_batch','Sources/PDF uses one grouped learner-visible session');
reject(sources,'pick.keys.map(key=>rpc<any[]>(\"english_get_source_batch\"','Sources/PDF no longer records false per-source exposures');
reject(sources,'items.slice(0,Math.max(1,pick.count))','Sources/PDF does not truncate after exposures are recorded');

// Extra lane mismatch regression.
need(extra,'english_get_today_extra_batch','Extra Practice uses its own selector');
reject(extra,'english_get_revision_batch','Extra Practice no longer falls back through the Revision lane');

// Stable navigation + safe learner-facing errors.
[runner,daily,hindu].forEach((text,i)=>{
  const label=['shared QuizRunner','Daily','Hindu'][i];
  reject(text,'behavior:\"smooth\"',`${label} has no smooth question-to-question scroll`);
  need(text,'behavior:\"auto\"',`${label} uses instant controlled top positioning`);
  need(text,'learnerErrorMessage',`${label} sanitizes database/network errors`);
});
need(runner,'english_complete_fresh_session','shared QuizRunner marks fresh sessions complete on Finish');
need(runner,'Opening {title} with current learning data','fresh quiz loader no longer claims an old cache is being opened');

// Fixed product routes still visibly retain their intended contracts.
need(demand,'Resume All','Demand deterministic resume remains present');
need(saved,'english_get_saved_history_batch','My Saved fixed-day history remains present');
need(phrasal,'english_get_phrasal_today','Phrasal Today fixed batch remains present');
need(phrasal,'english_get_phrasal_history_batch','Phrasal permanent history remains present');
need(bank,'english_get_bank_coverage_review_batch','Bank Today Review remains present');
need(bank,'english_get_bank_coverage_seen_batch','Bank Seen Practice remains present');

// Deterministic behavioral model of the SQL ordering contract.
function select(rows,limit,{strict=false,clientExclude=[]}={}){
  const exclude=new Set(clientExclude);
  const first=new Map();
  rows.forEach((row,ord)=>{if(row&&row.id&&!first.has(row.id))first.set(row.id,{...row,ord});});
  const dedup=[...first.values()];
  const eligible=dedup.filter(r=>!(strict&&(r.everServed||exclude.has(r.id))));
  eligible.forEach(r=>{
    r.hard=!!r.hardRecent||exclude.has(r.id);
    r.band=Math.floor(r.ord/Math.max(1,limit));
    r.last=Number(r.lastActivity||0);
  });
  eligible.sort((a,b)=>Number(a.hard)-Number(b.hard)||Number(!!a.everServed)-Number(!!b.everServed)||a.band-b.band||a.last-b.last||a.ord-b.ord||String(a.id).localeCompare(String(b.id)));
  return eligible.slice(0,limit).map(r=>r.id);
}
const ids=n=>Array.from({length:n},(_,i)=>`Q${String(i+1).padStart(3,'0')}`);
const unique=a=>new Set(a).size===a.length;

// 33 eligible, request 20: 13 unused first, only seven fallback.
const pool33=ids(33).map(id=>({id}));
const s1=select(pool33,20);
const s1set=new Set(s1);
const s2rows=pool33.map((r,i)=>({...r,everServed:s1set.has(r.id),hardRecent:s1set.has(r.id),lastActivity:s1set.has(r.id)?100+i:0}));
const s2=select(s2rows,20);
assert(s1.length===20&&unique(s1),'33→20 session 1 contains 20 unique IDs');
assert(s2.length===20&&unique(s2),'33→20 session 2 contains 20 unique IDs');
assert(s2.slice(0,13).every(id=>!s1set.has(id)),'33→20 session 2 serves all 13 unused alternatives before fallback');
assert(s2.slice(13).filter(id=>s1set.has(id)).length===7,'33→20 session 2 uses exactly seven recent fallbacks');

// Strict unseen: never backfill with seen rows.
const strictRows=[...ids(13).map(id=>({id})),...ids(87).map((_,i)=>({id:`S${i+1}`,everServed:true}))];
const strict=select(strictRows,20,{strict:true});
assert(strict.length===13&&strict.every(id=>id.startsWith('Q')),'strict unseen returns 13/20 when only 13 genuinely unseen remain');

// Large Smart pool: next session prefers the other 50.
const pool70=ids(70).map(id=>({id}));
const large1=select(pool70,20),largeSet=new Set(large1);
const large2=select(pool70.map((r,i)=>({...r,everServed:largeSet.has(r.id),hardRecent:largeSet.has(r.id),lastActivity:largeSet.has(r.id)?1000+i:0})),20);
assert(large2.every(id=>!largeSet.has(id)),'70→20 Smart session 2 has no immediate reuse while 50 alternatives exist');

// Small Smart pool: five alternatives first, then controlled fallback.
const pool25=ids(25).map(id=>({id}));
const small1=select(pool25,20),smallSet=new Set(small1);
const small2=select(pool25.map((r,i)=>({...r,everServed:smallSet.has(r.id),hardRecent:smallSet.has(r.id),lastActivity:smallSet.has(r.id)?200+i:0})),20);
assert(small2.slice(0,5).every(id=>!smallSet.has(id)),'25→20 Smart session 2 serves five non-recent alternatives first');
assert(small2.slice(5).filter(id=>smallSet.has(id)).length===15,'25→20 Smart session 2 fills exactly 15 from least-recent fallback');

// Pending outbox/local session exclusion protects the next launch before durability.
const pendingPool=ids(30).map(id=>({id}));
const pendingPrev=ids(20);
const pendingNext=select(pendingPool,20,{clientExclude:pendingPrev});
assert(pendingNext.slice(0,10).every(id=>!pendingPrev.includes(id)),'pending-sync exclusion serves all available alternatives before queued-answer IDs');

// Duplicate payload input cannot create duplicate Question_IDs in one batch.
const duplicateInput=[{id:'D1'},{id:'D1'},{id:'D2'},{id:'D3'},{id:'D2'}];
const duplicateOut=select(duplicateInput,10);
assert(unique(duplicateOut)&&duplicateOut.length===3,'same-session duplicate Question_IDs are removed deterministically');

if(process.exitCode){
  console.error('\nEnglish V2 fresh-session validation failed. Merge/deployment must not proceed.');
  process.exit(process.exitCode);
}
console.log('\n✅ English V2 fresh-session deterministic contracts passed.');

const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(text,needle,label)=>text.includes(needle)?ok(label):fail(`${label} — missing ${needle}`);
const reject=(text,needle,label)=>!text.includes(needle)?ok(label):fail(`${label} — forbidden ${needle}`);
const assert=(condition,label)=>condition?ok(label):fail(label);

const migration=read('supabase/managed-migrations/20260830210000_english_interaction_cooldown.sql');
const supabase=read('web-v2/lib/supabase.ts');
const frame=read('web-v2/components/english-frame.tsx');
const css=read('web-v2/app/session-rotation-ui-fixes.css');

need(migration,"coalesce(s.last_attempt >= now()-interval '90 minutes',false)",'durable recent attempts drive server cooldown and untouched NULL attempts stay non-recent');
need(migration,"qid=any(coalesce(p_client_exclude,'{}'::text[]))",'pending local answers remain an immediate cooldown input');
need(migration,'attempts>0','strict unseen is based on actual attempt evidence');
need(migration,'priority_band asc','Central Intelligence candidate priority stays ahead of within-band recency');
reject(migration,'latest_global','generated previous session is not a hard cooldown source');
reject(migration,'latest_lane','generated same-lane session is not a hard cooldown source');
reject(migration,'ever_served','generated/served history does not consume eligibility');
reject(migration,'last_exposure','exposure audit rows do not drive adaptive ordering');
need(migration,'insert into english.quiz_session_exposures','session generation remains auditable');

const localExclude=supabase.match(/function localExcludeIds\([\s\S]*?\n\}/)?.[0]||'';
need(localExclude,'pendingQuestionIds()','client exclusion contains pending attempted Question_IDs');
reject(localExclude,'readLocalSessions()','generated local batches are not sent back as cooldown exclusions');
reject(localExclude,'LOCAL_SESSION_MAX_AGE','strict/new sessions do not consume untouched generated items client-side');

reject(frame,'Syncing {pendingSaves}','quiz no longer renders animated Syncing text');
need(frame,'sync-status-dot sync-pending','quiz uses a compact pending dot');
need(frame,'sync-status-dot sync-saved','final durable save gets a subtle green dot');
need(frame,'{pendingSaves} pending','home exposes the actual pending count');
need(frame,'pendingSaves>0&&(isHome?','zero pending leaves the Home header clean');
need(css,'animation:none!important','sync indicators explicitly disable animation');
need(css,'.sync-status-dot.sync-pending{background:var(--primary)}','pending dot uses restrained purple');
need(css,'.sync-status-dot.sync-saved{background:var(--ok)}','saved confirmation uses restrained green');

function select(rows,limit,{strict=false,pending=[]}={}){
  const pendingSet=new Set(pending);
  const first=new Map();
  rows.forEach((row,ord)=>{if(row&&row.id&&!first.has(row.id))first.set(row.id,{...row,ord});});
  const eligible=[...first.values()].filter(r=>!(strict&&((r.attempts||0)>0||pendingSet.has(r.id))));
  eligible.forEach(r=>{
    r.hard=pendingSet.has(r.id)||!!r.recentAttempt;
    r.band=Math.floor(r.ord/Math.max(1,limit));
    r.last=Number(r.lastAttempt||0);
  });
  eligible.sort((a,b)=>Number(a.hard)-Number(b.hard)||a.band-b.band||a.last-b.last||a.ord-b.ord||String(a.id).localeCompare(String(b.id)));
  return eligible.slice(0,limit).map(r=>r.id);
}
const ids=n=>Array.from({length:n},(_,i)=>`Q${String(i+1).padStart(3,'0')}`);

// User contract: a generated 20-question Smart batch does not consume untouched questions.
// If only five were actually attempted, those five cool down while the other fifteen remain eligible.
const generated=ids(20);
const attempted=new Set(generated.slice(0,5));
const candidates=[
  ...generated.map((id,i)=>({id,attempts:attempted.has(id)?1:0,recentAttempt:attempted.has(id),lastAttempt:attempted.has(id)?100+i:0})),
  ...Array.from({length:20},(_,i)=>({id:`N${String(i+1).padStart(3,'0')}`,attempts:0}))
];
const next=select(candidates,20);
const untouched=generated.slice(5);
assert(untouched.every(id=>next.includes(id)),'20 generated / 5 attempted keeps all 15 untouched questions eligible in the next Smart selection');
assert(generated.slice(0,5).every(id=>!next.slice(0,15).includes(id)),'the five actual attempts cool down ahead of untouched eligible questions');

const strictNext=select(candidates,20,{strict:true});
assert(strictNext.every(id=>!attempted.has(id)),'strict unseen excludes attempted questions');
assert(untouched.every(id=>strictNext.includes(id)),'strict unseen does not consume generated-but-unattempted questions');

const pendingCase=select(ids(25).map(id=>({id})),20,{pending:['Q001','Q002']});
assert(!pendingCase.slice(0,20).includes('Q001')&&!pendingCase.slice(0,20).includes('Q002'),'pending local answers remain protected before durability catches up');

if(!process.exitCode)console.log('\n✅ English V2 interaction-cooldown + silent-sync UX contracts passed.');

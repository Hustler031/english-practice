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
const p1=read('supabase/managed-migrations/20260904090000_english_p1_reliability_targeted_hindu_worker.sql');
const p2=read('supabase/managed-migrations/20260904093000_english_p2_content_lifecycle_security.sql');
const workerHotfix=read('supabase/managed-migrations/20260904172000_english_worker_runtime_guard_hotfix.sql');
const rpcHardening=read('supabase/managed-migrations/20260904173000_english_public_rpc_invoker_hardening.sql');
const transferLease=read('supabase/managed-migrations/20260904174000_english_transfer_lease_recovery.sql');
const supabase=read('web-v2/lib/supabase.ts');
const targetedReliability=read('web-v2/lib/targeted-reliability.ts');
const targetedPage=read('web-v2/app/english/targeted/page.tsx');
const homePage=read('web-v2/app/english/page.tsx');
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
  eligible.forEach(r=>{r.hard=pendingSet.has(r.id)||!!r.recentAttempt;r.band=Math.floor(r.ord/Math.max(1,limit));r.last=Number(r.lastAttempt||0);});
  eligible.sort((a,b)=>Number(a.hard)-Number(b.hard)||a.band-b.band||a.last-b.last||a.ord-b.ord||String(a.id).localeCompare(String(b.id)));
  return eligible.slice(0,limit).map(r=>r.id);
}
const ids=n=>Array.from({length:n},(_,i)=>`Q${String(i+1).padStart(3,'0')}`);
const generated=ids(20);
const attempted=new Set(generated.slice(0,5));
const candidates=[...generated.map((id,i)=>({id,attempts:attempted.has(id)?1:0,recentAttempt:attempted.has(id),lastAttempt:attempted.has(id)?100+i:0})),...Array.from({length:20},(_,i)=>({id:`N${String(i+1).padStart(3,'0')}`,attempts:0}))];
const next=select(candidates,20);
const untouched=generated.slice(5);
assert(untouched.every(id=>next.includes(id)),'20 generated / 5 attempted keeps all 15 untouched questions eligible in the next Smart selection');
assert(generated.slice(0,5).every(id=>!next.slice(0,15).includes(id)),'the five actual attempts cool down ahead of untouched eligible questions');
const strictNext=select(candidates,20,{strict:true});
assert(strictNext.every(id=>!attempted.has(id)),'strict unseen excludes attempted questions');
assert(untouched.every(id=>strictNext.includes(id)),'strict unseen does not consume generated-but-unattempted questions');
const pendingCase=select(ids(25).map(id=>({id})),20,{pending:['Q001','Q002']});
assert(!pendingCase.slice(0,20).includes('Q001')&&!pendingCase.slice(0,20).includes('Q002'),'pending local answers remain protected before durability catches up');

need(p1,'english.targeted_question_in_cooldown','Targeted has an explicit exact-question cooldown');
need(p1,"when l.correct then",'Targeted cooldown distinguishes correct evidence');
need(p1,"else now()<l.attempted_at+interval '90 minutes'",'wrong Targeted answers receive a short exact-item cooldown');
need(p1,"kind in('confusion','transfer_check','need_learning')",'Targeted repair lanes can choose an alternate same-concept item');
need(p1,'Never force-fill by replaying the same exact item','Targeted may underfill instead of violating spacing');
need(p1,'english.targeted_recent_session_excludes','immediate next Targeted session excludes the prior Targeted exposure set');
need(p1,'p_client_exclude text[]','Targeted gateway accepts pending local answer IDs');
need(targetedReliability,'waitForAnswerDurability','Targeted waits for the durable answer outbox before a fresh set');
need(targetedReliability,'p_client_exclude: exclude','still-pending Targeted answers are sent as hard server exclusions');
need(targetedReliability,'english_start_targeted_fresh_session','Targeted has a dedicated fresh-session gateway');
need(targetedReliability,'Exact-item reads must never come from the 12-hour generic RPC cache','exact Targeted clicks bypass stale generic cache');
need(targetedPage,'targetedSessionRpc<any[]>','Targeted practice uses the durable fresh-session adapter');
need(targetedPage,'targetedLiveRpc<Hub>','Targeted mastery counters bypass stale cache');
need(homePage,'targetedLiveRpc<TargetedSummary>','Next Best Action reads live Targeted eligibility');
need(homePage,'subscribeTargetedDurability','Next Best Action refreshes after answer durability');

need(p1,'english.hindu_daily_eligible','Hindu Daily eligibility has a single server-side boundary');
need(p1,'coalesce(r.marked,false) or coalesce(r.in_vocab,false)','only explicitly retained Hindu items are Daily-eligible');
need(p1,'daily_hindu_exposure_guard','Daily inserts cannot leak exposure-only Hindu items');
need(p1,'hindu_daily_exposure_guard','unmark/remove actions prune future unattempted Hindu Daily leakage');
need(p1,"lower(coalesce(a.module,''))='daily'",'Hindu cleanup preserves already-attempted Daily history');

need(p1,'english.worker_scheduler_state','context worker has durable scheduler state');
need(p1,'english.worker_lane_allowed','worker claim RPCs are lane-gated');
need(p1,"worker_lane_allowed('revision')",'Revision queue can be explicitly scheduled');
need(p1,"worker_lane_allowed('quality_review')",'Quality Review queue can be explicitly scheduled');
need(p1,'english.context_worker_requests','scheduler records outbound worker request IDs');
need(p1,'net._http_response','scheduler reconciles HTTP status/timeouts even if the Edge Function fails before metrics');
need(p1,'english.worker_observability','worker failures remain observable');
need(workerHotfix,'english.context_ai_runtime_guard','worker hotfix restores the proven runtime token source');
need(workerHotfix,'perform english.enqueue_missing_targeted_transfers(6)','worker hotfix preserves automatic bank-first transfer discovery');
need(workerHotfix,'https://hytehindbmjdwcfptsic.supabase.co/functions/v1/english-context-worker','worker hotfix preserves the proven production Edge endpoint');
reject(workerHotfix,'vault.decrypted_secrets','worker scheduler no longer depends on unconfigured Vault secrets');
need(workerHotfix,'worker_scheduler_state','worker hotfix preserves fair lane scheduling');
need(workerHotfix,'reconcile_context_worker_http','worker hotfix preserves HTTP failure telemetry');

need(transferLease,"status='processing'\n        then english.targeted_transfer_jobs.updated_at",'transfer discovery cannot renew an active processing lease');
need(transferLease,"updated_at<now()-interval '5 minutes'",'transfer stale recovery uses a bounded lease');
need(transferLease,"last_error='stale generation recovered'",'stale transfer work is explicitly recovered before discovery');
need(transferLease,'Recover/terminate expired leases before discovery','transfer recovery occurs before bank-first re-enqueue');

need(rpcHardening,'security invoker','audited public RPC wrappers are SECURITY INVOKER');
need(rpcHardening,'uid is distinct from caller','internal privileged RPCs bind user identity to auth.uid()');
need(rpcHardening,'revoke execute on function public.english_get_today_extra_batch(integer) from public,anon','Extra RPC remains unavailable anonymously');
need(rpcHardening,'revoke execute on function public.english_set_hindu_vocab(text,boolean) from public,anon','Hindu vocab mutation remains unavailable anonymously');

need(p2,'Fixed Preposition explanation backfill','P2 contains the Fixed Preposition content backfill');
need(p2,'“Discuss” is transitive here','no-preposition explanation is concept-specific, not filler');
need(p2,'“Home” functions adverbially','go-home item has a concept-specific grammar explanation');
need(p2,'Fixed Preposition explanation backfill incomplete','migration fails closed if any targeted explanation remains blank');
need(p2,"terminal_reason='expired'",'stale quiz sessions get an explicit expired terminal state');
need(p2,'quiz_sessions_expire_stale_before_insert','new quiz sessions opportunistically close stale sessions');
need(p2,"'completed'::text,'abandoned'::text",'Sprint generation jobs have real terminal lifecycle states');
need(p2,'sprint_generation_terminal_sync','Sprint job terminal state follows the learner session');
need(p2,'revoke execute on function public.english_set_hindu_vocab','anonymous Hindu mutation execution is revoked');
need(p2,'revoke execute on function public.english_get_today_extra_batch','anonymous Extra execution is revoked');
need(p2,'using ((select auth.uid())=user_id)','quiz-session RLS evaluates auth.uid once per statement');
need(p2,'english_transfer_jobs_source_question_idx','Targeted transfer FK path is indexed');

if(!process.exitCode)console.log('\n✅ English V2 interaction-cooldown + P1/P2 reliability contracts passed.');

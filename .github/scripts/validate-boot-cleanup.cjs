const fs=require('fs'),path=require('path');
const root=path.join(__dirname,'../..','apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
let bad=0;const ok=m=>console.log('✓ '+m),fail=m=>{bad++;console.error('✗ '+m)},need=(s,x,m)=>s.includes(x)?ok(m):fail(m),forbid=(s,x,m)=>!s.includes(x)?ok(m):fail(m);
const app=read('AppJS.html'),fast=read('FastUI.html'),save=read('SaveReliabilityUI.html'),boot=read('BootstrapUI.gs'),daily=read('DailyAdaptive.gs');
need(app,'practiceLoadingTimer','AppJS owns the single loader timeout');need(app,'deferAfterHome','AppJS coordinates post-home warmups');need(app,'requestIdleCallback','Warmups yield to browser idle time');
for(const f of ['FastUI.html','SavedUI.html','TopicUI.html','NewPracticeUI.html','SourceUI.html']){const s=read(f);forbid(s,'compactQuizLoading','No secondary compact quiz overlay in '+f);need(s,'showPracticeLoading','Quiz launch delegates to AppJS loader in '+f)}
need(fast,'EPApp.deferAfterHome?.(()=>prefetch())','Aggregate prefetch waits for home');
need(read('SmartMySavedUI.html'),'EPApp.deferAfterHome?.(()=>refresh(false))','Smart My Saved warmup waits for home');need(read('PhrasalMasteryUI.html'),'EPApp.deferAfterHome?.(()=>refresh(false))','Phrasal warmup waits for home');
forbid(boot,'progressSnapshot','Bootstrap omits discarded progress snapshot');
need(save,'derivedPending=true','Derived repair retains a conservative startup/watchdog state');need(save,'setInterval(()=>{if(readQueue().length)flushSoon(0);else if(derivedPending)kickDerivedRepair(0)},300000)','Idle watchdog is conservative and skips known-empty repair work');need(save,'if(!derivedPending)return','Derived repair is event/state gated');need(save,'p.attemptId=String(p.attemptId||\'\').trim()||makeAttemptId(id)','Attempt_ID durability remains unchanged');need(save,'submitAnswerBatchV4','Batch durable save remains unchanged');
need(daily,'!q||!isActive_(q)||mastered[id]','Persisted Daily reconciliation suppresses manual Mastered rows');need(read('LearningIntelligence.gs'),'manualMasteredMapV3_','Manual Mastered remains derived from Mastered_Log');
if(bad){console.error('\nBoot cleanup validation failed.');process.exit(1)}console.log('\n✅ Boot cleanup behavioural contracts passed.');

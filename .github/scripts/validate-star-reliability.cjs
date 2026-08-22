const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
for(const f of ['CentralStarReliability.gs','CentralFlags.gs','LearningLayoutCompat.html'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const server=read('CentralStarReliability.gs'),flags=read('CentralFlags.gs'),ui=read('LearningLayoutCompat.html');
try{new vm.Script(server,{filename:'CentralStarReliability.gs'});ok('Central Star reliability server syntax')}catch(e){fail(`CentralStarReliability syntax: ${e.message}`)}
try{new vm.Script(ui.replace(/<\/?script[^>]*>/gi,''),{filename:'LearningLayoutCompat.html'});ok('Star reliability/layout UI syntax')}catch(e){fail(`LearningLayoutCompat syntax: ${e.message}`)}
[
  ['LockService.getUserLock()','Star writes use a user lock instead of the answer-save ScriptLock'],
  ['appendStarTransitionV4_','STAR/UNSTAR is written as an explicit state transition'],
  ['before.marked!==desired','duplicate same-state STAR events are idempotent'],
  ['syncStarStatusV4_','Question_Status mirrors the authoritative Star transition'],
  ['meta.rows.forEach','duplicate status rows receive one consistent Last_Marked value immediately'],
  ['repairPendingStarStatusDuplicatesV4','duplicate status rows have deferred canonical consolidation'],
  ['writeStatusSummaryV2_','duplicate consolidation preserves derived learning state'],
  ['getCentralStarAuditV4','central Star integrity audit endpoint exists'],
  ["durable:true",'server explicitly confirms durable Star state']
].forEach(([n,l])=>need(server,n,l));
need(flags,"setMarkedCentralV4(questionId,!!marked)",'legacy central Mark endpoint delegates to V4');
need(flags,"setHinduMarkedCentralV4(questionId,!!marked)",'legacy Hindu Mark endpoint delegates to V4');
[
  ["OUTBOX_KEY='ep-star-outbox-v4'",'Star taps have a durable local outbox'],
  ["setMarkedCentralV4",'normal Star outbox flushes to V4'],
  ["setHinduMarkedCentralV4",'Hindu Star outbox flushes to V4'],
  ['overlayPending','pending Star state survives fresh quiz payloads'],
  ['backoff','failed Star writes retry with backoff'],
  ['learning-difficult-row','Difficult-enabled quiz tools use the compact one-row layout'],
  ["--learning-tool-count",'one-row toolbar adapts to the number of visible controls'],
  ["master.classList.add('hidden')",'Difficult-enabled quizzes move Mastered out of the fixed tool row'],
  ['EPStarredRevision.syncDifficultButton','other Difficult-enabled quizzes reuse Starred Revision Mastered placement']
].forEach(([n,l])=>need(ui,n,l));
if(server.includes("getScriptLock();if(!lock.tryLock(2000)"))fail('V4 Star write must not reuse the old 2-second ScriptLock path');else ok('V4 Star write avoids old MARK_BUSY_RETRY lock contention');
if(ui.includes('submitAnswer')||ui.includes('nextBtn.disabled'))fail('Star/layout layer must not touch answer saving or Next');else ok('Star/layout layer does not touch answer saving or Next');
if(process.exitCode){console.error('\nStar reliability validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Central Star reliability and Difficult-toolbar contracts passed.');

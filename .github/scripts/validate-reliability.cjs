const fs=require('fs');
const path=require('path');
const vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script');
const read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`\n❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);

const server=['RobustLearningSave.gs','CentralFlags.gs','BankCoverage.gs','NewPracticeLive.gs','TopicPractice.gs','SourcePractice.gs','Demand.gs'];
const front=['SaveReliabilityUI.html','AppJS.html'];
[...server,...front].forEach(f=>fs.existsSync(path.join(root,f))?ok(`Reliability file present: ${f}`):fail(`Reliability file missing: ${f}`));
if(process.exitCode)process.exit(process.exitCode);
server.forEach(f=>{try{new vm.Script(read(f),{filename:f});ok(`Reliability server syntax: ${f}`)}catch(e){fail(`Server syntax failed in ${f}: ${e.message}`)}});
front.forEach(f=>{try{new vm.Script(read(f).replace(/<\/?script[^>]*>/gi,''),{filename:f});ok(`Reliability frontend syntax: ${f}`)}catch(e){fail(`Frontend syntax failed in ${f}: ${e.message}`)}});

const robust=read('RobustLearningSave.gs'),ui=read('SaveReliabilityUI.html'),flags=read('CentralFlags.gs'),bank=read('BankCoverage.gs'),np=read('NewPracticeLive.gs'),topic=read('TopicPractice.gs'),source=read('SourcePractice.gs'),demand=read('Demand.gs'),app=read('AppJS.html'),index=read('Index.html');
[
  ['function submitAnswerV3(','durable central answer endpoint'],
  ['function submitHinduAnswerV3(','durable Hindu answer endpoint'],
  ["tryLock(5000)",'short authoritative save lock'],
  ['SpreadsheetApp.flush()','Performance append flushed before lock release'],
  ['Attempt_ID:attemptId','stable Attempt_ID persisted'],
  ['answeredAtV3_','original answer timestamp preserved across retries'],
  ['durable:true','server explicitly confirms durable write'],
  ['function repairPendingLearningDerivationsV3(','derived-state self-healing'],
  ['function setMarkedFastV3(','lightweight central Mark update'],
  ["ix('Last_Marked')",'actual Last_Marked status column used'],
  ['function serveQuestionsCentralV3_(','central Star/Difficult serving helper']
].forEach(([n,l])=>need(robust,n,l));

[
  ["OUTBOX_KEY='ep-answer-outbox-v3'",'persistent local answer outbox'],
  ['submitAnswerV3','outbox targets durable answer endpoint'],
  ['submitHinduAnswerV3','outbox targets durable Hindu endpoint'],
  ['answeredAt','client captures answer time before retry'],
  ['attemptId','client persists stable Attempt_ID'],
  ['backoff(','automatic retry backoff'],
  ["window.addEventListener('online'",'retry resumes when connection returns'],
  ["fn==='logStarredRevisionFromUi'",'legacy duplicate Star log suppressed'],
  ['skippedLegacyDuplicate:true','duplicate Star suppression is explicit'],
  ['EPSaveReliability','outbox diagnostics exposed']
].forEach(([n,l])=>need(ui,n,l));
if(/nextBtn[^\n]{0,100}disabled/i.test(ui))fail('Reliability layer must never disable Next while saving');else ok('Next remains independent of background saving');

need(flags,'setMarkedFastV3','central Star path uses lightweight status write');
need(flags,'logStarredRevisionEvent_','central Star path still records one Star event');
need(bank,'bankCoverageSnapshotV3_','Bank Coverage builds one reusable snapshot');
if(/function getBankCoverageBatch[\s\S]*?getBankCoverageHub\(/.test(bank))fail('Bank Coverage batch must not rebuild the hub');else ok('Bank Coverage batch no longer rebuilds the hub');
need(np,'currentStarredMapV2_','New Practice reads central Star state');
need(np,'serveQuestionsCentralV3_','New Practice serves central flags');
need(topic,'serveQuestionsCentralV3_','Topic Practice serves central flags');
need(source,'currentStarredMapV2_','Source Practice random priority uses central Star state');
need(source,'serveQuestionsCentralV3_','Source Practice serves central flags');
need(demand,'currentStarredMapV2_','Demanded Practice random priority uses central Star state');
need(demand,'serveQuestionsCentralV3_','Demanded Practice serves central flags');
need(demand,'getHinduQuizV2','Hindu quiz starts with central Star/Difficult payload');
need(app,'getDailyBatchReliableV3','Daily receives central flags');
need(app,'getPracticeBatchCentralV3','generic Random/Weak/Due/Category/Source receives central flags');
need(app,'getNewPracticeBatchCentralV3','legacy New Practice fallback receives central flags');
need(index,"include('SaveReliabilityUI')",'reliability layer loaded in app');
if(index.lastIndexOf("include('SaveReliabilityUI')")<index.lastIndexOf("include('LearningLayoutCompat')"))fail('SaveReliabilityUI must load after compatibility wrappers');else ok('SaveReliabilityUI loads last among learning wrappers');

if(process.exitCode){console.error('\nAnswer-save reliability validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Answer-save reliability contracts passed.');

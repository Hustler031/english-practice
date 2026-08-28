const fs=require('fs');
const path=require('path');
const vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script');
const read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`\n❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
const assert=(v,m)=>v?ok(m):fail(m);
const count=(t,n)=>t.split(n).length-1;

const server=['LearningIntelligence.gs','BankCoverage.gs','DailyAdaptive.gs','LearningProgress.gs','MySavedRevision.gs','LearningHinduCompat.gs','CentralFlags.gs'];
const front=['FinalLearningUI.html','BankCoverageUX.html','LearningLayoutCompat.html','LearningCacheUX.html'];
[...server,...front].forEach(f=>fs.existsSync(path.join(root,f))?ok(`Learning file present: ${f}`):fail(`Learning file missing: ${f}`));
if(process.exitCode)process.exit(process.exitCode);
server.forEach(f=>{try{new vm.Script(read(f),{filename:f});ok(`Learning server syntax: ${f}`)}catch(e){fail(`Learning server syntax failed in ${f}: ${e.message}`)}});
front.forEach(f=>{try{new vm.Script(read(f).replace(/<\/?script[^>]*>/gi,''),{filename:f});ok(`Learning frontend syntax: ${f}`)}catch(e){fail(`Learning frontend syntax failed in ${f}: ${e.message}`)}});

const li=read('LearningIntelligence.gs'),bank=read('BankCoverage.gs'),daily=read('DailyAdaptive.gs'),progress=read('LearningProgress.gs'),saved=read('MySavedRevision.gs'),hcompat=read('LearningHinduCompat.gs'),flags=read('CentralFlags.gs'),ui=read('FinalLearningUI.html'),bankux=read('BankCoverageUX.html'),layout=read('LearningLayoutCompat.html'),cacheux=read('LearningCacheUX.html'),index=read('Index.html'),quiz=read('QuizJS.html'),star=read('StarredRevision.gs'),hindu=read('HinduUI.html'),dailyV2=read('DailyV2.gs');
[
  ['EP_RETENTION_GAP_MS=24*60*60*1000','base retention-day constant remains'],
  ['EP_MAX_ACTIVE_ANSWER_SECONDS=180','active timing capped at 180 seconds'],
  ["EP_PERFORMANCE_MODULE='Module'",'single Performance Module column'],
  ['function submitAnswerV2(','central answer logging'],
  ['function submitHinduAnswerV2(','central Hindu answer logging'],
  ['function setCentralDifficult(','central Difficult state'],
  ['function markMasteredV2(','retention-gated manual Mastered'],
  ['function learningStudyDayCheckpointsV3_(','one checkpoint per study day'],
  ['recentCheckpointWrong>=2','Persistent Weak uses recent checkpoint failures'],
  ['checkpointStreak>=3','Strong requires repeated study-day success'],
  ['provenMastery=checkpointStreak>=4&&lastGap>=5','Proven Mastered requires later spaced proof'],
  ["p.state==='Strong')return 7",'Strong cooldown is seven days'],
  ["p.state==='Proven Mastered')return 30",'Proven Mastered long recall interval is thirty days'],
  ['function learningDueV3_(','central due gate'],
  ['function reconcileLearningStatusV3_(','status is recomputed from Performance'],
  ["low.includes('fixed preposition')",'Fixed Preposition learning category'],
  ["low.includes('fields of study')",'Fields of Study learning category'],
  ['function getLearningDataAudit(','data-quality audit endpoint']
].forEach(([n,l])=>need(li,n,l));
need(li,'performanceAttemptExistsV2_','Attempt_ID duplicate protection');
assert(!li.includes('wrong>=3'),'lifetime wrong count no longer traps Persistent Weak');
assert(!li.includes('.deleteRow('),'learning reconciliation never structurally deletes spreadsheet rows');

['learningBankEligibleQuestionsV2_','facts.seen.has(id)','recommended=Math.max(0,Math.min(10,unseen))','function getBankCoverageBatch(category,count)','function getBankCoverageCategoryDetail(category)','function getBankCoverageTodayBatch(category,kind,count)','function getBankCoverageSeenBatch(category,count)','x.difficult=!!diff[q.id]','x.marked=!!stars[q.id]'].forEach(x=>need(bank,x,`Bank Coverage contract ${x}`));
if(bank.includes('appendRow')||bank.includes('EP.sheets.performance'))fail('Bank Coverage must not maintain a separate performance history');else ok('Bank Coverage uses central performance only');
['DETAIL_PREFIX=\'ep:bankCoverage:category:v1:\'','[10,20,50,100]','Attempted Today','Today’s Review','Last Session','getBankCoverageCategoryDetail','getBankCoverageTodayBatch','getBankCoverageSeenBatch','refreshes silently in background'].forEach(x=>need(bankux,x,`Bank Coverage category UX ${x}`));

['Persistent Weak','Weak','Fragile','Due Spaced Revision','Controlled New','learningCategoryKeyV2_','learningDueV3_','dailyBalancedSelectV5_','EP_DAILY_ROTATION_REFRESH_V5','targetIsMaximum'].forEach(x=>need(daily,x,`Adaptive Daily contract ${x}`));
assert(daily.includes("if(!reason)return"),'Daily excludes non-due/non-eligible questions instead of filling target blindly');
assert(daily.includes("const order=['Controlled New','Persistent Weak'"),'Controlled New receives protected first-pass capacity');
['firstAttemptAccuracy','afterReviewAccuracy','retentionAccuracy','weakConcepts','persistentWeakCount','masteredCount','learningCategoryKeyV2_'].forEach(x=>need(progress,x,`Progress metric ${x}`));
['currentStarredMapV2_','centralDifficultMapV2_','q.marked=!!x.starred','q.difficult=!!x.difficult','mySavedRevisionDaySummariesV2_','days:mySavedRevisionDaySummariesV2_'].forEach(x=>need(saved,x,`My Saved contract ${x}`));
need(saved,'learningProfilesV2_(facts)','My Saved reuses the central learning profile');
if(saved.includes('appendRow')||saved.includes('Starred_Revision_Difficult'))fail('My Saved must not create parallel Starred/Difficult storage');else ok('My Saved reuses central Starred/Difficult storage');

need(hcompat,'function getHinduPracticeProgressCentral(','Hindu central progress endpoint');
need(hcompat,"a.module==='hindu'",'Hindu progress uses central module attempts');
['function setMarkedCentralV3(','logStarredRevisionEvent_','function setHinduMarkedCentralV3('].forEach(x=>need(flags,x,`Central star synchronization ${x}`));
['attemptIdFor(','submitHinduAnswerV2','getHinduQuizV2','setCentralDifficult',"'bankCoverage'","'mySavedRevision'","'hindu'",'weakConcepts'].forEach(x=>need(ui,x,`Learning UI integration ${x}`));
['ep:bankCoverage:hub:v3','ep:mySavedRevision:hub:v3','stopImmediatePropagation','markLearningCachesDirty','openSavedFolds','localDateKey','bankCoverageQuick'].forEach(x=>need(cacheux,x,`Cache-first UX contract ${x}`));
if(cacheux.includes('finally(()=>{setTimeout(refreshBank')||cacheux.includes('finally(()=>{setTimeout(refreshSaved'))fail('Answer submission must not force immediate hub recalculation');else ok('Answer submission only dirties learning caches');
need(layout,"master.classList.add('hidden')",'Difficult-enabled quizzes reuse compact Mastered placement');
need(layout,'learning-difficult-row','Difficult-enabled quiz tools stay in one adaptive row');
need(layout,"title==='The Hindu – Today'",'Hindu legacy Mastered toolbar remains hidden when Difficult is absent');
need(layout,'setMarkedCentralV3','all-module Starred routing uses central synchronizer');
need(index,"include('FinalLearningUI')",'Final learning UI included');
need(index,"include('BankCoverageUX')",'Bank Coverage category UX included');
need(index,"include('LearningLayoutCompat')",'Learning layout compatibility included');
need(index,"include('LearningCacheUX')",'Learning cache UX included');
need(quiz,'if(q&&q.marked)state.marked[q.id]=true','quiz seeds central Starred state');
need(star,'served.marked=!!byId[q.id]?.starred','Starred Revision serves central Starred state');
need(hindu,'getHinduPracticeProgressCentral','Hindu UI reads central progress');
['function getBootstrapV2(','function getDailyBatchV2(','repairSkippedDailyDateV2_','archiveDailyV2_'].forEach(x=>need(dailyV2,x,`Existing Daily V2 preserved: ${x}`));

const allNew=server.map(read).join('\n');
[['function submitAnswerV2(',1],['function setCentralDifficult(',1],['function getLearningProgressSnapshot(',1],['function getBankCoverageHub(',1],['function getMySavedRevisionHub(',1],['function setMarkedCentralV3(',1]].forEach(([fn,n])=>count(allNew,fn)===n?ok(`Unique learning function: ${fn}`):fail(`Expected ${n} occurrence of ${fn}, found ${count(allNew,fn)}`));

// Behavioral regression suite for state recovery and spacing.
(function(){
  const ctx={console,Date,Math,Set,Object,String,Number,Array,Error,Map};
  ctx.dateKey_=d=>{d=new Date(d);if(isNaN(d))return '';const p=n=>String(n).padStart(2,'0');return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}`};
  vm.createContext(ctx);new vm.Script(li,{filename:'LearningIntelligence.gs'}).runInContext(ctx);
  const a=(day,correct,hour=9)=>({ts:new Date(2026,7,day,hour),correct,row:`${day}-${hour}`,attemptId:`${day}-${hour}`});
  let p=ctx.learningProfileV2_([a(1,false),a(2,false),a(3,false),a(4,true),a(5,true),a(6,true)]);
  assert(p.state==='Strong','three historical wrongs plus three study-day corrects recover to Strong');
  p=ctx.learningProfileV2_([a(1,true),a(2,false),a(3,true),a(4,false)]);
  assert(p.state==='Persistent Weak','repeated recent checkpoint failures ending wrong remain Persistent Weak');
  p=ctx.learningProfileV2_([a(1,true,9),a(1,true,12),a(1,true,18)]);
  assert(p.checkpointCount===1&&p.state==='Learning','same-day repeats produce only one retention checkpoint');
  p=ctx.learningProfileV2_([a(1,false,9),a(1,true,12)]);
  assert(p.state==='Weak'&&p.checkpointCount===1,'same-day correction is reinforcement, not spaced recovery');
  p=ctx.learningProfileV2_([a(1,true),a(2,true),a(3,true)]);
  assert(p.state==='Strong','three distinct-day correct checkpoints become Strong');
  assert(!ctx.learningDueV3_(p,'2026-08-04'),'Strong does not repeat the next day');
  assert(ctx.learningDueV3_(p,'2026-08-10'),'Strong returns when seven-day recall is due');
  p=ctx.learningProfileV2_([a(1,true),a(2,true),a(3,true),a(10,true)]);
  assert(p.state==='Proven Mastered'&&p.provenMastery,'later spaced fourth success becomes Proven Mastered');
  assert(!ctx.learningDueV3_(p,'2026-09-08'),'Proven Mastered stays out before long recall is due');
  assert(ctx.learningDueV3_(p,'2026-09-09'),'Proven Mastered returns on thirty-day recall');
})();

if(process.exitCode){console.error('\nFinal learning-system validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Final learning-system contract and behavioral validation passed.');

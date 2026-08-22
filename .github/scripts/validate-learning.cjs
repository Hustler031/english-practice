const fs=require('fs');
const path=require('path');
const vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script');
const read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`\n❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
const count=(t,n)=>t.split(n).length-1;

const server=['LearningIntelligence.gs','BankCoverage.gs','DailyAdaptive.gs','LearningProgress.gs','MySavedRevision.gs','LearningHinduCompat.gs','CentralFlags.gs'];
const front=['FinalLearningUI.html','BankCoverageUX.html','LearningLayoutCompat.html','LearningCacheUX.html'];
[...server,...front].forEach(f=>fs.existsSync(path.join(root,f))?ok(`Learning file present: ${f}`):fail(`Learning file missing: ${f}`));
if(process.exitCode)process.exit(process.exitCode);
server.forEach(f=>{try{new vm.Script(read(f),{filename:f});ok(`Learning server syntax: ${f}`)}catch(e){fail(`Learning server syntax failed in ${f}: ${e.message}`)}});
front.forEach(f=>{try{new vm.Script(read(f).replace(/<\/?script[^>]*>/gi,''),{filename:f});ok(`Learning frontend syntax: ${f}`)}catch(e){fail(`Learning frontend syntax failed in ${f}: ${e.message}`)}});

const li=read('LearningIntelligence.gs'),bank=read('BankCoverage.gs'),daily=read('DailyAdaptive.gs'),progress=read('LearningProgress.gs'),saved=read('MySavedRevision.gs'),hcompat=read('LearningHinduCompat.gs'),flags=read('CentralFlags.gs'),ui=read('FinalLearningUI.html'),bankux=read('BankCoverageUX.html'),layout=read('LearningLayoutCompat.html'),cacheux=read('LearningCacheUX.html'),index=read('Index.html'),quiz=read('QuizJS.html'),star=read('StarredRevision.gs'),hindu=read('HinduUI.html'),dailyV2=read('DailyV2.gs');
[
  ['EP_RETENTION_GAP_MS=24*60*60*1000','24-hour retention gap'],
  ['EP_MAX_ACTIVE_ANSWER_SECONDS=180','active timing capped at 180 seconds'],
  ["EP_PERFORMANCE_MODULE='Module'",'single Performance Module column'],
  ['function submitAnswerV2(','central answer logging'],
  ['function submitHinduAnswerV2(','central Hindu answer logging'],
  ['function setCentralDifficult(','central Difficult state'],
  ['function markMasteredV2(','retention-gated Mastered'],
  ["state='Persistent Weak'",'Persistent Weak state'],
  ["state='Fragile'",'Fragile state'],
  ["state='Strong'",'Strong state'],
  ["low.includes('fixed preposition')",'Fixed Preposition learning category'],
  ["low.includes('fields of study')",'Fields of Study learning category'],
  ['function getLearningDataAudit(','data-quality audit endpoint']
].forEach(([n,l])=>need(li,n,l));
need(li,'recentSpacedWrong>=2','Persistent Weak uses repeated spaced failures');
need(li,'retentionCorrect>=2','Mastery requires spaced correct recalls');
need(li,'performanceAttemptExistsV2_','Attempt_ID duplicate protection');

['learningBankEligibleQuestionsV2_','facts.seen.has(id)','recommended=Math.max(0,Math.min(10,unseen))','function getBankCoverageBatch(category,count)','function getBankCoverageCategoryDetail(category)','function getBankCoverageTodayBatch(category,kind,count)','function getBankCoverageSeenBatch(category,count)','x.difficult=!!diff[q.id]','x.marked=!!stars[q.id]'].forEach(x=>need(bank,x,`Bank Coverage contract ${x}`));
if(bank.includes('appendRow')||bank.includes('EP.sheets.performance'))fail('Bank Coverage must not maintain a separate performance history');else ok('Bank Coverage uses central performance only');
['DETAIL_PREFIX=\'ep:bankCoverage:category:v1:\'','[10,20,50,100]','Attempted Today','Today’s Review','Last Session','getBankCoverageCategoryDetail','getBankCoverageTodayBatch','getBankCoverageSeenBatch','refreshes silently in background'].forEach(x=>need(bankux,x,`Bank Coverage category UX ${x}`));

['Persistent Weak','Weak','Fragile','Due Spaced Revision','Controlled New','learningCategoryKeyV2_'].forEach(x=>need(daily,x,`Adaptive Daily contract ${x}`));
['firstAttemptAccuracy','afterReviewAccuracy','retentionAccuracy','weakConcepts','persistentWeakCount','masteredCount','learningCategoryKeyV2_'].forEach(x=>need(progress,x,`Progress metric ${x}`));
['currentStarredMapV2_','centralDifficultMapV2_','q.marked=!!x.starred','q.difficult=!!x.difficult','mySavedRevisionDaySummariesV2_','days:mySavedRevisionDaySummariesV2_'].forEach(x=>need(saved,x,`My Saved contract ${x}`));
if(saved.includes('appendRow')||saved.includes('Starred_Revision_Difficult'))fail('My Saved must not create parallel Starred/Difficult storage');else ok('My Saved reuses central Starred/Difficult storage');

need(hcompat,'function getHinduPracticeProgressCentral(','Hindu central progress endpoint');
need(hcompat,"a.module==='hindu'",'Hindu progress uses central module attempts');
['function setMarkedCentralV3(','logStarredRevisionEvent_','function setHinduMarkedCentralV3('].forEach(x=>need(flags,x,`Central star synchronization ${x}`));
['attemptIdFor(','submitHinduAnswerV2','getHinduQuizV2','setCentralDifficult',"'bankCoverage'","'mySavedRevision'","'hindu'",'weakConcepts'].forEach(x=>need(ui,x,`Learning UI integration ${x}`));
['ep:bankCoverage:hub:v3','ep:mySavedRevision:hub:v3','stopImmediatePropagation','markLearningCachesDirty','openSavedFolds','localDateKey','bankCoverageQuick'].forEach(x=>need(cacheux,x,`Cache-first UX contract ${x}`));
if(cacheux.includes('finally(()=>{setTimeout(refreshBank')||cacheux.includes('finally(()=>{setTimeout(refreshSaved'))fail('Answer submission must not force immediate hub recalculation');else ok('Answer submission only dirties learning caches');
need(layout,"title==='Starred Revision'",'Starred-only compact Mastered layout preserved');
need(layout,"title==='The Hindu – Today'",'Hindu legacy Mastered toolbar remains hidden');
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

if(process.exitCode){console.error('\nFinal learning-system validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Final learning-system contract validation passed.');

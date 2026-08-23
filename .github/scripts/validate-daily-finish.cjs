const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
for(const f of ['DailyFinishReliability.gs','DailyFinishBackgroundUI.html','Index.html','QuizJS.html','SaveReliabilityUI.html'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const server=read('DailyFinishReliability.gs'),ui=read('DailyFinishBackgroundUI.html'),index=read('Index.html'),quiz=read('QuizJS.html'),save=read('SaveReliabilityUI.html');
try{new vm.Script(server,{filename:'DailyFinishReliability.gs'});ok('Daily finish server syntax')}catch(e){fail(`Daily finish server syntax: ${e.message}`)}
try{new vm.Script(ui.replace(/<\/?script[^>]*>/gi,''),{filename:'DailyFinishBackgroundUI.html'});ok('Daily finish UI syntax')}catch(e){fail(`Daily finish UI syntax: ${e.message}`)}
[
  ['reconcileDailyCompletionV4','Server exposes explicit Daily completion reconciliation'],
  ['syncDailyCompletionsV3_','Reconciliation uses existing Performance-to-Daily completion logic'],
  ["String(a.module||'').toLowerCase()!=='daily'",'Batch-rollover verification accepts only Daily Performance attempts'],
  ['expectedIds','Reconciliation can verify the finished served subset after batch rollover'],
  ['batchAdvanced','Reconciliation reports batch rollover without fabricating a new attempt']
].forEach(([n,l])=>need(server,n,l));
if(server.includes('appendDurableAttemptV3_')||server.includes('perf.appendRow'))fail('Daily reconciliation must not fabricate Performance attempts');else ok('Daily reconciliation never fabricates attempts');
[
  ["FINISH_KEY='ep:daily-finish-pending:v1'",'Daily finish has a durable local pending marker'],
  ["finishPending:true",'Completed Daily session is retained as a safety net until confirmation'],
  ['pendingDailyItems','Finalizer waits on Daily outbox items'],
  ['prioritizeDailyOutbox','Pending Daily saves are prioritized without changing normal Next behavior'],
  ["EPQuiz.next=function()",'Only the terminal quiz navigation call is intercepted'],
  ["String($('nextBtn')?.textContent||'').trim()==='Finish'",'Background finalization applies only at Finish'],
  ['allServedAnswered','Finish cannot falsely complete an unanswered served Daily batch'],
  ["EPApp.showTab?.('home')",'Daily Finish returns to Home immediately'],
  ['Syncing final answers in the background','Home exposes sync-pending state'],
  ["EPApp.call('reconcileDailyCompletionV4'",'Client verifies server Daily completion after durable saves'],
  ["Number(res.remaining||0)===0",'Local Daily session clears only after server confirms zero remaining'],
  ["localStorage.removeItem(DAILY_KEY)",'Confirmed Daily completion clears its retained local session'],
  ["EPApp.startDirect=function(mode)",'Daily launch is guarded while final sync is pending'],
  ["String(mode)==='daily'&&state",'Pending finish blocks accidental re-serving of Daily questions'],
  ['disableHinduDifficult','Hindu has an explicit Difficult-removal guard'],
  ["==='The Hindu – Today'",'Difficult removal is scoped to the Hindu quiz only'],
  ["setDifficultQuizContext?.([],false)",'Hindu clears shared Difficult quiz context'],
  ["starredDifficultBtn",'Hindu Difficult button is forced hidden']
].forEach(([n,l])=>need(ui,n,l));
if(ui.includes('nextBtn.disabled'))fail('Background Daily finish must not disable/block Next');else ok('Normal Next remains non-blocking');
if(ui.includes('google.script.run'))fail('Daily finish UI must reuse EPApp transport');else ok('Daily finish UI reuses existing EPApp transport');
if(/\b120\b/.test(ui)||/\b120\b/.test(server))fail('Daily finish must not hard-code the 120 target');else ok('Daily target remains data-driven');
need(index,"<?!= include('DailyFinishBackgroundUI'); ?>",'Index loads Daily background finish layer');
if(index.indexOf("include('DailyFinishBackgroundUI')")>index.indexOf("include('DailySelectionWhyUI')"))ok('Daily finish layer loads after existing compatibility layers');else fail('Daily finish layer must load last among current quiz compatibility layers');
need(quiz,"EPApp.toast('Practice set completed.');",'Legacy generic Finish remains unchanged for non-Daily quizzes');
need(save,"const OUTBOX_KEY='ep-answer-outbox-v3'",'Existing durable answer outbox remains the save authority');
if(process.exitCode){console.error('\nDaily background finish validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Daily background finish + Hindu toolbar contracts passed.');

const fs=require('fs');
const path=require('path');
const vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script');
const read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing ${n}`);
const forbid=(t,n,l)=>!t.includes(n)?ok(l):fail(`${l} — forbidden ${n}`);
const syntaxServer=n=>{try{new vm.Script(read(n),{filename:n});ok(`Server syntax: ${n}`)}catch(e){fail(`Server syntax failed ${n}: ${e.message}`)}};
const syntaxUi=n=>{try{new vm.Script(read(n).replace(/<\/?script[^>]*>/gi,''),{filename:n});ok(`Frontend syntax: ${n}`)}catch(e){fail(`Frontend syntax failed ${n}: ${e.message}`)}};

const required=['SmartMySaved.gs','PhrasalMastery.gs','SmartMySavedUI.html','PhrasalMasteryUI.html','PhrasalQuizCompatUI.html','Index.html','NavigationPolishUI.html','QuizJS.html','SaveReliabilityUI.html','AnswerBatchV4.gs','StarredIntelligence.gs'];
required.forEach(n=>fs.existsSync(path.join(root,n))?ok(`File present: ${n}`):fail(`Missing file: ${n}`));
if(process.exitCode)process.exit(process.exitCode);
['SmartMySaved.gs','PhrasalMastery.gs'].forEach(syntaxServer);
['SmartMySavedUI.html','PhrasalMasteryUI.html','PhrasalQuizCompatUI.html','NavigationPolishUI.html'].forEach(syntaxUi);

const sms=read('SmartMySaved.gs'),pv=read('PhrasalMastery.gs'),smsui=read('SmartMySavedUI.html'),pvui=read('PhrasalMasteryUI.html'),compat=read('PhrasalQuizCompatUI.html'),index=read('Index.html'),nav=read('NavigationPolishUI.html'),quiz=read('QuizJS.html'),save=read('SaveReliabilityUI.html'),batch=read('AnswerBatchV4.gs'),star=read('StarredIntelligence.gs');

['mySavedRevisionItemsV2_','performanceFactsV2_','learningProfileV2_','currentStarredMapV2_','centralDifficultMapV2_','currentMasteredMapV2_','statusMap_','getSmartMySavedHubV1','getSmartMySavedBatchV1','getSmartMySavedAuditV1'].forEach(x=>need(sms,x,`Smart My Saved reuses central primitive ${x}`));
['Persistent Weak','Weak','Fragile','Due Recall','Difficult','Never Revised','Coverage Rotation'].forEach(x=>need(sms,x,`Smart My Saved priority includes ${x}`));
forbid(sms,'appendRow(','Smart My Saved does not write a second attempt system');
forbid(sms,'insertSheet','Smart My Saved creates no schema');
forbid(sms,'Daily_Quiz','Smart My Saved does not misuse Daily Quiz');

['phrasalConceptKeyV1_','performanceFactsV2_','learningProfileV2_','currentStarredMapV2_','centralDifficultMapV2_','currentMasteredMapV2_','PHRASAL_DAILY_','getPhrasalMasteryHubV1','getPhrasalMasteryBatchV1','getPhrasalTodayBatchV1','getPhrasalMasteryAuditV1'].forEach(x=>need(pv,x,`Phrasal mastery contract ${x}`));
['Persistent Weak','Weak','Fragile','Due Retention','Difficult + Starred','Never / Under-revised','Longest Not Seen'].forEach(x=>need(pv,x,`Phrasal central priority includes ${x}`));
need(pv,"groups[key]={conceptId:key,word:String(q.word||''),questions:[]}",'Phrasal selects at Concept_ID level');
need(pv,"EP_PHRASAL_MODULES=new Set(['phrasaldaily','phrasalrevision'])",'Phrasal history uses module tags in central Performance');
forbid(pv,'appendRow(','Phrasal selector does not create a second attempt writer');
forbid(pv,'insertSheet','Phrasal selector creates no schema');
forbid(pv,'Daily_Quiz','Phrasal Daily stays out of Daily_Quiz');

['Smart Revision','Weak','Difficult','Starred','Random','Practice All','Saved','Never Revised','Due','Mastered'].forEach(x=>need(smsui,x,`Smart My Saved UI contains ${x}`));
['10','20','30','50'].forEach(x=>need(smsui,`run(${x})`,`Smart My Saved size ${x}`));
need(smsui,"mode:'mySavedRevision'",'Smart My Saved uses existing My Saved session module');
need(smsui,'EPQuiz.replaceSavedFor','Smart My Saved uses proven replacement lifecycle');

['Smart Revision','Weak','Difficult','Starred','Random','Practice All',"Today's 15",'Phrasal Daily History','Bank Exposure','Due','Mastered'].forEach(x=>need(pvui,x,`Phrasal UI contains ${x}`));
['10','20','30','50'].forEach(x=>need(pvui,`run(${x})`,`Phrasal Smart size ${x}`));
need(pvui,"mode:'phrasalRevision'",'Phrasal Smart has a central Performance module tag');
need(pvui,"mode:'phrasalDaily'",'Phrasal Daily has a distinct central Performance module tag');
need(pvui,'EPQuiz.replaceSavedFor','Phrasal uses proven replacement lifecycle');

need(compat,"new Set(['phrasalRevision','phrasalDaily'])",'Phrasal Difficult compatibility covers both modes');
need(compat,'EPStarredRevision.setDifficultQuizContext','Phrasal reuses central Difficult UI/persistence');
forbid(compat,'setPhrasal','No Phrasal-specific difficult API');

['include(\'SmartMySavedUI\')','include(\'PhrasalMasteryUI\')','include(\'PhrasalQuizCompatUI\')'].forEach(x=>need(index,x,`Index wires ${x}`));
need(nav,'ensureOrder(grid,[hindu,saved,phrasal,starred,bank])','Quick Start order is Hindu → My Saved → Phrasal → Starred');
need(nav,"id='homeAddWordQuick'",'Tiny Add Word remains on Quick Start heading');
need(nav,'ui-quick-add-mini','Add Word is styled secondary/compact');
need(nav,'libraryPhrasalCard','Library contains Phrasal Verb entry');
need(nav,'EPMyWordsUX?.quickAdd?.()','Quick Add reuses existing Add Word flow');

need(quiz,"OTHER_KEY='ep-quiz-other-v4'",'Existing shared extra-practice session remains authoritative');
need(quiz,'beginSession()','Existing session generation guard remains');
need(quiz,'replaceSavedFor(mode)','Existing restart replacement remains');
need(quiz,"EPApp.call('submitAnswer'",'Existing quiz still submits through the normal call path');
need(save,"OUTBOX_KEY='ep-answer-outbox-v3'",'Existing answer outbox remains authoritative');
need(save,"submitAnswerBatchV4",'Existing batch durability endpoint remains authoritative');
need(save,"p.module=fn.indexOf('Hindu')>=0?'hindu':moduleForQuestion(id)",'New modes inherit module identity from current session');
need(batch,'Attempt_ID required','Batch requires stable Attempt_ID');
need(batch,'existing.has(x.attemptId)','Batch deduplicates Attempt_ID');
need(star,'getStarredIntelligenceBatch','Smart Starred implementation remains present and independent');

if(process.exitCode){console.error('\nSmart My Saved / Phrasal validation failed.');process.exit(process.exitCode)}
console.log('\n✅ Smart My Saved + Phrasal mastery contracts passed.');

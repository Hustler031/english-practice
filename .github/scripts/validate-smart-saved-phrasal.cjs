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
const stripUi=t=>t.replace(/<\/?script[^>]*>/gi,'');
const syntaxUi=n=>{try{new vm.Script(stripUi(read(n)),{filename:n});ok(`Frontend syntax: ${n}`)}catch(e){fail(`Frontend syntax failed ${n}: ${e.message}`)}};

const required=['SmartMySaved.gs','PhrasalMastery.gs','SmartMySavedUI.html','PhrasalMasteryUI.html','PhrasalQuizCompatUI.html','SavedUI.html','MyWordsFinalUI.html','Index.html','NavigationPolishUI.html','QuizJS.html','SaveReliabilityUI.html','AnswerBatchV4.gs','StarredIntelligence.gs','LearningIntelligence.gs'];
required.forEach(n=>fs.existsSync(path.join(root,n))?ok(`File present: ${n}`):fail(`Missing file: ${n}`));
if(process.exitCode)process.exit(process.exitCode);
['SmartMySaved.gs','PhrasalMastery.gs','LearningIntelligence.gs'].forEach(syntaxServer);
['SmartMySavedUI.html','PhrasalMasteryUI.html','PhrasalQuizCompatUI.html','SavedUI.html','MyWordsFinalUI.html','NavigationPolishUI.html'].forEach(syntaxUi);

const sms=read('SmartMySaved.gs'),pv=read('PhrasalMastery.gs'),smsui=read('SmartMySavedUI.html'),pvui=read('PhrasalMasteryUI.html'),compat=read('PhrasalQuizCompatUI.html'),savedui=read('SavedUI.html'),mywords=read('MyWordsFinalUI.html'),index=read('Index.html'),nav=read('NavigationPolishUI.html'),quiz=read('QuizJS.html'),save=read('SaveReliabilityUI.html'),batch=read('AnswerBatchV4.gs'),star=read('StarredIntelligence.gs'),learning=read('LearningIntelligence.gs');

['mySavedRevisionItemsV2_','performanceFactsV2_','learningProfileV2_','currentStarredMapV2_','centralDifficultMapV2_','currentMasteredMapV2_','statusMap_','getSmartMySavedHubV1','getSmartMySavedBatchV1','getSmartMySavedAuditV1'].forEach(x=>need(sms,x,`Smart My Saved reuses central primitive ${x}`));
['Persistent Weak','Weak','Fragile','Due Recall','Difficult','Never Revised','Coverage Rotation'].forEach(x=>need(sms,x,`Smart My Saved priority includes ${x}`));
forbid(sms,'appendRow(','Smart My Saved does not write a second attempt system');
forbid(sms,'insertSheet','Smart My Saved creates no schema');
forbid(sms,'Daily_Quiz','Smart My Saved does not misuse Daily Quiz');

['Smart Revision','Weak','Difficult','Starred','Random','Practice All','Saved','Never Revised','Due','Mastered'].forEach(x=>need(smsui,x,`Smart My Saved UI contains ${x}`));
['10','20','30','50'].forEach(x=>need(smsui,`run(${x})`,`Smart My Saved size ${x}`));
need(smsui,"mode:'mySavedRevision'",'Smart My Saved uses existing My Saved session module');
need(smsui,'EPQuiz.replaceSavedFor','Smart My Saved uses proven replacement lifecycle');
need(smsui,'EPApp.openSaved=open','Smart My Saved is the single authoritative EPApp.openSaved owner');
need(smsui,'install();','Smart My Saved route installs synchronously');
forbid(smsui,'setTimeout(install','Smart My Saved route is not timing-dependent');
forbid(savedui,'EPApp.openSaved=openSaved','Legacy Saved UI cannot steal the primary My Saved route');
need(savedui,"if(name==='saved'){EPApp.openSaved();return}",'Legacy saved tab alias forwards to Smart My Saved');
need(savedui,'openLegacySaved:openSaved','Legacy Saved tools remain available without owning primary navigation');
need(nav,'function openSaved(origin){savedOrigin=origin||\'revision\';EPApp.openSaved?.()}','Home/Revision polish route resolves through authoritative EPApp.openSaved');
need(index,'onclick="EPApp.openSaved()"','Revision Centre primary My Saved entry uses authoritative route');
need(smsui,'Manage Saved Words','Smart My Saved preserves word-management entry');
need(smsui,'EPMyWordsUX.open()','Manage Saved Words opens My Words manager');
need(mywords,'EPApp.openSaved()','Returning from My Words resolves back to Smart My Saved');
need(mywords,'quickAdd','Existing Add Word flow remains present');

function routeLoadRegression(){
  try{
    const listeners={},nodes={};
    const fakeNode=id=>({id:id||'',className:'',innerHTML:'',textContent:'',value:'',disabled:false,style:{},dataset:{},classList:{add(){},remove(){},toggle(){}},appendChild(n){if(n&&n.id)nodes[n.id]=n;return n},querySelector(){return null},querySelectorAll(){return[]},focus(){}});
    nodes.main=fakeNode('main');nodes.bottomNav=fakeNode('bottomNav');
    const document={getElementById:id=>nodes[id]||null,createElement:()=>fakeNode(''),addEventListener:(ev,fn)=>{(listeners[ev]||(listeners[ev]=[])).push(fn)},querySelectorAll:()=>[],head:fakeNode('head'),body:fakeNode('body')};
    const window={document,scrollTo(){},EPMySavedRevision:{}};
    const EPApp={showTab(){},call(){return Promise.resolve({})},toast(){}};
    const sandbox={window,document,EPApp,console,confirm:()=>true,setTimeout:fn=>{fn();return 1},clearTimeout(){},localStorage:{getItem(){return null},setItem(){},removeItem(){}}};window.window=window;window.EPApp=EPApp;vm.createContext(sandbox);
    vm.runInContext(stripUi(savedui),sandbox,{filename:'SavedUI.html'});
    vm.runInContext(stripUi(smsui),sandbox,{filename:'SmartMySavedUI.html'});
    if(!vm.runInContext('EPApp.openSaved===window.EPSmartMySaved.open',sandbox))throw new Error('Smart route is not authoritative immediately after load');
    (listeners.DOMContentLoaded||[]).forEach(fn=>fn());
    if(!vm.runInContext('EPApp.openSaved===window.EPSmartMySaved.open',sandbox))throw new Error('Legacy DOMContentLoaded handler stole Smart route');
    if(!vm.runInContext('EPSaved.openLegacySaved!==EPApp.openSaved',sandbox))throw new Error('Legacy Saved route still competes with Smart route');
    ok('Fresh-load My Saved route remains deterministic before and after DOMContentLoaded');
  }catch(e){fail('Fresh-load My Saved routing regression — '+e.message)}
}
routeLoadRegression();

['phrasalConceptKeyV1_','performanceFactsV2_','learningProfileV2_','currentStarredMapV2_','centralDifficultMapV2_','currentMasteredMapV2_','PHRASAL_DAILY_','getPhrasalMasteryHubV1','getPhrasalMasteryBatchV1','getPhrasalTodayBatchV1','getPhrasalHistoryBatchV1','getPhrasalMasteryAuditV1'].forEach(x=>need(pv,x,`Phrasal mastery contract ${x}`));
['Persistent Weak','Weak','Fragile','Due Retention','Difficult + Starred','Never / Under-revised','Longest Not Seen','Fresh Variant Check'].forEach(x=>need(pv,x,`Phrasal central priority includes ${x}`));
need(pv,"groups[key]={conceptId:key,word:String(q.word||''),questions:[]}",'Phrasal groups evidence at Concept_ID level');
need(pv,'phrasalConceptMasteredV1_(profile)','Phrasal concept mastery derives from aggregate central profile');
need(pv,"profile.provenMastery)&&String(profile&&profile.state||'')==='Strong'",'Concept mastery requires proven spaced mastery and Strong state');
need(pv,'freshVariants=activeVariants.filter','New permanent variants are detected without rewriting question mastery');
need(pv,'(!x.mastered||x.freshVariantCount>0)','A fresh variant can be checked without erasing concept mastery');
need(pv,"EP_PHRASAL_MODULES=new Set(['phrasaldaily','phrasalrevision'])",'Phrasal history uses module tags in central Performance');
need(pv,'phrasalHistoryOrderedV1_','Phrasal history resolves permanent daily batches');
need(pv,'phrasalHistoryScopeV1_','Phrasal history has reusable Day/Block/Month scope selector');
need(pv,'serveQuestionsCentralV3_','Historical questions receive central Starred/Difficult serving state');
need(pv,'!mastered[q.id]','Historical selector respects exact Question_ID Mastered exclusion');
forbid(pv,'appendRow(','Phrasal selector does not create a second attempt writer');
forbid(pv,'insertSheet','Phrasal selector creates no schema');
forbid(pv,'Daily_Quiz','Phrasal Daily/history stays out of Daily_Quiz');

function conceptIntelligenceRegression(){
  try{
    const ctx={console,Date,Set,Math};vm.createContext(ctx);vm.runInContext(learning,ctx,{filename:'LearningIntelligence.gs'});vm.runInContext(pv,ctx,{filename:'PhrasalMastery.gs'});
    const mastered=vm.runInContext("phrasalConceptMasteredV1_(learningProfileV2_([{id:'PV_A',ts:new Date('2026-01-01T00:00:00Z'),correct:true},{id:'PV_B',ts:new Date('2026-01-03T00:00:00Z'),correct:true},{id:'PV_A',ts:new Date('2026-01-05T00:00:00Z'),correct:true}]))",ctx);
    if(!mastered)throw new Error('aggregate multi-Question_ID spaced evidence did not master concept');
    const freshStillMastered=vm.runInContext("phrasalConceptMasteredV1_(learningProfileV2_([{id:'PV_A',ts:new Date('2026-01-01T00:00:00Z'),correct:true},{id:'PV_B',ts:new Date('2026-01-03T00:00:00Z'),correct:true},{id:'PV_A',ts:new Date('2026-01-05T00:00:00Z'),correct:true}]))",ctx);
    if(!freshStillMastered)throw new Error('adding an unattempted variant would erase concept mastery');
    const reopened=vm.runInContext("phrasalConceptMasteredV1_(learningProfileV2_([{id:'PV_A',ts:new Date('2026-01-01T00:00:00Z'),correct:true},{id:'PV_B',ts:new Date('2026-01-03T00:00:00Z'),correct:true},{id:'PV_A',ts:new Date('2026-01-05T00:00:00Z'),correct:true},{id:'PV_C',ts:new Date('2026-01-07T00:00:00Z'),correct:false}]))",ctx);
    if(reopened)throw new Error('later spaced wrong evidence did not weaken/reopen concept');
    const immediateRetry=vm.runInContext("phrasalConceptMasteredV1_(learningProfileV2_([{id:'PV_A',ts:new Date('2026-01-01T00:00:00Z'),correct:true},{id:'PV_B',ts:new Date('2026-01-01T01:00:00Z'),correct:true},{id:'PV_C',ts:new Date('2026-01-01T02:00:00Z'),correct:true}]))",ctx);
    if(immediateRetry)throw new Error('immediate retries incorrectly counted as retention mastery');
    ok('Concept_ID mastery uses aggregate spaced evidence, survives fresh insertion, and reopens on later wrong evidence');
  }catch(e){fail('Concept intelligence regression — '+e.message)}
}
conceptIntelligenceRegression();

function historyScopeRegression(){
  try{
    const ctx={console,Date,Set,Math};vm.createContext(ctx);vm.runInContext(pv,ctx,{filename:'PhrasalMastery.gs'});
    ctx.ordered=Array.from({length:35},(_,i)=>({day:i+1,questions:[{id:`PV${String(i+1).padStart(4,'0')}`,conceptId:`C${i+1}`}]}));
    const day=vm.runInContext('phrasalHistoryScopeV1_(ordered,1,1)',ctx),block=vm.runInContext('phrasalHistoryScopeV1_(ordered,1,10)',ctx),month=vm.runInContext('phrasalHistoryScopeV1_(ordered,1,30)',ctx);
    if(day.length!==1||day[0].id!=='PV0001')throw new Error('Day 1 scope incorrect');
    if(block.length!==10||block[9].id!=='PV0010')throw new Error('Days 1–10 scope incorrect');
    if(month.length!==30||month[29].id!=='PV0030')throw new Error('Month 1 scope incorrect');
    ok('Phrasal history Day, 10-day block, and Month scope selection preserves permanent Question_IDs');
  }catch(e){fail('Phrasal history scope regression — '+e.message)}
}
historyScopeRegression();

['Smart Revision','Weak','Difficult','Starred','Random','Practice All',"Today's 15",'Phrasal Daily History','Bank Exposure','Due','Mastered'].forEach(x=>need(pvui,x,`Phrasal UI contains ${x}`));
['10','20','30','50'].forEach(x=>need(pvui,`run(${x})`,`Phrasal Smart size ${x}`));
need(pvui,'startHistory','Phrasal history entries can launch practice');
need(pvui,"EPApp.call('getPhrasalHistoryBatchV1'",'Phrasal history uses permanent history selector endpoint');
need(pvui,"mode:'phrasalRevision'",'Phrasal Smart/history has central Performance module tag');
need(pvui,"mode:'phrasalDaily'",'Phrasal Daily has a distinct central Performance module tag');
need(pvui,"returnTab:'phrasalMastery'",'Historical quiz Back/Finish returns to Phrasal history');
need(pvui,'prepareRevisionSession','Phrasal Smart/history share one safe replacement lifecycle');
need(pvui,'EPQuiz.replaceSavedFor','Phrasal uses proven replacement lifecycle');

need(compat,"new Set(['phrasalRevision','phrasalDaily'])",'Phrasal Difficult compatibility covers both modes');
need(compat,'EPStarredRevision.setDifficultQuizContext','Phrasal reuses central Difficult UI/persistence');
need(compat,"name==='phrasalMastery'",'Phrasal history return route is isolated in compatibility layer');
need(compat,'EPPhrasalMastery?.open?.()','Phrasal history route reopens the existing mastery/history screen');
forbid(compat,'setPhrasal','No Phrasal-specific difficult API');

['at least three plausible competing distractors','put off / put out / put up / put through','look for / look after / look into / look over','call off / call in / call out / call for','set aside / put aside / set out / set off','get across / get over / get through / get by','uniquely defensible','artificial ambiguity'].forEach(x=>need(pv,x,`Future Phrasal Daily content contract includes ${x}`));

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
need(save,'submitAnswerBatchV4','Existing batch durability endpoint remains authoritative');
need(save,"p.module=fn.indexOf('Hindu')>=0?'hindu':moduleForQuestion(id)",'New modes inherit module identity from current session');
need(batch,'Attempt_ID required','Batch requires stable Attempt_ID');
need(batch,'existing.has(x.attemptId)','Batch deduplicates Attempt_ID');
need(star,'getStarredIntelligenceBatch','Smart Starred implementation remains present and independent');

if(process.exitCode){console.error('\nSmart My Saved / Phrasal audit-fix validation failed.');process.exit(process.exitCode)}
console.log('\n✅ Smart My Saved + Phrasal audit-fix behavioural contracts passed.');
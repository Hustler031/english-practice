const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`),assert=(v,m)=>v?ok(m):fail(m);
for(const f of ['StarredIntelligence.gs','StarredIntelligenceOptimization.gs','StarredIntelligenceUI.html','StarredRevisionUI.html','QuizJS.html','LearningIntelligence.gs','LearningLayoutCompat.html','SaveReliabilityUI.html','Index.html'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const server=read('StarredIntelligence.gs'),opt=read('StarredIntelligenceOptimization.gs'),ui=read('StarredIntelligenceUI.html'),legacyUi=read('StarredRevisionUI.html'),quiz=read('QuizJS.html'),learning=read('LearningIntelligence.gs'),starReliability=read('LearningLayoutCompat.html'),save=read('SaveReliabilityUI.html'),index=read('Index.html');
try{new vm.Script(server,{filename:'StarredIntelligence.gs'});ok('Starred Intelligence server syntax')}catch(e){fail(`StarredIntelligence.gs syntax: ${e.message}`)}
try{new vm.Script(opt,{filename:'StarredIntelligenceOptimization.gs'});ok('Starred Intelligence optimization syntax')}catch(e){fail(`StarredIntelligenceOptimization.gs syntax: ${e.message}`)}
try{new vm.Script(ui.replace(/<\/?script[^>]*>/gi,''),{filename:'StarredIntelligenceUI.html'});ok('Starred Intelligence UI syntax')}catch(e){fail(`StarredIntelligenceUI.html syntax: ${e.message}`)}
try{new vm.Script(quiz.replace(/<\/?script[^>]*>/gi,''),{filename:'QuizJS.html'});ok('Quiz lifecycle syntax')}catch(e){fail(`QuizJS.html syntax: ${e.message}`)}

// Central state and due authority.
[
  ['currentStarredMapV2_()','selector reads authoritative Central Star state'],
  ['currentMasteredMapV2_()','selector reads authoritative Central Mastered state'],
  ['learningProfileV2_(attempts)','selector reuses central learning profile'],
  ['learningDueV3_(profile,today)','Starred Smart due state reuses central learning due clock'],
  ["!stars[id]||!isActive_(q)||mastered[id]",'Star + Active + non-Mastered gate is applied before ranking'],
  ['starredIntelligenceApplyScopeV1_','Starred scope is applied before ranking'],
  ["String(a.module||'').toLowerCase()===EP_STARRED_INTELLIGENCE_MODULE.toLowerCase()",'Starred coverage uses only Starred Revision attempts'],
  ['starAttempts.length===0','Not Revised means zero genuine Starred Revision attempts'],
  ['starredIntelligenceDifficultMapV1_','Smart ranking reads existing Difficult state'],
  ["if(x.due&&s==='Persistent Weak')return 7",'Persistent Weak receives automatic urgency only when centrally due'],
  ["if(x.due&&s==='Weak')return 6",'Weak receives automatic urgency only when centrally due'],
  ["if(x.due&&s==='Fragile')return 5",'Fragile receives automatic urgency only when centrally due'],
  ['dueWeak','recommendation health distinguishes due weakness from historical weakness']
].forEach(([n,l])=>need(server,n,l));
need(opt,"!q||!stars[id]||!isActive_(q)||mastered[id]",'prepared Start revalidates Star / Active / non-Mastered eligibility');
need(opt,"m==='difficult'&&!diff[id]",'prepared Difficult Start revalidates manual Difficult state');
need(opt,'out.marked=true','prepared Smart questions remain current Starred');
need(opt,'out.difficult=!!difficultNow','prepared Smart questions seed current Difficult state');

// Recommendation generation remains read-only and isolated from Daily generation.
for(const text of [server,opt])for(const bad of ['.setValue(','.setValues(','.appendRow(','.clearContent(','.insertSheet(','PropertiesService','markDaily_(','ensureDailyAdaptiveV3_(','createDailyAdaptiveV3_(','sheet_(EP.sheets.daily)','Daily_Quiz'])if(text.includes(bad))fail(`Starred Intelligence must remain read-only / Daily-isolated — found ${bad}`);else ok(`No forbidden write/Daily coupling: ${bad}`);
assert(!/setMarkedCentral|setHinduMarkedCentral|setStarredRevisionDifficult\s*\(/.test(server+opt),'server layer introduces no parallel Star/Difficult saving path');
assert(!/Mastered_Log|Question_Status|Starred_Revision_Log\s*=|Starred_Revision_Difficult\s*=/.test(server+opt),'Smart layer introduces no parallel persisted learning state');

// Manual user-selected modes intentionally remain overrides of automatic due scheduling.
need(legacyUi,'Practice All','existing Practice All remains available');
need(server,"m==='weak'",'explicit Weak mode remains available');
need(server,"m==='difficult'",'explicit Difficult mode remains available');
need(server,"m==='longest'",'explicit Longest Not Revised mode remains available');
need(server,"m==='due'",'explicit Due mode remains available');
need(ui,"EPQuiz.start(qs,{mode:'starredRevision'",'Smart sessions reuse existing quiz engine');
need(ui,'EPQuiz.resumeOther()','Smart sessions reuse existing resume engine');
need(save,'emitDurableAck(item,res)','durable Answer acknowledgement remains authoritative');
need(starReliability,"OUTBOX_KEY='ep-star-outbox-v4'",'durable Star outbox remains intact');
need(legacyUi,'setStarredRevisionDifficult','existing Difficult toggle remains authoritative');

// Existing restart/cooldown/snapshot protections are preserved.
['sessionGeneration:0,live:false','function isLiveGeneration(generation)','if(!isLiveGeneration(generation))return','function invalidateCurrentGeneration()','function completeCurrentSaved(){invalidateCurrentGeneration();','if(!state.live||!state.questions.length)return'].forEach(x=>need(quiz,x,`Quiz lifecycle guard ${x}`));
need(opt,'EP_STARRED_INTELLIGENCE_COOLDOWN_MS_V2=24*60*60*1000','24-hour Starred Smart anti-repeat cooldown remains');
need(opt,'const fresh=rows.filter(x=>!x.recentStarredCooldown),recent=rows.filter(x=>x.recentStarredCooldown)','Smart selector prefers non-cooldown questions');
need(opt,'EP_STARRED_INTELLIGENCE_SIZES_V2.forEach','10/20/30/50 plans remain precomputed');
need(opt,'smartBySize','snapshot exposes precomputed size plans');
need(ui,"EPApp.call('getStarredIntelligenceSnapshotV2',scope)",'UI loads one Smart snapshot');
need(ui,"EPApp.call('getStarredIntelligencePreparedBatchV2'",'Start uses lightweight prepared-batch verification');
need(ui,'if(res?.needsRefresh&&retry)','Start refreshes safely when eligibility changed');
need(ui,"const pending=Number(window.EPSaveReliability?.pending?.()||0)",'session summary waits for durable saves');
need(ui,'requestSeq=0','latest-request-wins race protection remains');
need(ui,'if(seq!==requestSeq)return null','stale Smart snapshot responses are rejected');
need(index,"include('StarredIntelligenceUI')",'Starred Intelligence UI remains included');

// Behavioral ranking checks: automatic Smart is due-aware; explicit modes remain overrides.
const ctx={console,Date,Math,Set,Object,String,Number,Array,Error};vm.createContext(ctx);new vm.Script(server+'\n'+opt).runInContext(ctx);
const now=Date.now(),day=86400000;
const row=(id,state,days,extra={})=>Object.assign({id,profile:{state},due:false,difficult:false,neverRevised:false,lastStarred:days==null?null:new Date(now-days*day),daysSinceStarred:days,recentStarredCooldown:false},extra);
assert(ctx.starredIntelligenceLearningTierV1_(row('PW-NOT-DUE','Persistent Weak',2))===1,'non-due Persistent Weak does not receive automatic weak urgency');
assert(ctx.starredIntelligenceLearningTierV1_(row('PW-DUE','Persistent Weak',2,{due:true}))===7,'due Persistent Weak receives highest automatic urgency');
assert(ctx.starredIntelligenceLearningTierV1_(row('W-DUE','Weak',2,{due:true}))===6,'due Weak receives automatic urgency');
assert(ctx.starredIntelligenceLearningTierV1_(row('F-DUE','Fragile',2,{due:true}))===5,'due Fragile receives automatic urgency');
const due=ctx.starredIntelligenceSelectV2_([row('D1','Strong',5,{due:true}),row('D0','Persistent Weak',1,{due:false})],'due',10);
assert(due.length===1&&due[0].id==='D1','Due Now includes only centrally due Starred questions');
const weak=ctx.starredIntelligenceSelectV2_([row('W0','Weak',1,{due:false}),row('S','Strong',1)],'weak',10);
assert(weak.length===1&&weak[0].id==='W0','explicit Weak Focus remains a deliberate manual cooldown override');
const diff=ctx.starredIntelligenceSelectV2_([row('M','Strong',5,{difficult:true}),row('N','Persistent Weak',5,{difficult:false})],'difficult',10);
assert(diff.length===1&&diff[0].id==='M','Difficult mode remains manual Difficult only');
const recent=Array.from({length:10},(_,i)=>row('REC'+i,'Weak',0,{due:true,recentStarredCooldown:true}));
const fresh=Array.from({length:10},(_,i)=>row('ALT'+i,'Strong',10+i));
const smart=ctx.starredIntelligenceSmartSelectV2_(recent.concat(fresh),10);
assert(smart.length===10&&smart.every(x=>x.id.startsWith('ALT')),'Smart anti-repeat cooldown prefers fresh alternatives even over recently completed due weakness');
const rotation=ctx.starredIntelligenceSelectV2_([row('RECENT','Strong',0,{recentStarredCooldown:true}),row('OLD','Strong',15),row('NEVER','Strong',null,{neverRevised:true})],'longest',3);
assert(rotation.map(x=>x.id).join(',')==='NEVER,OLD,RECENT','Longest Not Revised rotation remains Never → old → recent');

if(process.exitCode){console.error('\nStarred Intelligence validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Starred Intelligence central-due, cooldown, isolation, lifecycle and manual-override contracts passed.');

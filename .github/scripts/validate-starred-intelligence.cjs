const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`),assert=(v,m)=>v?ok(m):fail(m);
for(const f of ['StarredIntelligence.gs','StarredIntelligenceUI.html','StarredRevisionUI.html','LearningIntelligence.gs','LearningLayoutCompat.html','SaveReliabilityUI.html','Index.html'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const server=read('StarredIntelligence.gs'),ui=read('StarredIntelligenceUI.html'),legacyUi=read('StarredRevisionUI.html'),learning=read('LearningIntelligence.gs'),starReliability=read('LearningLayoutCompat.html'),save=read('SaveReliabilityUI.html'),index=read('Index.html');
try{new vm.Script(server,{filename:'StarredIntelligence.gs'});ok('Starred Intelligence server syntax')}catch(e){fail(`StarredIntelligence.gs syntax: ${e.message}`)}
try{new vm.Script(ui.replace(/<\/?script[^>]*>/gi,''),{filename:'StarredIntelligenceUI.html'});ok('Starred Intelligence UI syntax')}catch(e){fail(`StarredIntelligenceUI.html syntax: ${e.message}`)}

// Strict eligibility and central-state reuse.
[
  ['currentStarredMapV2_()','selector reads authoritative Central Star state'],
  ['currentMasteredMapV2_()','selector reads authoritative Central Mastered state'],
  ['learningProfileV2_(attempts)','selector reuses central learning profile instead of defining a second engine'],
  ["!stars[id]||!isActive_(q)||mastered[id]",'Star + Active + non-Mastered gate is applied before ranking'],
  ['starredIntelligenceApplyScopeV1_','Starred Day/Block/Month scope has a dedicated pre-ranking gate'],
  ["String(a.module||'').toLowerCase()===EP_STARRED_INTELLIGENCE_MODULE.toLowerCase()",'Starred coverage is derived only from Module = starredRevision attempts'],
  ['starAttempts.length===0','Not Revised means zero genuine Starred Revision attempts'],
  ['status[id]&&status[id].nextReview','Due Now reads the existing central Next_Review clock'],
  ['starredIntelligenceDifficultMapV1_','Smart ranking reads the existing Difficult state'],
  ["q.marked=true",'served Smart questions are seeded as current Starred'],
  ['q.difficult=!!x.difficult','served Smart questions are seeded from existing Difficult state']
].forEach(([n,l])=>need(server,n,l));

// Read-only recommendation generation: no spreadsheet/state writes and no Daily coupling.
for(const bad of ['.setValue(','.setValues(','.appendRow(','.clearContent(','.insertSheet(','PropertiesService','markDaily_(','ensureDailyAdaptiveV3_(','createDailyAdaptiveV3_(','ensureDailyV2_(','createDailyV2_(','sheet_(EP.sheets.daily)','Daily_Quiz'])if(server.includes(bad))fail(`Starred Intelligence recommendation layer must be read-only / Daily-isolated — found ${bad}`);else ok(`No forbidden write/Daily coupling: ${bad}`);
assert(!/setMarkedCentral|setHinduMarkedCentral|setStarredRevisionDifficult\s*\(/.test(server+ui),'Smart layer introduces no parallel Star or Difficult saving path');
assert(!/Mastered_Log|Question_Status|Starred_Revision_Log\s*=|Starred_Revision_Difficult\s*=/.test(server),'Smart layer introduces no new persisted state definition');

// Existing Practice All / hierarchy remains untouched; Smart entry is additive only at top summary.
need(legacyUi,"EPStarredRevision.start(${json},\"all\",0)",'existing Practice All path remains present');
need(legacyUi,'Practice All','existing Practice All control remains unchanged');
need(ui,"document.querySelector('#starredRevisionBody > .sr-summary')",'Smart Revision entry is injected only into All Starred summary');
need(ui,"b.textContent='🧠 Smart Revision'",'new top-level Smart Revision button exists');
assert(!ui.includes('sr-group-panel')&&!ui.includes('sr-day-panel'),'Smart UI does not inject Smart Revision into Day/Block/Month action grids');

// Existing quiz/save engine reuse and module history contract.
need(ui,"EPQuiz.start(qs,{mode:'starredRevision'",'Smart session reuses existing quiz engine with Module route starredRevision');
need(ui,"smartStarred:true",'Smart metadata is additive to existing starredRevision mode');
need(ui,"EPQuiz.resumeOther()",'Smart Starred sessions use existing resume engine');
need(ui,"EPQuiz.hasSavedSessionFor('starredRevision')",'Smart launch respects existing shared paused-session contract');
need(save,'p.module=fn.indexOf(\'Hindu\')>=0?\'hindu\':moduleForQuestion(id)','answer outbox still derives module from existing quiz session');
need(save,"if(m)return m",'saved quiz mode remains authoritative for Performance Module');
need(starReliability,"OUTBOX_KEY='ep-star-outbox-v4'",'existing durable Star outbox remains intact');
need(starReliability,'overlayPending','existing pending Star overlay remains intact');
need(legacyUi,'setStarredRevisionDifficult','existing Difficult toggle remains authoritative');

// UI requirements.
for(const text of ['Recommended Now','Starred Coverage','Learning Health','Smart Practice','Not Revised','Due Now','Weak Focus','Difficult','Longest Not Revised','Rotation Health','Day-wise Intelligence / Scope','Today\'s Recommendation'])need(ui,text,`UI contains ${text}`);
need(ui,'<details class="si-card si-health">','Learning Health is collapsible and collapsed by default');
need(ui,'[10,20,30,50]','Smart batch sizes are 10 / 20 / 30 / 50');
need(ui,'smartStarredReason','question-level Smart selection reason is preserved in quiz payload/session');
need(ui,'Session Complete','Smart session summary exists');

// Pure selector behavior tests: rotation must not be starved by a permanent weak queue.
const ctx={console,Date,Math,Set,Object,String,Number,Array,Error};vm.createContext(ctx);new vm.Script(server).runInContext(ctx);
const now=Date.now(),day=86400000;
const row=(id,state,days,extra={})=>Object.assign({id,profile:{state},due:false,difficult:false,neverRevised:false,lastStarred:new Date(now-days*day),daysSinceStarred:days},extra);
const mixed=[...Array.from({length:8},(_,i)=>row('W'+i,i<4?'Persistent Weak':'Weak',1)),row('OLD_STRONG','Strong',20),row('NEVER_STRONG','Strong',0,{neverRevised:true,lastStarred:null,daysSinceStarred:null})];
const smart=ctx.starredIntelligenceSmartSelectV1_(mixed,10);
assert(smart.length===10,'Smart Mix returns requested eligible count');
assert(smart.some(x=>x.selectionLane==='learning'),'Smart Mix contains learning-priority lane');
assert(smart.some(x=>x.selectionLane==='rotation'),'Smart Mix reserves coverage-rotation lane');
assert(smart.some(x=>x.id==='OLD_STRONG'),'old Strong Starred item cannot be permanently starved by Weak items');
assert(smart.some(x=>x.id==='NEVER_STRONG'),'Never Revised Starred item receives rotation exposure');
const rotation=ctx.starredIntelligenceSelectV1_([row('RECENT','Strong',2),row('OLD','Strong',15),row('NEVER','Strong',0,{neverRevised:true,lastStarred:null,daysSinceStarred:null})],'longest',3);
assert(rotation.map(x=>x.id).join(',')==='NEVER,OLD,RECENT','Longest Not Revised orders Never Revised → oldest → recent');
const nr=ctx.starredIntelligenceSelectV1_([row('A','Weak',1),row('B','Strong',0,{neverRevised:true,lastStarred:null,daysSinceStarred:null})],'notRevised',10);
assert(nr.length===1&&nr[0].id==='B','Not Revised mode ignores central state and uses Starred-module exposure only');
const weak=ctx.starredIntelligenceSelectV1_([row('PW','Persistent Weak',1),row('W','Weak',1),row('F','Fragile',1),row('S','Strong',30)],'weak',10);
assert(weak.map(x=>x.id).join(',')==='PW,W,F','Weak Focus includes only Persistent Weak / Weak / Fragile in priority order');
const due=ctx.starredIntelligenceSelectV1_([row('D1','Strong',5,{due:true}),row('D0','Persistent Weak',1,{due:false})],'due',10);
assert(due.length===1&&due[0].id==='D1','Due Now includes only centrally due Starred questions');
const diff=ctx.starredIntelligenceSelectV1_([row('M','Strong',5,{difficult:true}),row('N','Persistent Weak',5,{difficult:false})],'difficult',10);
assert(diff.length===1&&diff[0].id==='M','Difficult mode eligibility remains manual Difficult only');
const scoped=ctx.starredIntelligenceApplyScopeV1_([{id:'D5',day:5},{id:'D8',day:8}],{fromDay:5,toDay:5});
assert(scoped.length===1&&scoped[0].id==='D5','scope filtering excludes Starred questions outside requested Day/Block/Month before ranking');

// New global function names must not collide with existing server files.
const newFns=[...server.matchAll(/function\s+([A-Za-z0-9_]+)\s*\(/g)].map(m=>m[1]),others=fs.readdirSync(root).filter(f=>f.endsWith('.gs')&&f!=='StarredIntelligence.gs').map(read).join('\n');
for(const fn of newFns)assert(!new RegExp(`function\\s+${fn.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}\\s*\\(`).test(others),`no duplicate global function: ${fn}`);

need(index,"include('StarredIntelligenceUI')",'Starred Intelligence UI is included');
assert(index.indexOf("include('StarredIntelligenceUI')")>index.indexOf("include('ModuleSyncUI')"),'Starred Intelligence integration loads last and wraps only finalized existing behavior');
if(process.exitCode){console.error('\nStarred Intelligence validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Starred Intelligence isolation, rotation, eligibility, save-routing and UI contracts passed.');

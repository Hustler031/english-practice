const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`),assert=(v,m)=>v?ok(m):fail(m);
for(const f of ['StarredIntelligence.gs','StarredIntelligenceOptimization.gs','StarredIntelligenceUI.html','StarredRevisionUI.html','QuizJS.html','LearningIntelligence.gs','LearningLayoutCompat.html','SaveReliabilityUI.html','Index.html'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const server=read('StarredIntelligence.gs'),opt=read('StarredIntelligenceOptimization.gs'),ui=read('StarredIntelligenceUI.html'),legacyUi=read('StarredRevisionUI.html'),quiz=read('QuizJS.html'),learning=read('LearningIntelligence.gs'),starReliability=read('LearningLayoutCompat.html'),save=read('SaveReliabilityUI.html'),index=read('Index.html');
try{new vm.Script(server,{filename:'StarredIntelligence.gs'});ok('Starred Intelligence V1 server syntax')}catch(e){fail(`StarredIntelligence.gs syntax: ${e.message}`)}
try{new vm.Script(opt,{filename:'StarredIntelligenceOptimization.gs'});ok('Starred Intelligence V2 optimization syntax')}catch(e){fail(`StarredIntelligenceOptimization.gs syntax: ${e.message}`)}
try{new vm.Script(ui.replace(/<\/?script[^>]*>/gi,''),{filename:'StarredIntelligenceUI.html'});ok('Starred Intelligence UI syntax')}catch(e){fail(`StarredIntelligenceUI.html syntax: ${e.message}`)}
try{new vm.Script(quiz.replace(/<\/?script[^>]*>/gi,''),{filename:'QuizJS.html'});ok('Quiz lifecycle syntax')}catch(e){fail(`QuizJS.html syntax: ${e.message}`)}

// Strict eligibility and central-state reuse remain authoritative.
[
  ['currentStarredMapV2_()','selector reads authoritative Central Star state'],
  ['currentMasteredMapV2_()','selector reads authoritative Central Mastered state'],
  ['learningProfileV2_(attempts)','selector reuses central learning profile instead of defining a second engine'],
  ["!stars[id]||!isActive_(q)||mastered[id]",'Star + Active + non-Mastered gate is applied before ranking'],
  ['starredIntelligenceApplyScopeV1_','Starred Day/Block/Month scope is applied before ranking'],
  ["String(a.module||'').toLowerCase()===EP_STARRED_INTELLIGENCE_MODULE.toLowerCase()",'Starred coverage is derived only from Module = starredRevision attempts'],
  ['starAttempts.length===0','Not Revised means zero genuine Starred Revision attempts'],
  ['status[id]&&status[id].nextReview','Due Now reads the existing central Next_Review clock'],
  ['starredIntelligenceDifficultMapV1_','Smart ranking reads the existing Difficult state']
].forEach(([n,l])=>need(server,n,l));
need(opt,"!q||!stars[id]||!isActive_(q)||mastered[id]",'prepared Start revalidates current Star / Active / non-Mastered eligibility');
need(opt,"eventDay<sc.fromDay||eventDay>sc.toDay",'prepared Start revalidates requested Starred scope');
need(opt,"m==='difficult'&&!diff[id]",'prepared Difficult Start revalidates current manual Difficult state');
need(opt,'out.marked=true','prepared Smart questions remain seeded as current Starred');
need(opt,'out.difficult=!!difficultNow','prepared Smart questions seed current Difficult state');

// V1 and V2 recommendation layers must remain side-effect free and Daily-isolated.
for(const text of [server,opt])for(const bad of ['.setValue(','.setValues(','.appendRow(','.clearContent(','.insertSheet(','PropertiesService','markDaily_(','ensureDailyAdaptiveV3_(','createDailyAdaptiveV3_(','ensureDailyV2_(','createDailyV2_(','sheet_(EP.sheets.daily)','Daily_Quiz'])if(text.includes(bad))fail(`Starred Intelligence recommendation layer must be read-only / Daily-isolated — found ${bad}`);else ok(`No forbidden write/Daily coupling: ${bad}`);
assert(!/setMarkedCentral|setHinduMarkedCentral|setStarredRevisionDifficult\s*\(/.test(server+opt),'server layer introduces no parallel Star or Difficult saving path');
assert(!/Mastered_Log|Question_Status|Starred_Revision_Log\s*=|Starred_Revision_Difficult\s*=/.test(server+opt),'Smart layer introduces no new persisted learning/Star/Difficult state definition');

// Existing Practice All / hierarchy remains untouched; Smart entry stays additive only at top summary.
need(legacyUi,"EPStarredRevision.start(${json},\"all\",0)",'existing Practice All path remains present');
need(legacyUi,'Practice All','existing Practice All control remains unchanged');
need(ui,"document.querySelector('#starredRevisionBody > .sr-summary')",'Smart Revision entry is injected only into All Starred summary');
need(ui,"b.textContent='🧠 Smart Revision'",'top-level Smart Revision button remains additive');
assert(!ui.includes('sr-group-panel')&&!ui.includes('sr-day-panel'),'Smart UI does not inject Smart Revision into Day/Block/Month action grids');

// Existing quiz/save/Star/Difficult engines remain reused.
need(ui,"EPQuiz.start(qs,{mode:'starredRevision'",'Smart session reuses existing quiz engine with Module route starredRevision');
need(ui,'smartStarred:true','Smart metadata remains additive to existing starredRevision mode');
need(ui,'EPQuiz.resumeOther()','Smart Starred sessions use existing resume engine');
need(ui,"EPQuiz.hasSavedSessionFor('starredRevision')",'Smart launch respects existing paused-session contract');
need(save,"emitDurableAck(item,res)",'durable Answer acknowledgement remains authoritative');
need(save,"module:String(item&&item.payload&&item.payload.module||'')",'durable acknowledgement preserves module');
need(starReliability,"OUTBOX_KEY='ep-star-outbox-v4'",'existing durable Star outbox remains intact');
need(starReliability,'overlayPending','existing pending Star overlay remains intact');
need(legacyUi,'setStarredRevisionDifficult','existing Difficult toggle remains authoritative');

// Completed/replaced-session lifecycle guard: late callbacks can never resurrect shared OTHER storage.
need(quiz,'sessionGeneration:0,live:false','quiz instances have an in-memory generation/live guard');
need(quiz,'function isLiveGeneration(generation)','async callbacks verify the current live quiz generation');
need(quiz,'if(!isLiveGeneration(generation))return','late answer/state callbacks are rejected after completion or replacement');
need(quiz,'function invalidateCurrentGeneration()','quiz completion and explicit replacement share one generation invalidator');
need(quiz,'function completeCurrentSaved(){invalidateCurrentGeneration();','Finish invalidates the current quiz generation before clearing storage');
need(quiz,'if(state.live&&keyForMode(state.meta.mode)===key)invalidateCurrentGeneration()','explicit shared-session replacement invalidates the matching live generation');
need(quiz,'if(!state.live||!state.questions.length)return','completed/replaced quiz state cannot be persisted again');
assert(!/location\.reload\s*\(|window\.location\.reload\s*\(/.test(ui+quiz),'Smart restart fix uses no forced page reload');

// Cooldown and snapshot performance contracts.
need(opt,'EP_STARRED_INTELLIGENCE_COOLDOWN_MS_V2=24*60*60*1000','24-hour Smart cooldown is explicit and non-persisted');
need(opt,'recentStarredCooldown:recent','cooldown is derived from existing Starred Revision attempt timestamp');
need(opt,'const fresh=rows.filter(x=>!x.recentStarredCooldown),recent=rows.filter(x=>x.recentStarredCooldown)','Smart selector performs non-cooldown first pass with recent fallback');
need(opt,'EP_STARRED_INTELLIGENCE_SIZES_V2.forEach','10/20/30/50 recommendations are precomputed from one snapshot universe');
need(opt,'smartBySize','snapshot exposes precomputed size plans');
need(ui,"EPApp.call('getStarredIntelligenceSnapshotV2',scope)",'page loads one Starred Intelligence snapshot');
need(ui,"function setSize(n){batchSize=[10,20,30,50].includes(Number(n))?Number(n):20;render()}",'size switching is client-side only');
assert(!/function setSize\([^)]*\)[\s\S]{0,180}load\(/.test(ui),'size switching never triggers backend recomputation');
need(ui,"EPApp.call('getStarredIntelligencePreparedBatchV2'",'Start uses lightweight prepared-batch verification');
assert(!ui.includes("EPApp.call('getStarredIntelligenceBatch'"),'optimized UI no longer rebuilds full Smart universe on Start');
const preparedBody=opt.slice(opt.indexOf('function getStarredIntelligencePreparedBatchV2'));
assert(!preparedBody.includes('starredIntelligenceUniverseV1_(')&&!preparedBody.includes('starredIntelligencePerformanceFactsV1_('),'prepared Start does not rescan Performance or rebuild complete universe');
need(ui,'const snapshots=new Map(),openSections=new Set()','narrow client snapshot cache and fold state exist');
need(ui,'snapshotDirty=true;snapshots.clear()','relevant changes invalidate all cached Smart snapshots');
need(ui,"String(e?.detail?.module||'')!=='starredRevision'",'only durable Starred Revision answers trigger answer-based Smart invalidation');
for(const fn of ['setMarked','setStarredRevisionDifficult','markMastered','restoreMastered'])need(ui,fn,`snapshot invalidation watches ${fn}`);
need(ui,'if(!hub||snapshotDirty||scopeKey(hub.scope)!==scopeKey(scope))return await load(true)','Start refuses stale/dirty snapshot');
need(ui,'if(res?.needsRefresh&&retry)','Start regenerates safely when lightweight eligibility verification detects material change');

// Post-session fresh result is computed once after durability and reused.
need(ui,"const pending=Number(window.EPSaveReliability?.pending?.()||0)",'session summary waits for durable Answer outbox');
need(ui,"EPApp.call('getStarredIntelligenceSnapshotV2',sum.meta?.smartScope||{all:true})",'post-session computes one confirmed fresh Smart snapshot');
need(ui,'rememberSnapshot(fresh)','confirmed post-session snapshot is retained for immediate Back to Intelligence reuse');
need(ui,'Next Smart Set Ready','session summary prepares the next recommendation without auto-starting');

// Race protection.
need(ui,'let hub=null,scope=','UI has isolated Starred Intelligence request state');
need(ui,'requestSeq=0','latest-request-wins sequence exists');
need(ui,'const seq=++requestSeq','each asynchronous snapshot refresh has a unique sequence');
need(ui,'if(seq!==requestSeq)return null','stale snapshot responses are rejected');
need(ui,'function changeScope(value)','scope changes have explicit request lifecycle');
need(ui,'requestSeq++;scope=Object.assign','scope change invalidates older in-flight response before starting the newer request');

// Compact mobile-first UI contracts.
need(ui,'Recommended Now —','Recommended Now remains permanently visible');
for(const section of ['coverage','health','practice','rotation','scope'])need(ui,`data-si-section=\"${section}\"`,`collapsible ${section} section exists`);
need(ui,'openSections.has(name)','open fold state is reapplied across renders');
need(ui,'sectionToggle(name,isOpen)','open fold state is tracked client-side');
need(ui,'ⓘ','compact information affordance is used');
assert(!ui.includes('<div class="si-card"><b>Why this set?</b>'),'permanent Why This Set paragraph was removed');
assert(!ui.includes("<b>Today's Recommendation</b>"),'duplicate large Today recommendation card was removed');
need(ui,'Starred Coverage ›','Starred Coverage collapsed row exists');
need(ui,'Learning Health ›','Learning Health collapsed row exists');
need(ui,'Smart Practice ›','Smart Practice collapsed row exists');
need(ui,'Rotation Health ›','Rotation Health collapsed row exists');
need(ui,'Day-wise Intelligence ›','Day-wise Intelligence collapsed row exists');
need(ui,'smartStarredReason','question-level Smart reason badge remains');

// Exact Smart restart regression: Finish clears OTHER, late callback cannot restore it, then Smart 2 and Smart 3 start without reload.
(function testQuizRestartLifecycle(){
  const storage=new Map(),elements={};
  const classList=()=>{const s=new Set();return{add:(...x)=>x.forEach(v=>s.add(v)),remove:(...x)=>x.forEach(v=>s.delete(v)),contains:x=>s.has(x),toggle:(x,force)=>{const on=force===undefined?!s.has(x):!!force;on?s.add(x):s.delete(x);return on}}};
  const makeEl=()=>{const e={textContent:'',className:'',style:{},disabled:false,children:[],classList:classList(),querySelector:sel=>sel==='.option-text'?{textContent:''}:null,appendChild(x){this.children.push(x);return x}};let html='';Object.defineProperty(e,'innerHTML',{get:()=>html,set:v=>{html=String(v);e.children=[]}});return e};
  ['quizView','bottomNav','quizMode','quizCounter','quizBar','qCategory','qId','qText','qWord','prevBtn','nextBtn','markBtn','masteredBtn','vocabBtn','optionList','feedback','explanation'].forEach(id=>elements[id]=makeEl());
  const pending=[];
  const delayed=()=>({then(fn){pending.push(fn);return{catch(){return this}}}});
  const localStorage={getItem:k=>storage.has(k)?storage.get(k):null,setItem:(k,v)=>storage.set(k,String(v)),removeItem:k=>storage.delete(k)};
  const document={getElementById:id=>elements[id]||null,querySelectorAll:()=>[],createElement:()=>makeEl()};
  const EPApp={call:fn=>fn==='submitAnswer'?delayed():{then(fn){fn({});return{catch(){return this}}}},toast:()=>{},showTab:()=>{},refreshDashboard:()=>{},refreshResumeCard:()=>{}};
  const q=id=>({id,topic:'Vocabulary',question:`Question ${id}`,correctKey:'A',options:[{key:'A',text:'A'},{key:'B',text:'B'},{key:'C',text:'C'},{key:'D',text:'D'}]});
  const qctx={console,Date,Math,Set,Object,String,Number,Array,Error,JSON,localStorage,document,EPApp,confirm:()=>true,window:{scrollTo:()=>{}},setTimeout:(fn)=>{fn();return 1}};vm.createContext(qctx);new vm.Script(quiz.replace(/<\/?script[^>]*>/gi,'')).runInContext(qctx);const Quiz=vm.runInContext('EPQuiz',qctx);
  const start=id=>Quiz.start([q(id)],{mode:'starredRevision',smartStarred:true,batchId:id,returnTab:'home'}),startOther=id=>Quiz.start([q(id)],{mode:'category',category:'Vocabulary',batchId:id,returnTab:'practice'});
  const answer=()=>elements.optionList.children[0].onclick(),drainPending=()=>{while(pending.length){const cb=pending.shift();cb&&cb({correctKey:'A'})}};
  start('SMART-1');answer();assert(Quiz.hasSavedSessionFor('starredRevision'),'Smart session 1 is resumable while live');Quiz.next();assert(!storage.has('ep-quiz-other-v4'),'Smart session 1 Finish clears shared OTHER session');assert(!Quiz.hasSavedSessionFor('starredRevision'),'finished Smart session is not reported as paused');drainPending();assert(!storage.has('ep-quiz-other-v4'),'late Smart 1 answer callback cannot resurrect completed OTHER session');
  start('SMART-2');answer();assert(JSON.parse(storage.get('ep-quiz-other-v4')).meta.batchId==='SMART-2','Smart session 2 starts without browser refresh');Quiz.next();drainPending();assert(!storage.has('ep-quiz-other-v4'),'Smart session 2 remains cleared after its late callback');
  start('SMART-3');assert(JSON.parse(storage.get('ep-quiz-other-v4')).meta.batchId==='SMART-3','Smart session 3 starts without browser refresh');Quiz.pause();assert(storage.has('ep-quiz-other-v4'),'paused Smart session remains resumable');Quiz.resumeOther();assert(JSON.parse(storage.get('ep-quiz-other-v4')).meta.batchId==='SMART-3','Pause/Resume contract remains intact after lifecycle guard');
  startOther('OTHER-PAUSED');answer();Quiz.pause();assert(JSON.parse(storage.get('ep-quiz-other-v4')).meta.mode==='category','unrelated shared OTHER session remains paused until user chooses replacement');Quiz.replaceSavedFor('starredRevision');assert(!storage.has('ep-quiz-other-v4'),'confirmed shared OTHER replacement clears the paused session');drainPending();assert(!storage.has('ep-quiz-other-v4'),'late callback cannot resurrect an explicitly replaced unrelated OTHER session');

  function startSized(label,n){Quiz.start(Array.from({length:n},(_,i)=>q(`${label}-${i+1}`)),{mode:'starredRevision',smartStarred:true,batchId:label,returnTab:'home'})}
  function finishSized(label,n,settleBeforeFinish){startSized(label,n);for(let i=0;i<n;i++){answer();if(settleBeforeFinish){const cb=pending.shift();cb&&cb({correctKey:'A'})}Quiz.next()}assert(!storage.has('ep-quiz-other-v4'),`${n}-question Smart Finish clears shared OTHER session`);drainPending();assert(!storage.has('ep-quiz-other-v4'),`${n}-question late callbacks cannot resurrect completed session`)}
  [10,20,30,50].forEach(n=>{
    finishSized(`SIZE-${n}-SET-1`,n,false);
    startSized(`SIZE-${n}-SET-2`,n);assert(JSON.parse(storage.get('ep-quiz-other-v4')).questions.length===n,`${n}-question Smart second set starts without refresh`);for(let i=0;i<n;i++){answer();const cb=pending.shift();cb&&cb({correctKey:'A'});Quiz.next()}assert(!storage.has('ep-quiz-other-v4'),`${n}-question Smart second Finish clears session when saves are already settled`);
    startSized(`SIZE-${n}-SET-3`,n);assert(JSON.parse(storage.get('ep-quiz-other-v4')).questions.length===n,`${n}-question Smart third set starts without refresh`);Quiz.replaceSavedFor('starredRevision');assert(!storage.has('ep-quiz-other-v4'),`${n}-question test cleanup uses normal replacement lifecycle`);
  });
})();

// Pure behavior tests: learning/rotation plus anti-repeat cooldown.
const ctx={console,Date,Math,Set,Object,String,Number,Array,Error};vm.createContext(ctx);new vm.Script(server+'\n'+opt).runInContext(ctx);
const now=Date.now(),day=86400000;
const row=(id,state,days,extra={})=>Object.assign({id,profile:{state},due:false,difficult:false,neverRevised:false,lastStarred:days==null?null:new Date(now-days*day),daysSinceStarred:days,recentStarredCooldown:false},extra);
const mixed=[...Array.from({length:8},(_,i)=>row('W'+i,i<4?'Persistent Weak':'Weak',2)),row('OLD_STRONG','Strong',20),row('NEVER_STRONG','Strong',null,{neverRevised:true})];
const smart=ctx.starredIntelligenceSmartSelectV2_(mixed,10);
assert(smart.length===10,'Smart Mix returns requested eligible count');
assert(smart.some(x=>x.selectionLane==='learning'),'Smart Mix contains learning-priority lane');
assert(smart.some(x=>x.selectionLane==='rotation'),'Smart Mix reserves coverage-rotation lane');
assert(smart.some(x=>x.id==='OLD_STRONG'),'old Strong Starred item cannot be permanently starved by Weak items');
assert(smart.some(x=>x.id==='NEVER_STRONG'),'Never Revised Starred item receives rotation exposure');

const recentCompleted=Array.from({length:20},(_,i)=>row('DONE'+i,i<8?'Persistent Weak':'Weak',0,{recentStarredCooldown:true}));
const alternatives=Array.from({length:20},(_,i)=>row('ALT'+i,'Strong',10+i));
const next20=ctx.starredIntelligenceSmartSelectV2_(recentCompleted.concat(alternatives),20);
assert(next20.length===20&&next20.every(x=>x.id.startsWith('ALT')),'Smart N immediately excludes all just-completed IDs when N non-cooldown alternatives exist');

const fresh23=Array.from({length:23},(_,i)=>row('FRESH'+i,i<5?'Weak':'Strong',8+i));
const recent7=Array.from({length:7},(_,i)=>row('REC'+i,'Persistent Weak',0,{recentStarredCooldown:true}));
const filled30=ctx.starredIntelligenceSmartSelectV2_(fresh23.concat(recent7),30);
assert(filled30.length===30,'soft cooldown never returns an artificially small Smart set');
assert(filled30.slice(0,23).every(x=>!x.recentStarredCooldown)&&filled30.slice(23).every(x=>x.recentStarredCooldown),'cooldown questions are used only as fallback after all non-recent alternatives');

const weakPref=ctx.starredIntelligenceSelectV2_([row('RECENT_WEAK','Weak',0,{recentStarredCooldown:true}),row('FRESH_WEAK','Weak',3)],'weak',2);
assert(weakPref[0].id==='FRESH_WEAK','explicit Weak Focus prefers equivalent non-recent candidate before recent candidate');
const rotation=ctx.starredIntelligenceSelectV2_([row('RECENT','Strong',0,{recentStarredCooldown:true}),row('OLD','Strong',15),row('NEVER','Strong',null,{neverRevised:true})],'longest',3);
assert(rotation.map(x=>x.id).join(',')==='NEVER,OLD,RECENT','Longest Not Revised orders Never Revised → old non-recent → recent cooldown');
const nr=ctx.starredIntelligenceSelectV2_([row('A','Weak',2),row('B','Strong',null,{neverRevised:true})],'notRevised',10);
assert(nr.length===1&&nr[0].id==='B','Not Revised remains based only on Starred-module exposure');
const due=ctx.starredIntelligenceSelectV2_([row('D1','Strong',5,{due:true}),row('D0','Persistent Weak',1,{due:false})],'due',10);
assert(due.length===1&&due[0].id==='D1','Due Now includes only centrally due Starred questions');
const diff=ctx.starredIntelligenceSelectV2_([row('M','Strong',5,{difficult:true}),row('N','Persistent Weak',5,{difficult:false})],'difficult',10);
assert(diff.length===1&&diff[0].id==='M','Difficult mode eligibility remains manual Difficult only');
const scoped=ctx.starredIntelligenceApplyScopeV1_([{id:'D5',day:5},{id:'D8',day:8}],{fromDay:5,toDay:5});
assert(scoped.length===1&&scoped[0].id==='D5','scope filtering still excludes questions outside requested Day/Block/Month before ranking');

// No global collisions across all server files.
const newFns=[...server.matchAll(/function\s+([A-Za-z0-9_]+)\s*\(/g),...opt.matchAll(/function\s+([A-Za-z0-9_]+)\s*\(/g)].map(m=>m[1]),others=fs.readdirSync(root).filter(f=>f.endsWith('.gs')&&!['StarredIntelligence.gs','StarredIntelligenceOptimization.gs'].includes(f)).map(read).join('\n');
for(const fn of newFns)assert(!new RegExp(`function\\s+${fn.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}\\s*\\(`).test(others),`no duplicate global function: ${fn}`);

need(index,"include('StarredIntelligenceUI')",'Starred Intelligence UI remains included');
assert(index.indexOf("include('StarredIntelligenceUI')")>index.indexOf("include('ModuleSyncUI')"),'Starred Intelligence integration still loads last and wraps only finalized existing behavior');
if(process.exitCode){console.error('\nStarred Intelligence optimization validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Starred Intelligence cooldown, snapshot, race, eligibility, save-routing, restart/replacement lifecycle, all-size relaunch and compact UX contracts passed.');
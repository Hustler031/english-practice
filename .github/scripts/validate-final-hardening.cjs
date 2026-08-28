const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error('❌ '+m);process.exitCode=1},assert=(v,m)=>v?console.log('✅ '+m):fail(m);
const li=read('LearningIntelligence.gs'),daily=read('DailyAdaptive.gs'),saved=read('SmartMySaved.gs'),star=read('StarredIntelligence.gs'),history=read('MySavedRevision.gs');
assert(!daily.includes('dailyFlagEligibleV5_'),'Daily has no flag-age bypass');
assert(daily.includes("if(!learningDueV3_(p,key))return ''"),'Daily applies due gate before flags');
assert(li.includes('function manualMasteredMapV3_()'),'Manual Mastered has a durable authoritative map');
assert(!li.includes('failedAfterMastery'),'Later failure cannot silently unmaster');
assert(saved.includes('controlledNew:attempts.length===0'),'Smart My Saved Controlled New uses central Performance evidence');
assert(star.includes('controlledNew:attempts.length===0'),'Smart Starred Controlled New uses central Performance evidence');
assert(history.includes("if(t==='CU')return {id:'CU',name:'Concept / Usage'}"),'My Saved CU type overrides stale Question topic');
(function(){
  const ctx={console,Math,Date,Set,Object,String,Number,Array};ctx.isGenuineBankQuestionV2_=()=>true;ctx.learningDueV3_=(p)=>!!p.due;vm.createContext(ctx);new vm.Script(daily,{filename:'DailyAdaptive.gs'}).runInContext(ctx);
  const q={id:'Q'},strong={attempts:3,state:'Strong',due:false},proven={attempts:4,state:'Proven Mastered',due:false},dueStrong={attempts:3,state:'Strong',due:true};
  assert(ctx.dailyPrimaryReasonV5_(q,strong,'x',{Q:true},{Q:true})==='','Non-due Strong + Starred/Difficult is excluded from Daily');
  assert(ctx.dailyPrimaryReasonV5_(q,proven,'x',{Q:true},{Q:true})==='','Non-due Proven Mastered + flags is excluded from Daily');
  assert(ctx.dailyPrimaryReasonV5_(q,dueStrong,'x',{Q:true},{})==='Marked Review','Due Strong + Starred remains eligible');
  const scored=[...Array.from({length:20},(_,i)=>({q:{id:'W'+i},reason:'Weak',score:100-i})),...Array.from({length:4},(_,i)=>({q:{id:'N'+i},reason:'Controlled New',score:1-i}))];
  const got=ctx.dailyBalancedSelectV5_(scored,20);assert(got.filter(x=>x.reason==='Controlled New').length>=2,'Daily protects Controlled New under weak backlog');assert(new Set(got.map(x=>x.q.id)).size===got.length,'Daily selection is unique');
})();
(function(){
  const ctx={console,Math,Date,Set,Object,String,Number,Array};ctx.shuffle_=a=>a;vm.createContext(ctx);new vm.Script(saved,{filename:'SmartMySaved.gs'}).runInContext(ctx);
  const mk=(id,state,controlledNew=false)=>({id,active:true,mastered:false,controlledNew,neverRevised:false,daysSinceRevision:0,due:state!=='Strong',difficult:false,profile:{state}});
  const got=ctx.smartMySavedSelectV1_([mk('N1','New',true),mk('N2','New',true),...Array.from({length:20},(_,i)=>mk('W'+i,'Weak'))],'smart',10);
  assert(got.filter(x=>x.selectionReason==='Controlled New').length===2,'Smart My Saved protects Controlled New');assert(new Set(got.map(x=>x.id)).size===got.length,'Smart My Saved selection is unique');
})();
(function(){
  const ctx={console,Math,Date,Set,Object,String,Number,Array};vm.createContext(ctx);new vm.Script(star,{filename:'StarredIntelligence.gs'}).runInContext(ctx);
  const mk=(id,state,controlledNew=false)=>({id,controlledNew,neverRevised:false,daysSinceStarred:0,due:state!=='Strong',difficult:false,profile:{state}});
  const got=ctx.starredIntelligenceSmartSelectV1_([mk('N1','New',true),mk('N2','New',true),...Array.from({length:20},(_,i)=>mk('W'+i,'Weak'))],10);
  assert(got.filter(x=>x.selectionReason==='Controlled New').length===2,'Smart Starred protects in-corpus Controlled New');assert(new Set(got.map(x=>x.id)).size===got.length,'Smart Starred selection is unique');
})();
if(process.exitCode)process.exit(process.exitCode);console.log('✅ Final hardening behavioural suite passed.');

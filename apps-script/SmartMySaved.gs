const EP_SMART_MY_SAVED_VERSION='V2';
const EP_SMART_MY_SAVED_MODULE='mySavedRevision';
// Shared central primitives are supplied by mySavedRevisionContextV2_: mySavedRevisionItemsV2_, performanceFactsV2_, learningProfileV2_, currentStarredMapV2_, centralDifficultMapV2_, currentMasteredMapV2_, statusMap_.

function smartMySavedDaysSinceV1_(d,now){if(!(d instanceof Date)||isNaN(d))return null;return Math.max(0,Math.floor((now.getTime()-d.getTime())/86400000));}
function smartMySavedTierV1_(x){const s=String(x.profile&&x.profile.state||'New');if(x.due&&s==='Persistent Weak')return 8;if(x.due&&s==='Weak')return 7;if(x.due&&s==='Fragile')return 6;if(x.due)return 5;if(x.difficult)return 4;if(x.neverRevised)return 3;if(s==='Learning'||s==='New')return 2;return 1;}
function smartMySavedLearningSortV1_(a,b){const ta=smartMySavedTierV1_(a),tb=smartMySavedTierV1_(b);if(tb!==ta)return tb-ta;if(Number(b.due)!==Number(a.due))return Number(b.due)-Number(a.due);if(Number(b.difficult)!==Number(a.difficult))return Number(b.difficult)-Number(a.difficult);const da=a.daysSinceRevision==null?1e9:a.daysSinceRevision,db=b.daysSinceRevision==null?1e9:b.daysSinceRevision;if(db!==da)return db-da;return String(a.id).localeCompare(String(b.id));}
function smartMySavedRotationSortV1_(a,b){if(Number(b.neverRevised)!==Number(a.neverRevised))return Number(b.neverRevised)-Number(a.neverRevised);const at=a.lastRevision instanceof Date?a.lastRevision.getTime():0,bt=b.lastRevision instanceof Date?b.lastRevision.getTime():0;if(at!==bt)return at-bt;return smartMySavedLearningSortV1_(a,b);}
function smartMySavedReasonV1_(x,lane){const s=String(x.profile&&x.profile.state||'New');if(lane==='rotation'){if(x.neverRevised)return'Never Revised';if(Number(x.daysSinceRevision||0)>=7)return'Longest Not Revised';return'Coverage Rotation';}if(['Persistent Weak','Weak','Fragile'].includes(s))return s;if(x.due&&x.difficult)return'Difficult + Due';if(x.due)return'Due Recall';if(x.difficult)return'Difficult';if(s==='Learning'||s==='New')return'Learning';return'Healthy Rotation';}
function smartMySavedMarkV1_(x,lane){return Object.assign({},x,{selectionLane:lane,selectionReason:smartMySavedReasonV1_(x,lane)});}

function smartMySavedUniverseV1_(ctx){
  ctx=ctx||mySavedRevisionContextV2_();const base=mySavedRevisionItemsFromContextV2_(ctx),facts=ctx.facts,now=ctx.now||new Date(),today=todayKey_();
  const rows=base.filter(x=>x.active).map(x=>{const attempts=facts.byId[x.id]||[],moduleAttempts=attempts.filter(a=>String(a.module||'').toLowerCase()===EP_SMART_MY_SAVED_MODULE.toLowerCase()),lastRevision=moduleAttempts.length?moduleAttempts[moduleAttempts.length-1].ts:null,due=learningDueV3_(x.profile,today);return Object.assign({},x,{due,revisedCount:moduleAttempts.length,neverRevised:moduleAttempts.length===0,lastRevision,daysSinceRevision:smartMySavedDaysSinceV1_(lastRevision,now)});});
  return {rows,base,facts,now,ctx};
}
function smartMySavedEligibleV1_(rows){return (rows||[]).filter(x=>x.active&&!x.mastered);}
function smartMySavedStatsV1_(rows){const all=(rows||[]),eligible=smartMySavedEligibleV1_(all);return {saved:all.length,eligible:eligible.length,neverRevised:eligible.filter(x=>x.neverRevised).length,due:eligible.filter(x=>x.due).length,weak:eligible.filter(x=>['Persistent Weak','Weak','Fragile'].includes(String(x.profile&&x.profile.state||''))).length,difficult:eligible.filter(x=>x.difficult).length,starred:eligible.filter(x=>x.starred).length,mastered:all.filter(x=>x.mastered).length};}
function smartMySavedSelectV1_(rows,mode,count){
  let pool=smartMySavedEligibleV1_(rows),m=String(mode||'smart').toLowerCase();const requested=Math.max(1,Math.min(100,Number(count||20)));
  if(m==='weak')pool=pool.filter(x=>['Persistent Weak','Weak','Fragile'].includes(String(x.profile&&x.profile.state||''))).sort(smartMySavedLearningSortV1_);
  else if(m==='difficult')pool=pool.filter(x=>x.difficult).sort(smartMySavedLearningSortV1_);
  else if(m==='starred')pool=pool.filter(x=>x.starred).sort(smartMySavedLearningSortV1_);
  else if(m==='random'){shuffle_(pool);}
  else if(m==='all')return pool.sort(smartMySavedRotationSortV1_).map(x=>smartMySavedMarkV1_(x,'rotation'));
  else if(m==='smart'){
    const n=Math.min(requested,pool.length);if(!n)return[];const chosen=[],ids=new Set(),urgent=pool.filter(x=>smartMySavedTierV1_(x)>=4).length,coverage=pool.filter(x=>x.neverRevised||Number(x.daysSinceRevision||0)>=7).length;let learningRatio=.5;if(urgent>=Math.ceil(n*.7))learningRatio=.6;if(coverage>=Math.ceil(n*.5))learningRatio=.4;const learnTarget=Math.round(n*learningRatio),rotationTarget=n-learnTarget;
    pool.slice().sort(smartMySavedLearningSortV1_).slice(0,learnTarget).forEach(x=>{chosen.push(smartMySavedMarkV1_(x,'learning'));ids.add(x.id)});
    pool.slice().sort(smartMySavedRotationSortV1_).filter(x=>!ids.has(x.id)).slice(0,rotationTarget).forEach(x=>{chosen.push(smartMySavedMarkV1_(x,'rotation'));ids.add(x.id)});
    pool.slice().sort(smartMySavedRotationSortV1_).filter(x=>!ids.has(x.id)).slice(0,n-chosen.length).forEach(x=>chosen.push(smartMySavedMarkV1_(x,'rotation')));return chosen;
  } else throw new Error('Unknown Smart My Saved mode: '+mode);
  return pool.slice(0,requested).map(x=>smartMySavedMarkV1_(x,'learning'));
}
function smartMySavedSnapshotV2_(){const ctx=mySavedRevisionContextV2_(),u=smartMySavedUniverseV1_(ctx),stats=smartMySavedStatsV1_(u.rows),currentDay=typeof starredRevisionActiveDay_==='function'?starredRevisionActiveDay_():Math.max(1,...u.base.map(x=>x.day));return {version:EP_SMART_MY_SAVED_VERSION,generatedAt:new Date().toISOString(),stats,available:{smart:stats.eligible,weak:stats.weak,difficult:stats.difficult,starred:stats.starred,random:stats.eligible,all:stats.eligible},sizes:[10,20,30,50],history:{currentDay,stats:mySavedRevisionStatsV2_(u.base),categories:mySavedRevisionCategoriesV2_(u.base),groups:mySavedRevisionHierarchyV2_(u.base,currentDay)}};}
function getSmartMySavedSnapshotV2(){return smartMySavedSnapshotV2_();}
function getSmartMySavedHubV1(){const u=smartMySavedUniverseV1_(),stats=smartMySavedStatsV1_(u.rows);return {version:EP_SMART_MY_SAVED_VERSION,generatedAt:new Date().toISOString(),stats,available:{smart:stats.eligible,weak:stats.weak,difficult:stats.difficult,starred:stats.starred,random:stats.eligible,all:stats.eligible},sizes:[10,20,30,50]};}
function getSmartMySavedBatchV1(mode,count){const u=smartMySavedUniverseV1_(),selected=smartMySavedSelectV1_(u.rows,mode,count);return selected.map(x=>{const q=serveQuestion_(x.q);q.marked=!!x.starred;q.difficult=!!x.difficult;q.smartMySaved=true;q.smartMySavedReason=x.selectionReason;q.smartMySavedLane=x.selectionLane;q.smartMySavedBaselineState=String(x.profile&&x.profile.state||'New');return q;});}
function getSmartMySavedAuditV1(){const u=smartMySavedUniverseV1_(),eligible=smartMySavedEligibleV1_(u.rows),ids=new Set(),dupes=[];eligible.forEach(x=>{if(ids.has(x.id))dupes.push(x.id);ids.add(x.id)});return {ok:dupes.length===0,eligible:eligible.length,duplicates:dupes,stats:smartMySavedStatsV1_(u.rows)};}

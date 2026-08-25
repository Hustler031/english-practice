const EP_PHRASAL_VERSION='V1.1';
const EP_PHRASAL_DAILY_PREFIX='PHRASAL_DAILY_';
const EP_PHRASAL_MODULES=new Set(['phrasaldaily','phrasalrevision']);

/*
PHRASAL DAILY CONTENT CONTRACT (future generated batches):
- Keep every generated question permanent under PHRASAL_DAILY_YYYYMMDD and preserve Question_ID + Concept_ID.
- When the format permits, use at least three plausible competing distractors, preferably related phrasal verbs,
  neighbouring particle combinations, or contextually plausible alternatives rather than obviously unrelated choices.
- Useful confusion families include: put off / put out / put up / put through; look for / look after / look into / look over;
  call off / call in / call out / call for; set aside / put aside / set out / set off; get across / get over / get through / get by.
- The keyed answer must remain uniquely defensible. Never introduce artificial ambiguity merely to increase difficulty.
- Explanations should distinguish important nearby distractors when that distinction improves SSC-style recall.
*/

function phrasalQuestionsV1_(){return allQuestions_().filter(q=>isActive_(q)&&(canonicalCategory_(q.topic)==='PHRASAL'||String(q.topic||'').trim().toLowerCase()==='phrasal verb'));}
function phrasalConceptKeyV1_(q){return String(q&&q.conceptId||'').trim()||('PVQ_'+String(q&&q.id||'').trim());}
function phrasalDaysSinceV1_(d,now){if(!(d instanceof Date)||isNaN(d))return null;return Math.max(0,Math.floor((now.getTime()-d.getTime())/86400000));}
function phrasalConceptMasteredV1_(profile){return !!(profile&&profile.provenMastery)&&String(profile&&profile.state||'')==='Strong';}
function phrasalConceptsV1_(){
  const qs=phrasalQuestionsV1_(),facts=performanceFactsV2_(),status=statusMap_(),stars=currentStarredMapV2_(),diff=centralDifficultMapV2_(),questionMastered=currentMasteredMapV2_(),now=new Date(),groups={};
  qs.forEach(q=>{const key=phrasalConceptKeyV1_(q);if(!groups[key])groups[key]={conceptId:key,word:String(q.word||''),questions:[]};groups[key].questions.push(q)});
  return Object.values(groups).map(g=>{
    const ids=g.questions.map(q=>q.id),attempts=ids.flatMap(id=>facts.byId[id]||[]).sort((a,b)=>a.ts-b.ts),profile=learningProfileV2_(attempts),moduleAttempts=attempts.filter(a=>EP_PHRASAL_MODULES.has(String(a.module||'').toLowerCase())),lastRevision=moduleAttempts.length?moduleAttempts[moduleAttempts.length-1].ts:null,activeVariants=g.questions.filter(q=>isActive_(q)&&!questionMastered[q.id]),freshVariants=activeVariants.filter(q=>!(facts.byId[q.id]||[]).length),conceptMastered=phrasalConceptMasteredV1_(profile),due=activeVariants.some(q=>{const n=status[q.id]&&status[q.id].nextReview?new Date(status[q.id].nextReview):null;return !!(n&&!isNaN(n)&&n<=now)}),starred=activeVariants.some(q=>!!stars[q.id]),difficult=activeVariants.some(q=>!!diff[q.id]);
    return Object.assign(g,{ids,attempts,profile,activeVariants,freshVariants,freshVariantCount:freshVariants.length,questionMasteredCount:g.questions.filter(q=>!!questionMastered[q.id]).length,mastered:conceptMastered,due,starred,difficult,revisedCount:moduleAttempts.length,neverRevised:moduleAttempts.length===0,lastRevision,daysSinceRevision:phrasalDaysSinceV1_(lastRevision,now)});
  });
}
function phrasalTierV1_(x){const s=String(x.profile&&x.profile.state||'New');if(s==='Persistent Weak')return 9;if(s==='Weak')return 8;if(s==='Fragile')return 7;if(x.due)return 6;if(x.difficult)return 5;if(x.starred)return 4;if(x.mastered&&x.freshVariantCount)return 3;if(x.neverRevised)return 3;if(s==='Learning'||s==='New')return 2;return 1;}
function phrasalLearningSortV1_(a,b){const ta=phrasalTierV1_(a),tb=phrasalTierV1_(b);if(tb!==ta)return tb-ta;if(Number(b.due)!==Number(a.due))return Number(b.due)-Number(a.due);const da=a.daysSinceRevision==null?1e9:a.daysSinceRevision,db=b.daysSinceRevision==null?1e9:b.daysSinceRevision;if(db!==da)return db-da;return String(a.conceptId).localeCompare(String(b.conceptId));}
function phrasalRotationSortV1_(a,b){if(Number(b.freshVariantCount>0)!==Number(a.freshVariantCount>0))return Number(b.freshVariantCount>0)-Number(a.freshVariantCount>0);if(Number(b.neverRevised)!==Number(a.neverRevised))return Number(b.neverRevised)-Number(a.neverRevised);const at=a.lastRevision instanceof Date?a.lastRevision.getTime():0,bt=b.lastRevision instanceof Date?b.lastRevision.getTime():0;if(at!==bt)return at-bt;return phrasalLearningSortV1_(a,b);}
function phrasalReasonV1_(x,lane){const s=String(x.profile&&x.profile.state||'New');if(['Persistent Weak','Weak','Fragile'].includes(s))return s;if(x.due)return'Due Retention';if(x.difficult&&x.starred)return'Difficult + Starred';if(x.difficult)return'Difficult';if(x.starred)return'Starred';if(x.mastered&&x.freshVariantCount)return'Fresh Variant Check';if(lane==='rotation'){if(x.neverRevised)return'Never / Under-revised';if(Number(x.daysSinceRevision||0)>=7)return'Longest Not Seen';return'Healthy Rotation';}if(s==='Learning'||s==='New')return'Learning';return'Rotation';}
function phrasalMarkV1_(x,lane){return Object.assign({},x,{selectionLane:lane,selectionReason:phrasalReasonV1_(x,lane)});}
function phrasalEligibleConceptsV1_(concepts){return (concepts||[]).filter(x=>x.activeVariants.length&&(!x.mastered||x.freshVariantCount>0));}
function phrasalSelectConceptsV1_(concepts,mode,count){
  let pool=phrasalEligibleConceptsV1_(concepts),m=String(mode||'smart').toLowerCase(),n=Math.max(1,Math.min(100,Number(count||20)));
  if(m==='weak')pool=pool.filter(x=>['Persistent Weak','Weak','Fragile'].includes(String(x.profile&&x.profile.state||''))).sort(phrasalLearningSortV1_);
  else if(m==='difficult')pool=pool.filter(x=>x.difficult).sort(phrasalLearningSortV1_);
  else if(m==='starred')pool=pool.filter(x=>x.starred).sort(phrasalLearningSortV1_);
  else if(m==='random')shuffle_(pool);
  else if(m==='all')return pool.sort(phrasalRotationSortV1_).map(x=>phrasalMarkV1_(x,'rotation'));
  else if(m==='smart'){
    n=Math.min(n,pool.length);if(!n)return[];const chosen=[],keys=new Set(),urgent=pool.filter(x=>phrasalTierV1_(x)>=4).length,rotation=pool.filter(x=>x.freshVariantCount||x.neverRevised||Number(x.daysSinceRevision||0)>=7).length;let ratio=.6;if(urgent<=Math.floor(n*.35)&&rotation>=Math.ceil(n*.5))ratio=.45;else if(urgent>=Math.ceil(n*.75))ratio=.7;const learnTarget=Math.round(n*ratio),rotationTarget=n-learnTarget;
    pool.slice().sort(phrasalLearningSortV1_).slice(0,learnTarget).forEach(x=>{chosen.push(phrasalMarkV1_(x,'learning'));keys.add(x.conceptId)});
    pool.slice().sort(phrasalRotationSortV1_).filter(x=>!keys.has(x.conceptId)).slice(0,rotationTarget).forEach(x=>{chosen.push(phrasalMarkV1_(x,'rotation'));keys.add(x.conceptId)});
    pool.slice().sort(phrasalRotationSortV1_).filter(x=>!keys.has(x.conceptId)).slice(0,n-chosen.length).forEach(x=>chosen.push(phrasalMarkV1_(x,'rotation')));return chosen;
  } else throw new Error('Unknown Phrasal mode: '+mode);
  return pool.slice(0,n).map(x=>phrasalMarkV1_(x,'learning'));
}
function phrasalChooseVariantV1_(concept,facts,mastered){
  const candidates=(concept.activeVariants||[]).filter(q=>!mastered[q.id]);if(!candidates.length)return null;
  return candidates.slice().sort((a,b)=>{const aa=facts.byId[a.id]||[],bb=facts.byId[b.id]||[],am=aa.filter(x=>EP_PHRASAL_MODULES.has(String(x.module||'').toLowerCase())),bm=bb.filter(x=>EP_PHRASAL_MODULES.has(String(x.module||'').toLowerCase()));if(am.length!==bm.length)return am.length-bm.length;const at=am.length?am[am.length-1].ts.getTime():0,bt=bm.length?bm[bm.length-1].ts.getTime():0;if(at!==bt)return at-bt;if(aa.length!==bb.length)return aa.length-bb.length;return String(a.id).localeCompare(String(b.id));})[0];
}
function phrasalServeConceptsV1_(selected){const facts=performanceFactsV2_(),mastered=currentMasteredMapV2_(),stars=currentStarredMapV2_(),diff=centralDifficultMapV2_();return (selected||[]).map(x=>{const base=phrasalChooseVariantV1_(x,facts,mastered);if(!base)return null;const q=serveQuestion_(base);q.marked=!!stars[base.id];q.difficult=!!diff[base.id];q.phrasalConceptId=x.conceptId;q.phrasalSelectionReason=x.selectionReason;q.phrasalSelectionLane=x.selectionLane;q.phrasalBaselineState=String(x.profile&&x.profile.state||'New');q.phrasalConceptMastered=!!x.mastered;return q;}).filter(Boolean);}
function phrasalSourceDateV1_(q){const s=String(q&&q.sourceId||'').trim(),m=s.match(/^PHRASAL_DAILY_(\d{4})(\d{2})(\d{2})$/);return m?`${m[1]}-${m[2]}-${m[3]}`:'';}
function phrasalDailySourceIdV1_(date){return EP_PHRASAL_DAILY_PREFIX+String(date||todayKey_()).replace(/-/g,'');}
function phrasalDailyRowsV1_(date){const sid=phrasalDailySourceIdV1_(date);return phrasalQuestionsV1_().filter(q=>String(q.sourceId||'').trim()===sid);}
function getPhrasalTodayBatchV1(){const rows=phrasalDailyRowsV1_(todayKey_()),maps=centralServeMapsV3_(),mastered=currentMasteredMapV2_();return serveQuestionsCentralV3_(rows.filter(q=>isActive_(q)&&!mastered[q.id]),maps);}
function phrasalHistoryOrderedV1_(){
  const facts=performanceFactsV2_(),batches={};phrasalQuestionsV1_().forEach(q=>{const date=phrasalSourceDateV1_(q);if(!date)return;if(!batches[date])batches[date]={date,questions:[],questionIds:new Set(),practised:new Set()};batches[date].questions.push(q);batches[date].questionIds.add(q.id)});
  Object.values(batches).forEach(b=>b.questionIds.forEach(id=>(facts.byId[id]||[]).filter(a=>EP_PHRASAL_MODULES.has(String(a.module||'').toLowerCase())).forEach(()=>b.practised.add(id))));
  return Object.values(batches).sort((a,b)=>a.date.localeCompare(b.date)).map((b,i)=>({day:i+1,date:b.date,label:b.date===todayKey_()?'Today':'Day '+(i+1),generated:b.questions.length,practised:b.practised.size,questions:b.questions.slice()}));
}
function phrasalHistoryScopeV1_(ordered,fromDay,toDay){
  const rows=ordered||[],lo=Math.max(1,Number(fromDay||1)),hi=Math.max(lo,Number(toDay||lo)),seen=new Set(),out=[];
  rows.filter(x=>Number(x.day)>=lo&&Number(x.day)<=hi).forEach(x=>(x.questions||[]).forEach(q=>{const id=String(q&&q.id||'').trim();if(id&&!seen.has(id)){seen.add(id);out.push(q)}}));return out;
}
function getPhrasalHistoryBatchV1(fromDay,toDay){const rows=phrasalHistoryScopeV1_(phrasalHistoryOrderedV1_(),fromDay,toDay),mastered=currentMasteredMapV2_(),maps=centralServeMapsV3_();return serveQuestionsCentralV3_(rows.filter(q=>isActive_(q)&&!mastered[q.id]),maps);}
function phrasalHistoryV1_(){
  const ordered=phrasalHistoryOrderedV1_();if(!ordered.length)return[];const currentDay=ordered.length,currentMonth=Math.floor((currentDay-1)/30)+1,currentMonthStart=(currentMonth-1)*30+1,currentBlockStart=Math.floor((currentDay-1)/10)*10+1,out=[];
  for(let d=currentDay;d>=currentBlockStart;d--){const x=ordered[d-1];if(x)out.push({type:'day',label:x.label,fromDay:d,toDay:d,generated:x.generated,practised:x.practised,date:x.date});}
  for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=Math.min(start+9,currentDay),part=ordered.filter(x=>x.day>=start&&x.day<=end);if(part.length)out.push({type:'block',label:'Days '+start+'–'+end,fromDay:start,toDay:end,generated:part.reduce((n,x)=>n+x.generated,0),practised:part.reduce((n,x)=>n+x.practised,0)});}
  for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30,part=ordered.filter(x=>x.day>=start&&x.day<=end);if(part.length)out.push({type:'month',label:'Month '+month,fromDay:start,toDay:end,generated:part.reduce((n,x)=>n+x.generated,0),practised:part.reduce((n,x)=>n+x.practised,0)});}
  return out;
}
function phrasalStatsV1_(concepts){const all=concepts||[],eligible=phrasalEligibleConceptsV1_(all),exposed=all.filter(x=>x.attempts.length>0).length;return {totalConcepts:all.length,exposed,exposurePercent:all.length?Math.round(exposed*1000/all.length)/10:0,due:eligible.filter(x=>x.due).length,weak:eligible.filter(x=>['Persistent Weak','Weak','Fragile'].includes(String(x.profile&&x.profile.state||''))).length,difficult:eligible.filter(x=>x.difficult).length,starred:eligible.filter(x=>x.starred).length,mastered:all.filter(x=>x.mastered).length,freshVariantChecks:eligible.filter(x=>x.mastered&&x.freshVariantCount).length,eligible:eligible.length};}
function getPhrasalMasteryHubV1(){const c=phrasalConceptsV1_(),stats=phrasalStatsV1_(c),today=phrasalDailyRowsV1_(todayKey_());return {version:EP_PHRASAL_VERSION,generatedAt:new Date().toISOString(),stats,today:{date:todayKey_(),count:today.length,ready:today.length>0,sourceId:phrasalDailySourceIdV1_(todayKey_())},available:{smart:stats.eligible,weak:stats.weak,difficult:stats.difficult,starred:stats.starred,random:stats.eligible,all:stats.eligible},sizes:[10,20,30,50],history:phrasalHistoryV1_()};}
function getPhrasalMasteryBatchV1(mode,count){return phrasalServeConceptsV1_(phrasalSelectConceptsV1_(phrasalConceptsV1_(),mode,count));}
function getPhrasalMasteryAuditV1(){const c=phrasalConceptsV1_(),seen=new Set(),dupes=[];c.forEach(x=>{if(seen.has(x.conceptId))dupes.push(x.conceptId);seen.add(x.conceptId)});const today=phrasalDailyRowsV1_(todayKey_()),todayConcepts=today.map(phrasalConceptKeyV1_),todayDup=todayConcepts.filter((x,i)=>todayConcepts.indexOf(x)!==i);return {ok:dupes.length===0&&todayDup.length===0,questions:phrasalQuestionsV1_().length,concepts:c.length,duplicateConcepts:dupes,todayCount:today.length,todayDuplicateConcepts:[...new Set(todayDup)],stats:phrasalStatsV1_(c)};}
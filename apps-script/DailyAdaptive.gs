const EP_DAILY_RATIONALE_V4='EP_DAILY_RATIONALE_V4';
const EP_DAILY_ROTATION_REFRESH_V5='EP_DAILY_ROTATION_REFRESH_20260828_V5';

function getBootstrapV3(){
  ensurePerformanceModuleColumn_();ensureLearningStatusMigration_();const cfg=config_(),all=allQuestions_(),daily=ensureDailyAdaptiveV3_(all,Number(cfg.DAILY_TARGET||120)),mastered=currentMasteredMapV2_(),status=statusMap_(),counts={};all.forEach(q=>{if(!isActive_(q)||mastered[q.id])return;const id=canonicalCategory_(q.topic);counts[id]=(counts[id]||0)+1;});const categories=table_(EP.sheets.categories).filter(r=>truthy_(r.Active)).sort((a,b)=>Number(a.Display_Order||99)-Number(b.Display_Order||99)).map(r=>({id:r.Category_ID,name:r.Category_Name,parent:r.Parent_Category,home:truthy_(r.Home_Visible),count:Number(counts[r.Category_ID]||0)})),today=todayKey_(),hinduToday=table_(EP.sheets.hindu).filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today).length,recallIds=recallIds_(status),recall=all.filter(q=>isActive_(q)&&!mastered[q.id]&&recallIds.has(q.id)).length,masteredCount=Object.keys(mastered).filter(id=>mastered[id]).length;return {schemaVersion:4,dailyTarget:Number(cfg.DAILY_TARGET||120),extraCounts:String(cfg.EXTRA_COUNTS||'10,20,30,50').split(',').map(Number).filter(Number.isFinite),categories,dailyInfo:daily.info,stats:{dailyTotal:daily.rows.length,dailyCompleted:daily.rows.filter(r=>String(r.Status||'').toLowerCase()==='completed').length,hinduToday,recall,mastered:masteredCount,totalActive:all.filter(q=>isActive_(q)&&!mastered[q.id]).length}};
}
function getDailyBatchV3(){
  const all=allQuestions_(),daily=ensureDailyAdaptiveV3_(all,Number(config_().DAILY_TARGET||120)),map=Object.fromEntries(all.map(q=>[q.id,q])),mastered=currentMasteredMapV2_(),batchDate=daily.rows.length?dateKey_(daily.rows[0].Quiz_Date):todayKey_(),rationale=dailyRationaleSnapshotV4_(daily.rows,all,batchDate),items=rationale.items||{};
  return daily.rows.filter(r=>String(r.Status||'').toLowerCase()!=='completed').map(r=>{const id=String(r.Question_ID||'').trim(),q=map[id];if(!q||!isActive_(q)||mastered[id])return null;const x=serveQuestion_(q),meta=items[id]||[String(r.Reason||'Mixed Revision'),''];x.selectionReason=String(meta[0]||r.Reason||'Mixed Revision');x.selectionReasonCode=dailyReasonCodeV4_(x.selectionReason);x.selectionSignals=String(meta[1]||'').split(',').filter(Boolean);return x;}).filter(Boolean);
}

function ensureDailyAdaptiveV3_(all,target){
  target=Math.max(1,Number(target||120));const today=todayKey_(),s=sheet_(EP.sheets.daily),mastered=currentMasteredMapV2_(),props=PropertiesService.getScriptProperties();let rows=table_(EP.sheets.daily).filter(r=>String(r.Question_ID||'').trim());rows=normalizeDailyRowsV3_(rows,all,mastered,s);rows=syncDailyCompletionsV3_(rows,s);
  if(props.getProperty(EP_DAILY_ROTATION_REFRESH_V5)!=='1'){
    if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,Math.max(7,s.getLastColumn())).clearContent();try{props.deleteProperty(EP_DAILY_RATIONALE_V4)}catch(e){}rows=createDailyAdaptiveV3_(all,target,today,s);props.setProperty(EP_DAILY_ROTATION_REFRESH_V5,'1');return {rows,info:dailyInfoAdaptiveV3_(rows,today,false,target)};
  }
  rows=repairSkippedDailyDateV2_(rows,s,today);const batchDate=rows.length?dateKey_(rows[0].Quiz_Date):'';
  if(batchDate&&batchDate!==today){const done=rows.filter(r=>String(r.Status||'').toLowerCase()==='completed').length;if(done<rows.length)return {rows,info:dailyInfoAdaptiveV3_(rows,batchDate,true,target)};archiveDailyV2_(rows,batchDate);if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,Math.max(7,s.getLastColumn())).clearContent();const nextDate=addDaysKeyV2_(batchDate,1);rows=createDailyAdaptiveV3_(all,target,nextDate,s);return {rows,info:dailyInfoAdaptiveV3_(rows,nextDate,nextDate!==today,target)};}
  if(batchDate===today&&rows.length)return {rows,info:dailyInfoAdaptiveV3_(rows,today,false,target)};rows=createDailyAdaptiveV3_(all,target,today,s);return {rows,info:dailyInfoAdaptiveV3_(rows,today,false,target)};
}
function normalizeDailyRowsV3_(rows,all,mastered,s){const map=Object.fromEntries(all.map(q=>[q.id,q]));rows.forEach((r,i)=>{const id=String(r.Question_ID||'').trim(),q=map[id],done=String(r.Status||'').toLowerCase()==='completed';if(!done&&(!q||!isActive_(q)||mastered[id])){s.getRange(i+2,5).setValue('Completed');r.Status='Completed';}});return rows;}
function syncDailyCompletionsV3_(rows,s){
  if(!rows.length)return rows;const facts=performanceFactsV2_(),byId=facts.byId||{};rows.forEach((r,i)=>{if(String(r.Status||'').toLowerCase()==='completed')return;const id=String(r.Question_ID||'').trim(),key=dateKey_(r.Quiz_Date);if(!id||!key)return;const p=key.split('-').map(Number),start=new Date(p[0],p[1]-1,p[2],0,0,0,0),hit=(byId[id]||[]).some(a=>a.ts>=start&&String(a.module||'').toLowerCase()==='daily');if(hit){s.getRange(i+2,5).setValue('Completed');r.Status='Completed';}});return rows;
}
function adaptiveCategoryPenaltyV3_(cat,bank,profiles){const ids=bank.filter(q=>learningCategoryKeyV2_(q)===cat).map(q=>q.id),seen=ids.map(id=>profiles[id]).filter(Boolean);if(!seen.length)return .5;const weak=seen.filter(p=>p.state==='Weak'||p.state==='Persistent Weak').length,retN=seen.reduce((n,p)=>n+p.retentionAttempts,0),retC=seen.reduce((n,p)=>n+p.retentionCorrect,0),first=seen.filter(p=>p.firstCorrect).length/seen.length,ret=retN?retC/retN:.5;return Math.max(0,Math.min(1,(weak/seen.length)*.5+(1-first)*.25+(1-ret)*.25));}
function dailyFlagEligibleV5_(p,key){if(!p||!p.attempts)return false;if(learningDueV3_(p,key))return true;const last=p.lastCheckpoint||p.lastAttempt;if(!(last instanceof Date)||isNaN(last))return false;const parts=String(key||todayKey_()).split('-').map(Number),end=new Date(parts[0],parts[1]-1,parts[2],23,59,59,999);return learningCalendarGapDaysV3_(last,end)>=3;}
function dailyPrimaryReasonV5_(q,p,key,stars,diff){
  if(p.attempts===0&&isGenuineBankQuestionV2_(q))return 'Controlled New';
  if(learningDueV3_(p,key)){
    if(p.state==='Persistent Weak')return 'Persistent Weak';
    if(p.state==='Weak')return 'Weak';
    if(p.state==='Fragile')return 'Fragile';
    if(p.state==='Learning')return 'Learning';
    return 'Due Spaced Revision';
  }
  if(stars[q.id]&&p.attempts>0&&dailyFlagEligibleV5_(p,key))return 'Marked Review';
  if(diff[q.id]&&p.attempts>0&&dailyFlagEligibleV5_(p,key))return 'Difficult Review';
  return '';
}
function dailyQuotaV5_(target){return {'Persistent Weak':Math.max(1,Math.floor(target*.22)),'Weak':Math.max(1,Math.floor(target*.18)),'Fragile':Math.max(1,Math.floor(target*.15)),'Due Spaced Revision':Math.max(1,Math.floor(target*.15)),'Learning':Math.max(1,Math.floor(target*.08)),'Marked Review':Math.max(1,Math.floor(target*.05)),'Difficult Review':Math.max(1,Math.floor(target*.05)),'Controlled New':Math.max(1,Math.floor(target*.10)),'Mixed Revision':Math.max(1,Math.floor(target*.02))};}
function dailyHardCapV5_(target){return {'Persistent Weak':Math.max(1,Math.ceil(target*.30)),'Weak':Math.max(1,Math.ceil(target*.25)),'Fragile':Math.max(1,Math.ceil(target*.20)),'Due Spaced Revision':Math.max(1,Math.ceil(target*.25)),'Learning':Math.max(1,Math.ceil(target*.15)),'Marked Review':Math.max(1,Math.ceil(target*.10)),'Difficult Review':Math.max(1,Math.ceil(target*.10)),'Controlled New':Math.max(1,Math.ceil(target*.15)),'Mixed Revision':Math.max(1,Math.ceil(target*.05))};}
function dailyReasonBaseScoreV5_(reason){return {'Persistent Weak':1000,'Weak':900,'Fragile':800,'Due Spaced Revision':720,'Learning':660,'Marked Review':640,'Difficult Review':630,'Controlled New':520,'Mixed Revision':300}[reason]||0;}
function dailyBalancedSelectV5_(scored,target){
  const quota=dailyQuotaV5_(target),cap=dailyHardCapV5_(target),groups={},selected=[],ids=new Set(),counts={};scored.forEach(x=>(groups[x.reason]||(groups[x.reason]=[])).push(x));Object.values(groups).forEach(g=>g.sort((a,b)=>b.score-a.score));
  const order=['Controlled New','Persistent Weak','Weak','Fragile','Due Spaced Revision','Learning','Marked Review','Difficult Review','Mixed Revision'];
  order.forEach(reason=>{const take=Math.min(quota[reason]||0,(groups[reason]||[]).length,target-selected.length);(groups[reason]||[]).slice(0,take).forEach(x=>{selected.push(x);ids.add(x.q.id);counts[reason]=(counts[reason]||0)+1;});});
  if(selected.length<target){scored.slice().sort((a,b)=>b.score-a.score).forEach(x=>{if(selected.length>=target||ids.has(x.q.id))return;const c=counts[x.reason]||0;if(c>=(cap[x.reason]||target))return;selected.push(x);ids.add(x.q.id);counts[x.reason]=c+1;});}
  return selected;
}
function createDailyAdaptiveV3_(all,target,batchDate,s){
  const facts=performanceFactsV2_(),profiles=learningProfilesV2_(facts),mastered=currentMasteredMapV2_(),stars=currentStarredMapV2_(),diff=centralDifficultMapV2_(),todayDaily=batchDate===todayKey_()?(facts.todayByModule.daily||new Set()):new Set(),base=all.filter(q=>isActive_(q)&&!mastered[q.id]&&!todayDaily.has(q.id)),genuine=base.filter(isGenuineBankQuestionV2_),penalty={};genuine.forEach(q=>{const c=learningCategoryKeyV2_(q);if(penalty[c]===undefined)penalty[c]=adaptiveCategoryPenaltyV3_(c,genuine,profiles)});const scored=[];
  base.forEach(q=>{const p=profiles[q.id]||learningProfileV2_([]),reason=dailyPrimaryReasonV5_(q,p,batchDate,stars,diff);if(!reason)return;const cat=learningCategoryKeyV2_(q),weight=(penalty[cat]||0)*70,overdue=learningDaysOverdueV3_(p,batchDate),flagBoost=(stars[q.id]?12:0)+(diff[q.id]?10:0),score=dailyReasonBaseScoreV5_(reason)+weight+Math.min(120,overdue*12)+flagBoost+Math.random()*20;scored.push({q,score,reason,signals:dailySignalCodesV4_(q,p,batchDate,stars,diff)});});
  const selected=dailyBalancedSelectV5_(scored,target);if(selected.length){const out=selected.map(x=>[x.q.id,Math.round(x.score),x.reason,batchDate,'New',x.q.topic||'',x.q.conceptId||'']);s.getRange(2,1,out.length,7).setValues(out);writeDailyRationaleV4_(batchDate,Object.fromEntries(selected.map(x=>[x.q.id,[x.reason,dailyEnsurePrimarySignalV4_(x.reason,x.signals).join(',')]])));}return table_(EP.sheets.daily).filter(r=>dateKey_(r.Quiz_Date)===batchDate&&String(r.Question_ID||'').trim());
}
function dailyDueV3_(p,key){return learningDueV3_(p,key);}
function dailyInfoAdaptiveV3_(rows,activeDate,pending,target){
  const x=dailyInfoV2_(rows,activeDate,pending,target),reasons=rows.map(r=>String(r.Reason||''));x.persistentWeakCount=reasons.filter(r=>r==='Persistent Weak').length;x.weakCount=reasons.filter(r=>r==='Weak').length;x.fragileCount=reasons.filter(r=>r==='Fragile').length;x.dueCount=reasons.filter(r=>r==='Due Spaced Revision').length;x.markedReviewCount=reasons.filter(r=>r==='Marked Review').length;x.difficultReviewCount=reasons.filter(r=>r==='Difficult Review').length;x.flaggedCount=x.markedReviewCount+x.difficultReviewCount;x.freshCount=reasons.filter(r=>r==='Controlled New').length;x.learningCount=reasons.filter(r=>r==='Learning').length;x.mixedCount=reasons.filter(r=>r==='Mixed Revision').length;x.selectionMixTotal=x.persistentWeakCount+x.weakCount+x.fragileCount+x.dueCount+x.flaggedCount+x.freshCount+x.learningCount+x.mixedCount;x.carryCount=x.flaggedCount;x.carryForwardRemaining=pending?rows.filter(r=>String(r.Status||'').toLowerCase()!=='completed').length:0;x.adaptive=true;x.targetIsMaximum=true;return x;
}

function dailyReasonCodeV4_(reason){return ({'Persistent Weak':'PW','Weak':'W','Fragile':'FR','Due Spaced Revision':'DUE','Marked Review':'STAR','Difficult Review':'DIFF','Controlled New':'NEW','Learning':'LEARN','Mixed Revision':'MIX'})[String(reason||'')]||'MIX';}
function dailySignalCodesV4_(q,p,key,stars,diff){const out=[];if(p.state==='Persistent Weak')out.push('PW');else if(p.state==='Weak')out.push('W');else if(p.state==='Fragile')out.push('FR');else if(p.state==='Learning')out.push('LEARN');if(p.attempts>0&&learningDueV3_(p,key))out.push('DUE');if(stars&&stars[q.id])out.push('STAR');if(diff&&diff[q.id])out.push('DIFF');if(p.attempts===0&&isGenuineBankQuestionV2_(q))out.push('NEW');if(!out.length)out.push('MIX');return [...new Set(out)];}
function dailyEnsurePrimarySignalV4_(reason,signals){const primary=dailyReasonCodeV4_(reason),out=(signals||[]).slice();if(!out.includes(primary))out.unshift(primary);return [...new Set(out)];}
function readDailyRationaleV4_(){try{const raw=PropertiesService.getScriptProperties().getProperty(EP_DAILY_RATIONALE_V4);if(!raw)return null;const x=JSON.parse(raw);return x&&x.date&&x.items?x:null}catch(e){return null}}
function writeDailyRationaleV4_(date,items){try{PropertiesService.getScriptProperties().setProperty(EP_DAILY_RATIONALE_V4,JSON.stringify({date:String(date||''),items:items||{}}))}catch(e){}return {date:String(date||''),items:items||{}};}
function dailyRationaleSnapshotV4_(rows,all,batchDate){
  rows=rows||[];const ids=rows.map(r=>String(r.Question_ID||'').trim()).filter(Boolean),saved=readDailyRationaleV4_();if(saved&&saved.date===String(batchDate||'')&&ids.every(id=>saved.items&&saved.items[id]))return saved;if(!ids.length)return {date:String(batchDate||''),items:{}};
  const facts=performanceFactsV2_(),profiles=learningProfilesV2_(facts),stars=currentStarredMapV2_(),diff=centralDifficultMapV2_(),qmap=Object.fromEntries((all||[]).map(q=>[q.id,q])),items={};rows.forEach(r=>{const id=String(r.Question_ID||'').trim(),q=qmap[id];if(!id||!q)return;const p=profiles[id]||learningProfileV2_([]),reason=String(r.Reason||'Mixed Revision'),signals=dailyEnsurePrimarySignalV4_(reason,dailySignalCodesV4_(q,p,batchDate,stars,diff));items[id]=[reason,signals.join(',')];});return writeDailyRationaleV4_(batchDate,items);
}

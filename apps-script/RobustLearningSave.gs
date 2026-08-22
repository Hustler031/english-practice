const EP_DERIVED_REPAIR_QUEUE_V3='EP_DERIVED_REPAIR_QUEUE_V3';

function centralServeMapsV3_(){return {stars:currentStarredMapV2_(),diff:centralDifficultMapV2_()};}
function enrichServedQuestionsV3_(served,maps){maps=maps||centralServeMapsV3_();return (served||[]).map(x=>{if(!x)return x;const id=String(x.id||'').trim();x.marked=!!maps.stars[id];x.difficult=!!maps.diff[id];return x;});}
function serveQuestionsCentralV3_(questions,maps){maps=maps||centralServeMapsV3_();return (questions||[]).map(q=>{const x=serveQuestion_(q);x.marked=!!maps.stars[q.id];x.difficult=!!maps.diff[q.id];return x;});}
function getPracticeBatchCentralV3(mode,options){return enrichServedQuestionsV3_(getPracticeBatch(mode,options));}
function getDailyBatchReliableV3(){return enrichServedQuestionsV3_(getDailyBatchV3());}
function getNewPracticeBatchCentralV3(category,kind,count){return enrichServedQuestionsV3_(getNewPracticeBatch(category,kind,count));}

function answeredAtV3_(value){const d=value instanceof Date?value:new Date(value||Date.now());return isNaN(d)?new Date():d;}
function appendDurableAttemptV3_(q,payload,isCorrect){
  payload=payload||{};const lock=LockService.getScriptLock();if(!lock.tryLock(5000))throw new Error('SAVE_BUSY_RETRY');
  try{
    ensurePerformanceModuleColumn_();const perf=sheet_(EP.sheets.performance),headers=perf.getRange(1,1,1,perf.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),id=q.id,attemptId=String(payload.attemptId||'').trim()||id+'-'+Date.now()+'-'+Math.random().toString(36).slice(2,8);
    if(performanceAttemptExistsV2_(perf,headers,attemptId))return {deduped:true,attemptId,now:answeredAtV3_(payload.answeredAt),module:String(payload.module||'practice').trim()||'practice'};
    const now=answeredAtV3_(payload.answeredAt),secs=Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(payload.timeSeconds||0))),module=String(payload.module||'practice').trim()||'practice',obj={Timestamp:now,Question_ID:id,Selected_Answer:String(payload.selectedKey||'').toUpperCase(),Correct:!!isCorrect,Time_Seconds:secs,Marked_Revision:!!payload.marked,Attempt_ID:attemptId,Topic:q.topic||'',Concept_ID:q.conceptId||'',Module:module};
    perf.appendRow(headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));SpreadsheetApp.flush();return {deduped:false,attemptId,now,module};
  }finally{lock.releaseLock();}
}

function derivedRepairQueueV3_(){const p=PropertiesService.getScriptProperties().getProperty(EP_DERIVED_REPAIR_QUEUE_V3);if(!p)return{};try{return JSON.parse(p)||{}}catch(e){return{}}}
function writeDerivedRepairQueueV3_(q){const props=PropertiesService.getScriptProperties(),keys=Object.keys(q||{});if(keys.length)props.setProperty(EP_DERIVED_REPAIR_QUEUE_V3,JSON.stringify(q));else props.deleteProperty(EP_DERIVED_REPAIR_QUEUE_V3);}
function queueDerivedRepairV3_(id,module){const q=derivedRepairQueueV3_();q[String(id||'').trim()]={module:String(module||'practice'),queuedAt:new Date().toISOString()};writeDerivedRepairQueueV3_(q);}
function repairLearningDerivedV3_(id,module){
  id=String(id||'').trim();const q=findQuestion_(id);if(!q)throw new Error('Question not found for derived repair');const facts=performanceFactsV2_(),profile=learningProfileV2_(facts.byId[id]||[]),lock=LockService.getScriptLock();if(!lock.tryLock(2500))throw new Error('DERIVED_BUSY_RETRY');
  try{writeStatusSummaryV2_(q,profile,undefined,facts);if(String(module||'').toLowerCase()==='daily')markDaily_(id);try{PropertiesService.getScriptProperties().deleteProperty(EP_LEARNING_PROGRESS_KEY)}catch(e){}return {ok:true,id,status:profile.state};}finally{lock.releaseLock();}
}
function repairPendingLearningDerivationsV3(limit){const q=derivedRepairQueueV3_(),ids=Object.keys(q).slice(0,Math.max(1,Math.min(25,Number(limit||5)))),failed=[];ids.forEach(id=>{try{repairLearningDerivedV3_(id,q[id]&&q[id].module);delete q[id]}catch(e){failed.push(id)}});writeDerivedRepairQueueV3_(q);return {ok:true,processed:ids.length-failed.length,failed:failed.length,pending:Object.keys(q).length};}

function submitAnswerV3(payload){
  payload=payload||{};const id=String(payload.questionId||'').trim(),q=findQuestion_(id);if(!q)throw new Error('Question not found');const selected=String(payload.selectedKey||'').toUpperCase();if(!['A','B','C','D'].includes(selected))throw new Error('Invalid answer');const correctKey=String(q.correct||'').toUpperCase(),isCorrect=selected===correctKey,saved=appendDurableAttemptV3_(q,payload,isCorrect);let derivedOk=true;
  try{repairLearningDerivedV3_(id,saved.module)}catch(e){derivedOk=false;queueDerivedRepairV3_(id,saved.module)}
  return {ok:true,durable:true,deduped:!!saved.deduped,attemptId:saved.attemptId,isCorrect,correctKey,derivedOk};
}
function submitHinduAnswerV3(payload){
  payload=payload||{};const raw=String(payload.questionId||'').trim(),id=resolveHinduQuestionId_(raw),q=findQuestion_(id);if(!q)throw new Error('Hindu question is not linked to the central question bank yet');const selected=String(payload.selectedKey||'').toUpperCase();if(!['A','B','C','D'].includes(selected))throw new Error('Invalid answer');payload=Object.assign({},payload,{questionId:id,module:'hindu'});const saved=appendDurableAttemptV3_(q,payload,!!payload.localCorrect);let derivedOk=true;
  try{repairLearningDerivedV3_(id,'hindu')}catch(e){derivedOk=false;queueDerivedRepairV3_(id,'hindu')}
  return {ok:true,durable:true,deduped:!!saved.deduped,attemptId:saved.attemptId,correct:!!payload.localCorrect,correctKey:String(payload.correctKey||''),derivedOk};
}

function setMarkedFastV3(questionId,marked){
  let id=String(questionId||'').trim();if(/^HINDU_/.test(id))id=resolveHinduQuestionId_(id)||id;const q=findQuestion_(id);if(!q)throw new Error('Question not found');const lock=LockService.getScriptLock();if(!lock.tryLock(2000))throw new Error('MARK_BUSY_RETRY');
  try{
    const s=sheet_(EP.sheets.status),headers=s.getRange(1,1,1,s.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),ix=n=>headers.indexOf(n),row=findRow_(s,Math.max(1,ix('Question_ID')+1),id),lastMarked=ix('Last_Marked')>=0?ix('Last_Marked')+1:11;
    if(row>1)s.getRange(row,lastMarked).setValue(!!marked);else{const obj={Question_ID:id,Attempts:0,Correct:0,Wrong:0,Accuracy:0,Marked_Count:0,Avg_Time:0,Last_Marked:!!marked,Status:'New',Topic:q.topic||'',Concept_ID:q.conceptId||'',Mastered:false,Recall_Check_Count:0};s.appendRow(headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));}
    try{CacheService.getScriptCache().remove(EP.cache.status)}catch(e){}return {ok:true,questionId:id,marked:!!marked};
  }finally{lock.releaseLock();}
}
function setHinduMarkedFastV3(questionId,marked){const raw=String(questionId||'').trim(),r=upsertHinduVocab_(raw,{marked:!!marked}),id=(r&&r.questionId)||resolveHinduQuestionId_(raw);if(id)setMarkedFastV3(id,!!marked);return Object.assign({},r||{},{ok:true,questionId:id,marked:!!marked});}

function getSaveReliabilityAuditV3(){const q=derivedRepairQueueV3_(),facts=performanceFactsV2_();return {pendingDerivedRepairs:Object.keys(q).length,duplicateAttemptIds:facts.duplicateAttemptIds||[],performanceAttempts:facts.all.length};}

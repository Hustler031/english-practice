const EP_ANSWER_BATCH_SIZE_V4=15;
const EP_DERIVED_REPAIR_BATCH_V4=25;

function answerBatchModuleV4_(payload,hindu){
  if(hindu)return'hindu';
  return String(payload&&payload.module||'practice').trim()||'practice';
}
function normalizeAnswerBatchItemV4_(item,qmap){
  item=item||{};const payload=Object.assign({},item.payload||item),endpoint=String(item.endpoint||''),rawId=String(payload.questionId||'').trim(),hindu=/hindu/i.test(endpoint)||String(payload.module||'').toLowerCase()==='hindu'||/^HINDU_/i.test(rawId);
  if(!rawId)throw new Error('Question ID required');const id=hindu?String(resolveHinduQuestionId_(rawId)||'').trim():rawId,q=qmap[id];if(!id||!q)throw new Error(hindu?'Hindu question is not linked to the central question bank yet':'Question not found');
  const selected=String(payload.selectedKey||'').toUpperCase();if(!['A','B','C','D'].includes(selected))throw new Error('Invalid answer');const attemptId=String(item.attemptId||payload.attemptId||'').trim();if(!attemptId)throw new Error('Attempt_ID required');
  const correctKey=String(q.correct||'').toUpperCase(),isCorrect=hindu?!!payload.localCorrect:selected===correctKey,module=answerBatchModuleV4_(payload,hindu),now=answeredAtV3_(payload.answeredAt),secs=Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(payload.timeSeconds||0)));
  return {attemptId,endpoint,hindu,payload,id,q,selected,correctKey,isCorrect,module,now,secs};
}
function queueDerivedRepairsV4_(items){
  const queue=derivedRepairQueueV3_(),now=new Date().toISOString();(items||[]).forEach(x=>{const id=String(x&&x.id||'').trim();if(!id)return;const module=String(x&&x.module||'practice'),prev=queue[id],merged=String(prev&&prev.module||'').toLowerCase()==='daily'||module.toLowerCase()==='daily'?'daily':module;queue[id]={module:merged,queuedAt:prev&&prev.queuedAt||now};});writeDerivedRepairQueueV3_(queue);return Object.keys(queue).length;
}
function submitAnswerBatchV4(items){
  const input=(Array.isArray(items)?items:[]).slice(0,EP_ANSWER_BATCH_SIZE_V4),results=input.map((item,i)=>({index:i,attemptId:String(item&&item.attemptId||item&&item.payload&&item.payload.attemptId||''),durable:false,deduped:false}));if(!input.length)return {ok:true,batchSize:0,durableCount:0,results};
  const all=allQuestions_(),qmap=Object.fromEntries(all.map(q=>[String(q.id||'').trim(),q])),valid=[];
  input.forEach((item,i)=>{try{const x=normalizeAnswerBatchItemV4_(item,qmap);x.index=i;valid.push(x);results[i].attemptId=x.attemptId;results[i].questionId=x.id;results[i].module=x.module;results[i].correctKey=x.hindu?String(x.payload.correctKey||x.correctKey):x.correctKey;results[i].isCorrect=x.isCorrect}catch(e){results[i].error=String(e&&e.message||e)}});
  if(!valid.length)return {ok:true,batchSize:input.length,durableCount:0,results};
  const lock=LockService.getScriptLock();if(!lock.tryLock(5000))throw new Error('SAVE_BUSY_RETRY');
  try{
    ensurePerformanceModuleColumn_();const perf=sheet_(EP.sheets.performance),headers=perf.getRange(1,1,1,perf.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),ai=headers.indexOf('Attempt_ID'),existing=new Set();
    if(ai>=0&&perf.getLastRow()>1)perf.getRange(2,ai+1,perf.getLastRow()-1,1).getValues().forEach(r=>{const id=String(r[0]||'').trim();if(id)existing.add(id)});
    const accepted=[],rows=[];valid.forEach(x=>{if(existing.has(x.attemptId)){results[x.index]=Object.assign(results[x.index],{durable:true,deduped:true});accepted.push(x);return}existing.add(x.attemptId);const obj={Timestamp:x.now,Question_ID:x.id,Selected_Answer:x.selected,Correct:!!x.isCorrect,Time_Seconds:x.secs,Marked_Revision:!!x.payload.marked,Attempt_ID:x.attemptId,Topic:x.q.topic||'',Concept_ID:x.q.conceptId||'',Module:x.module};rows.push(headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));accepted.push(x)});
    if(rows.length){const start=perf.getLastRow()+1;perf.getRange(start,1,rows.length,headers.length).setValues(rows);SpreadsheetApp.flush();}
    accepted.forEach(x=>{results[x.index]=Object.assign(results[x.index],{durable:true,deduped:existing.has(x.attemptId)&&!rows.length?true:results[x.index].deduped||false})});
    try{queueDerivedRepairsV4_(accepted)}catch(e){accepted.forEach(x=>{results[x.index].derivedQueued=false;results[x.index].derivedQueueError=String(e&&e.message||e)})}
  }finally{lock.releaseLock();}
  const durableCount=results.filter(r=>r&&r.durable===true).length;return {ok:true,batchSize:input.length,durableCount,results};
}
function repairPendingLearningDerivationsV4(limit){
  const queue=derivedRepairQueueV3_(),ids=Object.keys(queue).slice(0,Math.max(1,Math.min(EP_DERIVED_REPAIR_BATCH_V4,Number(limit||EP_DERIVED_REPAIR_BATCH_V4)))),failed=[];if(!ids.length)return {ok:true,processed:0,failed:0,pending:0};
  const lock=LockService.getScriptLock();if(!lock.tryLock(5000))return {ok:false,busy:true,processed:0,failed:0,pending:Object.keys(queue).length};
  try{
    const facts=performanceFactsV2_(),all=allQuestions_(),qmap=Object.fromEntries(all.map(q=>[String(q.id||'').trim(),q])),stars=currentStarredMapV2_();
    ids.forEach(id=>{try{const q=qmap[id];if(!q)throw new Error('Question not found for derived repair');const profile=learningProfileV2_(facts.byId[id]||[]);writeStatusSummaryV2_(q,profile,!!stars[id],facts);if(String(queue[id]&&queue[id].module||'').toLowerCase()==='daily')markDaily_(id);delete queue[id]}catch(e){failed.push(id)}});
    try{PropertiesService.getScriptProperties().deleteProperty(EP_LEARNING_PROGRESS_KEY)}catch(e){}
    writeDerivedRepairQueueV3_(queue);
  }finally{lock.releaseLock();}
  return {ok:true,processed:ids.length-failed.length,failed:failed.length,pending:Object.keys(queue).length,failedIds:failed};
}
function getAnswerBatchAuditV4(){return {batchSize:EP_ANSWER_BATCH_SIZE_V4,derivedRepairBatch:EP_DERIVED_REPAIR_BATCH_V4,outboxKey:'ep-answer-outbox-v3'};}

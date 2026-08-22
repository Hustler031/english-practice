const EP_STAR_STATUS_REPAIR_V4='EP_STAR_STATUS_REPAIR_V4';

function starStatusMetaV4_(id){
  const s=sheet_(EP.sheets.status),headers=s.getRange(1,1,1,s.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),qi=Math.max(0,headers.indexOf('Question_ID')),li=headers.indexOf('Last_Marked'),si=headers.indexOf('Status'),rows=[];
  if(s.getLastRow()>1){const found=s.getRange(2,qi+1,s.getLastRow()-1,1).createTextFinder(String(id||'').trim()).matchEntireCell(true).findAll();found.forEach(c=>rows.push(c.getRow()));}
  return {sheet:s,headers,qi,li:li>=0?li:10,si:si>=0?si:12,rows};
}

function starLatestEventV4_(id){
  const s=starredRevisionLogSheet_();if(s.getLastRow()<2)return null;const vals=s.getRange(2,1,s.getLastRow()-1,5).getValues();let latest=null;
  vals.forEach((r,i)=>{if(String(r[0]||'').trim()!==String(id||'').trim())return;const d=r[1] instanceof Date?r[1]:new Date(r[1]),t=isNaN(d)?0:d.getTime(),item={row:i+2,t,marked:String(r[4]||'').toUpperCase()!=='UNSTAR',action:String(r[4]||'').toUpperCase(),eventAt:isNaN(d)?new Date(0):d,date:dateKey_(r[2])||dateKey_(d),day:Number(r[3]||0)};if(!latest||t>latest.t||(t===latest.t&&item.row>latest.row))latest=item;});
  return latest;
}

function starCurrentStateV4_(id,meta){
  const ev=starLatestEventV4_(id);if(ev)return {marked:!!ev.marked,source:'event',event:ev};meta=meta||starStatusMetaV4_(id);let marked=false;
  meta.rows.forEach(r=>{const row=meta.sheet.getRange(r,1,1,meta.headers.length).getValues()[0];if(truthy_(row[meta.li])||String(row[meta.si]||'').toLowerCase()==='marked')marked=true;});
  return {marked,source:'status',event:null};
}

function queueStarStatusRepairV4_(id){
  const props=PropertiesService.getScriptProperties();let q={};try{q=JSON.parse(props.getProperty(EP_STAR_STATUS_REPAIR_V4)||'{}')||{}}catch(e){}q[String(id||'').trim()]=new Date().toISOString();props.setProperty(EP_STAR_STATUS_REPAIR_V4,JSON.stringify(q));
}
function starStatusRepairQueueV4_(){try{return JSON.parse(PropertiesService.getScriptProperties().getProperty(EP_STAR_STATUS_REPAIR_V4)||'{}')||{}}catch(e){return{}}}
function writeStarStatusRepairQueueV4_(q){const p=PropertiesService.getScriptProperties(),keys=Object.keys(q||{});if(keys.length)p.setProperty(EP_STAR_STATUS_REPAIR_V4,JSON.stringify(q));else p.deleteProperty(EP_STAR_STATUS_REPAIR_V4);}

function syncStarStatusV4_(q,marked,meta){
  meta=meta||starStatusMetaV4_(q.id);const s=meta.sheet,lastCol=meta.li+1;
  if(meta.rows.length){meta.rows.forEach(r=>s.getRange(r,lastCol).setValue(!!marked));}
  else{
    const obj={Question_ID:q.id,Attempts:0,Correct:0,Wrong:0,Accuracy:0,Marked_Count:0,Avg_Time:0,Last_Marked:!!marked,Status:'New',Topic:q.topic||'',Concept_ID:q.conceptId||'',Mastered:false,Recall_Check_Count:0};
    s.appendRow(meta.headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));
  }
  try{CacheService.getScriptCache().remove(EP.cache.status)}catch(e){}
  if(meta.rows.length>1)queueStarStatusRepairV4_(q.id);
  return {rows:meta.rows.length||1,duplicates:Math.max(0,meta.rows.length-1)};
}

function appendStarTransitionV4_(id,marked){
  const now=new Date(),date=starredRevisionActiveDate_(),day=starredRevisionActiveDay_();starredRevisionLogSheet_().appendRow([id,now,date,day,marked?'STAR':'UNSTAR']);return {eventAt:now,date,day,action:marked?'STAR':'UNSTAR'};
}

function setMarkedCentralV4(questionId,marked){
  let id=String(questionId||'').trim();if(/^HINDU_/.test(id)&&typeof resolveHinduQuestionId_==='function')id=resolveHinduQuestionId_(id)||id;const q=findQuestion_(id);if(!q)throw new Error('Question not found');const desired=!!marked,lock=LockService.getUserLock();lock.waitLock(10000);
  try{
    const meta=starStatusMetaV4_(id),before=starCurrentStateV4_(id,meta),changed=before.marked!==desired,event=changed?appendStarTransitionV4_(id,desired):before.event,sync=syncStarStatusV4_(q,desired,meta);SpreadsheetApp.flush();
    return {ok:true,durable:true,questionId:id,marked:desired,changed,eventAction:event&&event.action||'',statusRows:sync.rows,duplicateStatusRows:sync.duplicates};
  }finally{lock.releaseLock();}
}

function setHinduMarkedCentralV4(questionId,marked){
  const raw=String(questionId||'').trim(),r=upsertHinduVocab_(raw,{marked:!!marked}),id=(r&&r.questionId)||resolveHinduQuestionId_(raw);if(!id)throw new Error('Hindu question is not linked to the central question bank yet');const central=setMarkedCentralV4(id,!!marked);return Object.assign({},r||{},central,{questionId:id});
}

function duplicateStarStatusIdsV4_(limit){
  const s=sheet_(EP.sheets.status);if(s.getLastRow()<2)return[];const ids=s.getRange(2,1,s.getLastRow()-1,1).getValues().map(r=>String(r[0]||'').trim()),seen=new Set(),dup=[];ids.forEach(id=>{if(!id)return;if(seen.has(id)&&!dup.includes(id))dup.push(id);else seen.add(id)});return dup.slice(0,Math.max(1,Math.min(25,Number(limit||5))));
}

function repairPendingStarStatusDuplicatesV4(limit){
  const lock=LockService.getScriptLock();if(!lock.tryLock(3500))return {ok:true,deferred:true,repaired:0,pending:Object.keys(starStatusRepairQueueV4_()).length};
  try{
    const queued=starStatusRepairQueueV4_(),ids=[...new Set([...Object.keys(queued),...duplicateStarStatusIdsV4_(limit)])].slice(0,Math.max(1,Math.min(10,Number(limit||5))));if(!ids.length)return {ok:true,repaired:0,pending:0};const facts=performanceFactsV2_();let repaired=0;
    ids.forEach(id=>{try{const q=findQuestion_(id);if(!q){delete queued[id];return}const meta=statusRowsV2_(id);if(meta.rows.length>1){const profile=learningProfileV2_(facts.byId[id]||[]),marked=starCurrentStateV4_(id).marked;writeStatusSummaryV2_(q,profile,marked,facts);repaired++;}delete queued[id]}catch(e){queued[id]=new Date().toISOString();}});writeStarStatusRepairQueueV4_(queued);return {ok:true,repaired,pending:Object.keys(queued).length};
  }finally{lock.releaseLock();}
}

function getCentralStarAuditV4(){
  const s=sheet_(EP.sheets.status),statusIds=s.getLastRow()>1?s.getRange(2,1,s.getLastRow()-1,1).getValues().map(r=>String(r[0]||'').trim()).filter(Boolean):[],counts={};statusIds.forEach(id=>counts[id]=(counts[id]||0)+1);const duplicateIds=Object.keys(counts).filter(id=>counts[id]>1),log=starredRevisionLogSheet_(),vals=log.getLastRow()>1?log.getRange(2,1,log.getLastRow()-1,5).getValues():[],latest={},duplicateTransitions=[];
  vals.forEach((r,i)=>{const id=String(r[0]||'').trim(),action=String(r[4]||'').toUpperCase();if(!id)return;const prev=latest[id];if(prev&&prev.action===action)duplicateTransitions.push({id,action,row:i+2});latest[id]={action,row:i+2};});
  return {ok:true,duplicateStatusIds:duplicateIds.slice(0,100),duplicateStatusCount:duplicateIds.length,duplicateTransitionCount:duplicateTransitions.length,duplicateTransitions:duplicateTransitions.slice(0,100),pendingDuplicateRepairs:Object.keys(starStatusRepairQueueV4_()).length};
}

const EP_RETENTION_GAP_MS=24*60*60*1000;
const EP_MAX_ACTIVE_ANSWER_SECONDS=180;
const EP_PERFORMANCE_MODULE='Module';
const EP_LEARNING_PROGRESS_KEY='EP_LEARNING_PROGRESS_SNAPSHOT_V2';
const EP_LEARNING_MIGRATION_KEY='EP_LEARNING_STATUS_NORMALIZED_V3';
const EP_LEARNING_DAY_MS=24*60*60*1000;

function ensurePerformanceModuleColumn_(){
  const s=sheet_(EP.sheets.performance),last=Math.max(1,s.getLastColumn()),h=s.getRange(1,1,1,last).getValues()[0].map(x=>String(x||'').trim());
  let i=h.indexOf(EP_PERFORMANCE_MODULE);
  if(i<0){i=h.findIndex(x=>!x);if(i<0)i=last;s.getRange(1,i+1).setValue(EP_PERFORMANCE_MODULE);}
  return i+1;
}

function performanceFactsV2_(){
  const s=sheet_(EP.sheets.performance);ensurePerformanceModuleColumn_();
  const vals=s.getDataRange().getValues();if(vals.length<2)return {all:[],byId:{},seen:new Set(),todayByModule:{},duplicateAttemptIds:[]};
  const h=vals[0].map(x=>String(x||'').trim().toLowerCase());
  const ix=n=>h.indexOf(n),ti=Math.max(0,ix('timestamp')),qi=Math.max(1,ix('question_id')),ci=ix('correct')>=0?ix('correct'):3,si=ix('selected_answer')>=0?ix('selected_answer'):2,timei=ix('time_seconds')>=0?ix('time_seconds'):4,mi=ix('marked_revision')>=0?ix('marked_revision'):5,ai=ix('attempt_id')>=0?ix('attempt_id'):6,topici=ix('topic')>=0?ix('topic'):7,concepti=ix('concept_id')>=0?ix('concept_id'):8,modulei=ix('module');
  const all=[],byId={},seen=new Set(),seenAttempt=new Set(),duplicateAttemptIds=new Set(),todayByModule={},today=todayKey_();
  vals.slice(1).forEach((r,n)=>{
    const id=String(r[qi]||'').trim();if(!id)return;const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;
    const attemptId=String(r[ai]||'').trim(),dedupe=attemptId?('A|'+attemptId):('L|'+id+'|'+d.getTime()+'|'+String(r[si]||'')+'|'+String(r[ci]||''));
    if(seenAttempt.has(dedupe)){if(attemptId)duplicateAttemptIds.add(attemptId);return}seenAttempt.add(dedupe);
    const rawTime=Number(r[timei]||0),time=Number.isFinite(rawTime)&&rawTime>=0?rawTime:0;
    const a={id,ts:d,correct:truthy_(r[ci]),selected:String(r[si]||''),time,marked:truthy_(r[mi]),attemptId,topic:String(r[topici]||''),conceptId:String(r[concepti]||''),module:String(modulei>=0?r[modulei]||'':'').trim(),row:n+2};
    all.push(a);(byId[id]||(byId[id]=[])).push(a);seen.add(id);
    if(dateKey_(d)===today){const k=a.module||'legacy';if(!todayByModule[k])todayByModule[k]=new Set();todayByModule[k].add(id);}
  });
  all.sort((a,b)=>a.ts-b.ts);Object.keys(byId).forEach(id=>byId[id].sort((a,b)=>a.ts-b.ts));
  return {all,byId,seen,todayByModule,duplicateAttemptIds:[...duplicateAttemptIds]};
}

function learningStudyDayCheckpointsV3_(attempts){
  const seen=new Set(),out=[];
  (attempts||[]).slice().sort((a,b)=>a.ts-b.ts).forEach(a=>{const k=dateKey_(a.ts);if(!k||seen.has(k))return;seen.add(k);out.push(a);});
  return out;
}
function learningCalendarGapDaysV3_(a,b){
  const ad=new Date(a),bd=new Date(b);if(isNaN(ad)||isNaN(bd))return 0;
  const ak=dateKey_(ad).split('-').map(Number),bk=dateKey_(bd).split('-').map(Number),au=Date.UTC(ak[0],ak[1]-1,ak[2]),bu=Date.UTC(bk[0],bk[1]-1,bk[2]);return Math.max(0,Math.round((bu-au)/EP_LEARNING_DAY_MS));
}
function learningProfileV2_(attempts){
  attempts=(attempts||[]).slice().sort((a,b)=>a.ts-b.ts);const n=attempts.length;
  if(!n)return {state:'New',attempts:0,correct:0,wrong:0,firstCorrect:null,retentionAttempts:0,retentionCorrect:0,retentionWrong:0,retentionAccuracy:null,afterReviewAttempts:0,afterReviewCorrect:0,afterReviewAccuracy:null,lastCorrect:null,correctStreak:0,rawCorrectStreak:0,checkpointCount:0,checkpointCorrect:0,checkpointWrong:0,checkpointCorrectStreak:0,recentCheckpointWrong:0,lastCheckpoint:null,lastCheckpointCorrect:null,provenMastery:false};
  const correct=attempts.filter(a=>a.correct).length,wrong=n-correct,firstCorrect=!!attempts[0].correct,checkpoints=learningStudyDayCheckpointsV3_(attempts),retention=checkpoints.slice(1),checkpointCorrect=checkpoints.filter(a=>a.correct).length,checkpointWrong=checkpoints.length-checkpointCorrect;
  let rawStreak=0;for(let i=attempts.length-1;i>=0&&attempts[i].correct;i--)rawStreak++;
  let checkpointStreak=0;for(let i=checkpoints.length-1;i>=0&&checkpoints[i].correct;i--)checkpointStreak++;
  const chosen=new Set(checkpoints.map(a=>a.row||('T|'+a.ts.getTime()+'|'+a.attemptId))),after=attempts.filter(a=>!chosen.has(a.row||('T|'+a.ts.getTime()+'|'+a.attemptId))),retentionCorrect=retention.filter(a=>a.correct).length,retentionWrong=retention.length-retentionCorrect,retentionAccuracy=retention.length?retentionCorrect/retention.length:null,afterReviewCorrect=after.filter(a=>a.correct).length,afterReviewAccuracy=after.length?afterReviewCorrect/after.length:null,lastCheckpoint=checkpoints[checkpoints.length-1],lastCheckpointCorrect=!!lastCheckpoint.correct,recent=checkpoints.slice(-4),recentCheckpointWrong=recent.filter(a=>!a.correct).length;
  const repeatedRecentFailure=!lastCheckpointCorrect&&recentCheckpointWrong>=2;
  const lastGap=checkpoints.length>=2?learningCalendarGapDaysV3_(checkpoints[checkpoints.length-2].ts,lastCheckpoint.ts):0;
  const provenMastery=checkpointStreak>=4&&lastGap>=5;
  let state='Learning';
  if(!lastCheckpointCorrect)state=repeatedRecentFailure?'Persistent Weak':'Weak';
  else if(provenMastery)state='Proven Mastered';
  else if(checkpointStreak>=3)state='Strong';
  else if(checkpointWrong>0)state='Fragile';
  else state='Learning';
  return {state,attempts:n,correct,wrong,firstCorrect,retentionAttempts:retention.length,retentionCorrect,retentionWrong,retentionAccuracy,afterReviewAttempts:after.length,afterReviewCorrect,afterReviewAccuracy,lastCorrect:lastCheckpointCorrect,correctStreak:checkpointStreak,rawCorrectStreak:rawStreak,lastAttempt:attempts[n-1].ts,checkpointCount:checkpoints.length,checkpointCorrect,checkpointWrong,checkpointCorrectStreak:checkpointStreak,recentCheckpointWrong,lastCheckpoint:lastCheckpoint.ts,lastCheckpointCorrect,provenMastery};
}
function learningProfilesV2_(facts){facts=facts||performanceFactsV2_();const out={};Object.keys(facts.byId).forEach(id=>out[id]=learningProfileV2_(facts.byId[id]));return out;}
function learningPctV2_(n,d){return d?Math.round(1000*n/d)/10:0;}
function learningIntervalDaysV3_(p){
  if(!p||!p.attempts)return 0;
  if(p.state==='Persistent Weak'||p.state==='Weak')return 1;
  if(p.state==='Fragile')return Number(p.checkpointCorrectStreak||0)>=2?3:2;
  if(p.state==='Learning')return 1;
  if(p.state==='Strong')return 7;
  if(p.state==='Proven Mastered')return 30;
  return 7;
}
function learningNextReviewV3_(p){const raw=p&&(p.lastCheckpoint||p.lastAttempt),anchor=raw?new Date(raw):null,days=learningIntervalDaysV3_(p);return anchor&&!isNaN(anchor)&&days?new Date(anchor.getTime()+days*EP_LEARNING_DAY_MS):'';}
function learningDueV3_(p,key){if(!p||!p.attempts)return false;const target=learningNextReviewV3_(p);if(!(target instanceof Date)||isNaN(target))return false;const parts=String(key||todayKey_()).split('-').map(Number),end=new Date(parts[0],parts[1]-1,parts[2],23,59,59,999);return target<=end;}
function learningDaysOverdueV3_(p,key){if(!learningDueV3_(p,key))return 0;const next=learningNextReviewV3_(p),parts=String(key||todayKey_()).split('-').map(Number),end=new Date(parts[0],parts[1]-1,parts[2],23,59,59,999);return Math.max(0,Math.floor((end-next)/EP_LEARNING_DAY_MS));}

function currentMasteredMapV2_(){
  const out={},s=sheet_(EP.sheets.status);if(s.getLastRow()<2)return out;const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim().toLowerCase()),qi=h.indexOf('question_id'),mi=h.indexOf('mastered');
  vals.slice(1).forEach(r=>{const id=String(r[qi>=0?qi:0]||'').trim();if(id&&truthy_(r[mi>=0?mi:16]))out[id]=true;});return out;
}
function currentStarredMapV2_(){
  const out={},ss=ss_(),log=ss.getSheetByName(typeof STARRED_REVISION_LOG!=='undefined'?STARRED_REVISION_LOG:'Starred_Revision_Log'),latest={};
  if(log&&log.getLastRow()>1)log.getRange(2,1,log.getLastRow()-1,5).getValues().forEach(r=>{const id=String(r[0]||'').trim();if(!id)return;const d=r[1] instanceof Date?r[1]:new Date(r[1]);const t=isNaN(d)?0:d.getTime();if(!latest[id]||t>=latest[id].t)latest[id]={t,marked:String(r[4]||'').toUpperCase()!=='UNSTAR'};});
  Object.keys(latest).forEach(id=>out[id]=latest[id].marked);
  const s=sheet_(EP.sheets.status);if(s.getLastRow()>1){const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim().toLowerCase()),qi=h.indexOf('question_id'),li=h.indexOf('last_marked'),si=h.indexOf('status');vals.slice(1).forEach(r=>{const id=String(r[qi>=0?qi:0]||'').trim();if(!id||Object.prototype.hasOwnProperty.call(out,id))return;if(truthy_(r[li>=0?li:10])||String(r[si>=0?si:12]||'').toLowerCase()==='marked')out[id]=true;});}
  return out;
}
function statusRowsV2_(id){const s=sheet_(EP.sheets.status);if(s.getLastRow()<2)return {sheet:s,rows:[],headers:[]};const headers=s.getRange(1,1,1,s.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),found=s.getRange(2,1,s.getLastRow()-1,1).createTextFinder(String(id)).matchEntireCell(true).findAll();return {sheet:s,rows:found.map(c=>c.getRow()),headers};}

function writeStatusSummaryV2_(q,profile,markedOverride,facts){
  const id=q.id,meta=statusRowsV2_(id),s=meta.sheet,rows=meta.rows,h=meta.headers,idx=n=>h.indexOf(n),existing=rows.map(r=>s.getRange(r,1,1,h.length).getValues()[0]);
  const existingMastered=existing.some(r=>truthy_(r[idx('Mastered')>=0?idx('Mastered'):16])),masteredOn=(existing.map(r=>r[idx('Mastered_On')>=0?idx('Mastered_On'):17]).filter(Boolean).sort((a,b)=>new Date(b)-new Date(a))[0]||''),suppressed=(existing.map(r=>r[idx('Repeat_Suppressed_Until')>=0?idx('Repeat_Suppressed_Until'):18]).filter(Boolean)[0]||''),recall=Math.max(0,...existing.map(r=>Number(r[idx('Recall_Check_Count')>=0?idx('Recall_Check_Count'):19]||0)));
  const starMap=currentStarredMapV2_(),marked=markedOverride===undefined?!!starMap[id]:!!markedOverride,attempts=(facts&&facts.byId&&facts.byId[id])||performanceFactsV2_().byId[id]||[],validTimes=attempts.map(a=>Number(a.time||0)).filter(x=>x>0&&x<=EP_MAX_ACTIVE_ANSWER_SECONDS),avg=validTimes.length?validTimes.reduce((a,b)=>a+b,0)/validTimes.length:0,last=attempts.length?attempts[attempts.length-1]:null,markedCount=attempts.filter(a=>a.marked).length;
  const masteredDate=masteredOn?new Date(masteredOn):null,failedAfterMastery=!!(existingMastered&&last&&masteredDate&&!isNaN(masteredDate)&&last.ts>masteredDate&&!last.correct),persistentAfterMastery=existingMastered&&profile.state==='Persistent Weak',mastered=existingMastered&&!failedAfterMastery&&!persistentAfterMastery;
  const status=mastered?'Mastered':profile.state,next=mastered?'':learningNextReviewV3_(profile);
  const row=[id,profile.attempts,profile.correct,profile.wrong,profile.attempts?profile.correct/profile.attempts:0,markedCount,avg,last?last.ts:'',last?!!last.correct:'',last?Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(last.time||0))):0,marked,profile.correctStreak,status,next,q.topic||'',q.conceptId||'',mastered,mastered?masteredOn:'',mastered?suppressed:'',recall];
  let target=rows.length?rows[0]:s.getLastRow()+1;s.getRange(target,1,1,20).setValues([row]);if(rows.length>1)rows.slice(1).forEach(r=>s.getRange(r,1,1,20).clearContent());
  const qs=sheet_(EP.sheets.questions),qr=findRow_(qs,1,id);if(qr>1){qs.getRange(qr,18).setValue(status);if(profile.attempts){qs.getRange(qr,20).setValue(attempts[0].ts);qs.getRange(qr,21).setValue(last.ts);qs.getRange(qr,22).setValue(profile.attempts);}}
  try{CacheService.getScriptCache().remove(EP.cache.status)}catch(e){}return {row:target,duplicatesRemoved:Math.max(0,rows.length-1),mastered};
}

function reconcileLearningStatusV3_(){
  const s=sheet_(EP.sheets.status),headers=s.getRange(1,1,1,Math.max(20,s.getLastColumn())).getValues()[0].slice(0,20).map(x=>String(x||'').trim()),existing=s.getLastRow()>1?s.getRange(2,1,s.getLastRow()-1,20).getValues():[],idx=n=>headers.indexOf(n),old={},order=[];
  existing.forEach(r=>{const id=String(r[idx('Question_ID')>=0?idx('Question_ID'):0]||'').trim();if(!id)return;if(!old[id]){old[id]=[];order.push(id)}old[id].push(r);});
  const facts=performanceFactsV2_(),profiles=learningProfilesV2_(facts),qmap=Object.fromEntries(allQuestions_().map(q=>[q.id,q])),stars=currentStarredMapV2_();Object.keys(facts.byId).forEach(id=>{if(qmap[id]&&!old[id])order.push(id)});
  const rows=[];
  order.forEach(id=>{const q=qmap[id];if(!q)return;const prior=old[id]||[],p=profiles[id]||learningProfileV2_([]),attempts=facts.byId[id]||[],last=attempts.length?attempts[attempts.length-1]:null,existingMastered=prior.some(r=>truthy_(r[idx('Mastered')>=0?idx('Mastered'):16])),masteredOn=(prior.map(r=>r[idx('Mastered_On')>=0?idx('Mastered_On'):17]).filter(Boolean).sort((a,b)=>new Date(b)-new Date(a))[0]||''),suppressed=(prior.map(r=>r[idx('Repeat_Suppressed_Until')>=0?idx('Repeat_Suppressed_Until'):18]).filter(Boolean)[0]||''),recall=Math.max(0,...prior.map(r=>Number(r[idx('Recall_Check_Count')>=0?idx('Recall_Check_Count'):19]||0))),masteredDate=masteredOn?new Date(masteredOn):null,failedAfterMastery=!!(existingMastered&&last&&masteredDate&&!isNaN(masteredDate)&&last.ts>masteredDate&&!last.correct),mastered=existingMastered&&!failedAfterMastery&&p.state!=='Persistent Weak',times=attempts.map(a=>Number(a.time||0)).filter(x=>x>0&&x<=EP_MAX_ACTIVE_ANSWER_SECONDS),avg=times.length?times.reduce((a,b)=>a+b,0)/times.length:0,obj={Question_ID:id,Attempts:p.attempts,Correct:p.correct,Wrong:p.wrong,Accuracy:p.attempts?p.correct/p.attempts:0,Marked_Count:attempts.filter(a=>a.marked).length,Avg_Time:avg,Last_Attempt:last?last.ts:'',Last_Result:last?!!last.correct:'',Last_Time:last?Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(last.time||0))):0,Last_Marked:!!stars[id],Correct_Streak:p.correctStreak,Status:mastered?'Mastered':p.state,Next_Review:mastered?'':learningNextReviewV3_(p),Topic:q.topic||'',Concept_ID:q.conceptId||'',Mastered:mastered,Mastered_On:mastered?masteredOn:'',Repeat_Suppressed_Until:mastered?suppressed:'',Recall_Check_Count:recall};rows.push(headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));});
  if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,20).clearContent();if(rows.length)s.getRange(2,1,rows.length,20).setValues(rows);try{CacheService.getScriptCache().remove(EP.cache.status)}catch(e){}return {rows:rows.length};
}
function ensureLearningStatusMigration_(){
  const props=PropertiesService.getScriptProperties();if(props.getProperty(EP_LEARNING_MIGRATION_KEY)==='1')return;const lock=LockService.getScriptLock();if(!lock.tryLock(5000))return;try{if(props.getProperty(EP_LEARNING_MIGRATION_KEY)==='1')return;reconcileLearningStatusV3_();props.setProperty(EP_LEARNING_MIGRATION_KEY,'1');}finally{lock.releaseLock();}
}

function performanceAttemptExistsV2_(perf,headers,attemptId){const ai=headers.indexOf('Attempt_ID');return !!(attemptId&&ai>=0&&perf.getLastRow()>1&&perf.getRange(2,ai+1,perf.getLastRow()-1,1).createTextFinder(attemptId).matchEntireCell(true).findNext());}
function appendCentralAttemptV2_(q,payload,isCorrect){
  ensurePerformanceModuleColumn_();const perf=sheet_(EP.sheets.performance),headers=perf.getRange(1,1,1,perf.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),id=q.id,attemptId=String(payload.attemptId||'').trim()||id+'-'+Date.now()+'-'+Math.random().toString(36).slice(2,8);if(performanceAttemptExistsV2_(perf,headers,attemptId))return {deduped:true,attemptId};
  const now=new Date(),secs=Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(payload.timeSeconds||0))),module=String(payload.module||'practice').trim(),obj={Timestamp:now,Question_ID:id,Selected_Answer:String(payload.selectedKey||'').toUpperCase(),Correct:!!isCorrect,Time_Seconds:secs,Marked_Revision:!!payload.marked,Attempt_ID:attemptId,Topic:q.topic||'',Concept_ID:q.conceptId||'',Module:module};perf.appendRow(headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));return {deduped:false,attemptId,now,module};
}
function submitAnswerV2(payload){
  payload=payload||{};const lock=LockService.getScriptLock();lock.waitLock(15000);try{const id=String(payload.questionId||'').trim(),q=findQuestion_(id);if(!q)throw new Error('Question not found');const selected=String(payload.selectedKey||'').toUpperCase();if(!['A','B','C','D'].includes(selected))throw new Error('Invalid answer');const isCorrect=selected===String(q.correct||'').toUpperCase(),saved=appendCentralAttemptV2_(q,payload,isCorrect);if(saved.deduped)return {ok:true,deduped:true,correctKey:String(q.correct||'').toUpperCase()};const facts=performanceFactsV2_(),profile=learningProfileV2_(facts.byId[id]||[]);writeStatusSummaryV2_(q,profile,payload.marked,facts);if(saved.module==='daily')markDaily_(id);try{PropertiesService.getScriptProperties().deleteProperty(EP_LEARNING_PROGRESS_KEY)}catch(e){}return {ok:true,isCorrect,correctKey:String(q.correct||'').toUpperCase(),status:profile.state,nextReview:learningNextReviewV3_(profile)};}finally{lock.releaseLock();}
}
function submitHinduAnswerV2(payload){
  payload=payload||{};const raw=String(payload.questionId||'').trim(),id=resolveHinduQuestionId_(raw),q=findQuestion_(id);if(!q)throw new Error('Hindu question is not linked to the central question bank yet');const selected=String(payload.selectedKey||'').toUpperCase();if(!['A','B','C','D'].includes(selected))throw new Error('Invalid answer');const lock=LockService.getScriptLock();lock.waitLock(15000);try{payload=Object.assign({},payload,{questionId:id,module:'hindu'});const saved=appendCentralAttemptV2_(q,payload,!!payload.localCorrect);if(saved.deduped)return {ok:true,deduped:true,correctKey:String(payload.correctKey||'')};const facts=performanceFactsV2_(),profile=learningProfileV2_(facts.byId[id]||[]);writeStatusSummaryV2_(q,profile,undefined,facts);try{PropertiesService.getScriptProperties().deleteProperty(EP_LEARNING_PROGRESS_KEY)}catch(e){}return {ok:true,correct:!!payload.localCorrect,correctKey:String(payload.correctKey||''),status:profile.state,nextReview:learningNextReviewV3_(profile)};}finally{lock.releaseLock();}
}
function getHinduQuizV2(){const diff=centralDifficultMapV2_(),stars=currentStarredMapV2_();return getHinduQuiz().map(x=>{const id=resolveHinduQuestionId_(x.id);x.centralQuestionId=id;x.difficult=!!diff[id];x.marked=!!stars[id];return x;});}
function getHinduPracticeProgress(){const words=getHinduToday(),facts=performanceFactsV2_(),counts=words.map(w=>{const id=resolveHinduQuestionId_(String(w.id||''));return id?(facts.byId[id]||[]).filter(a=>a.module==='hindu').length:0}),total=words.length,roundsCompleted=counts.length?Math.min(...counts):0;return {total,roundsCompleted,nextRound:roundsCompleted+1};}
function setMarkedV2(questionId,marked){let id=String(questionId||'').trim();if(/^HINDU_/.test(id))id=resolveHinduQuestionId_(id)||id;const q=findQuestion_(id);if(!q)throw new Error('Question not found');const lock=LockService.getScriptLock();lock.waitLock(10000);try{const facts=performanceFactsV2_(),profile=learningProfileV2_(facts.byId[id]||[]);writeStatusSummaryV2_(q,profile,!!marked,facts);return {ok:true,questionId:id,marked:!!marked};}finally{lock.releaseLock();}}
function setHinduMarkedV2(id,marked){const r=upsertHinduVocab_(id,{marked:!!marked});if(r.questionId)setMarkedV2(r.questionId,!!marked);return r;}
function setCentralDifficult(questionId,difficult){let id=String(questionId||'').trim();if(/^HINDU_/.test(id))id=resolveHinduQuestionId_(id)||id;const q=findQuestion_(id);if(!q||!isActive_(q))return {ok:false,reason:'not-active-question'};if(currentMasteredMapV2_()[id])return {ok:false,reason:'mastered'};const s=starredRevisionDifficultSheet_(),row=findRow_(s,1,id),now=new Date(),value=!!difficult;if(row>1)s.getRange(row,2,1,2).setValues([[value,now]]);else s.appendRow([id,value,now]);return {ok:true,questionId:id,difficult:value};}
function centralDifficultMapV2_(){return starredRevisionDifficultMap_();}
function getCentralDifficultBatch(){const diff=centralDifficultMapV2_(),mastered=currentMasteredMapV2_(),stars=currentStarredMapV2_();const pool=shuffle_(allQuestions_().filter(q=>isActive_(q)&&!mastered[q.id]&&!!diff[q.id]));return pool.map(q=>{const x=serveQuestion_(q);x.difficult=true;x.marked=!!stars[q.id];return x;});}
function markMasteredV2(questionId){let id=String(questionId||'').trim();if(/^HINDU_/.test(id))id=resolveHinduQuestionId_(id)||id;const q=findQuestion_(id);if(!q)throw new Error('Question not found');const p=learningProfileV2_((performanceFactsV2_().byId[id]||[]));if(!p.provenMastery)throw new Error('Retention not proven yet');return markMastered(id);}

function isGenuineBankQuestionV2_(q){const id=String(q.id||''),topic=String(q.topic||'').toLowerCase(),source=String(q.sourceId||q.sourceFile||'').toLowerCase();if(!isActive_(q))return false;if(/^MYWORD_/i.test(id)||/^HV20\d{6}_/i.test(id))return false;if(topic.includes('the hindu')||source.includes('my_saved_words')||source.includes('my saved words')||source.includes('the hindu daily')||source.includes('daily news vocabulary'))return false;return true;}
function learningCategoryKeyV2_(q){const t=String(q&&q.topic||'').trim(),low=t.toLowerCase();if(low.includes('fixed preposition'))return'FIXED_PREPOSITION';if(low.includes('fields of study')||low.includes('field of study'))return'FIELDS_OF_STUDY';return canonicalCategory_(t);}
function learningCategoryNameV2_(key,q){if(key==='FIXED_PREPOSITION')return'Fixed Preposition';if(key==='FIELDS_OF_STUDY')return'Fields of Study';return typeof progressCategoryName_==='function'?progressCategoryName_(key,q&&q.topic):String(q&&q.topic||key||'Other');}
function learningBankEligibleQuestionsV2_(all,facts,mastered){facts=facts||performanceFactsV2_();mastered=mastered||currentMasteredMapV2_();return (all||allQuestions_()).filter(q=>isGenuineBankQuestionV2_(q)&&(!mastered[q.id]||facts.seen.has(q.id)));}

function getLearningDataAudit(){
  const s=sheet_(EP.sheets.status),dup={},zeroMarked=[];if(s.getLastRow()>1){const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim()),qi=h.indexOf('Question_ID'),ai=h.indexOf('Attempts'),li=h.indexOf('Last_Marked');vals.slice(1).forEach((r,i)=>{const id=String(r[qi>=0?qi:0]||'').trim();if(!id)return;(dup[id]||(dup[id]=[])).push(i+2);if(Number(r[ai>=0?ai:1]||0)===0&&truthy_(r[li>=0?li:10]))zeroMarked.push(id);});}
  const facts=performanceFactsV2_(),malformed=[],missing=[],conceptCats={};allQuestions_().forEach(q=>{const c=String(q.conceptId||'').trim();if(!c){missing.push(q.id);return}if(c.length>80||/\s{2,}/.test(c)||/[.!?].*\s/.test(c)||c.split(/\s+/).length>6)malformed.push({id:q.id,conceptId:c});const k=c.toUpperCase(),cat=learningCategoryKeyV2_(q);(conceptCats[k]||(conceptCats[k]=new Set())).add(cat);});const cross=Object.keys(conceptCats).filter(k=>conceptCats[k].size>1);return {duplicateStatusIds:Object.keys(dup).filter(id=>dup[id].length>1),zeroAttemptMarkedIds:[...new Set(zeroMarked)],duplicateAttemptIds:facts.duplicateAttemptIds,timingOutliers:facts.all.filter(a=>a.time>EP_MAX_ACTIVE_ANSWER_SECONDS).length,malformedConcepts:malformed.slice(0,100),missingConceptIds:missing.slice(0,100),crossCategoryConceptIds:cross.slice(0,100),counts:{duplicateStatus:Object.keys(dup).filter(id=>dup[id].length>1).length,zeroAttemptMarked:new Set(zeroMarked).size,duplicateAttempts:facts.duplicateAttemptIds.length,malformedConcepts:malformed.length,missingConceptIds:missing.length,crossCategoryConceptIds:cross.length}};
}

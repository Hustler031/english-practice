const EP_RETENTION_GAP_MS=24*60*60*1000;
const EP_MAX_ACTIVE_ANSWER_SECONDS=600;
const EP_PERFORMANCE_MODULE='Module';
const EP_LEARNING_PROGRESS_KEY='EP_LEARNING_PROGRESS_SNAPSHOT_V2';
const EP_LEARNING_MIGRATION_KEY='EP_LEARNING_STATUS_NORMALIZED_V2';

function ensurePerformanceModuleColumn_(){
  const s=sheet_(EP.sheets.performance),last=Math.max(1,s.getLastColumn()),h=s.getRange(1,1,1,last).getValues()[0].map(x=>String(x||'').trim());
  let i=h.indexOf(EP_PERFORMANCE_MODULE);
  if(i<0){i=h.findIndex(x=>!x);if(i<0)i=last;s.getRange(1,i+1).setValue(EP_PERFORMANCE_MODULE);}
  return i+1;
}

function performanceFactsV2_(){
  const s=sheet_(EP.sheets.performance);ensurePerformanceModuleColumn_();
  const vals=s.getDataRange().getValues();if(vals.length<2)return {all:[],byId:{},seen:new Set(),todayByModule:{}};
  const h=vals[0].map(x=>String(x||'').trim().toLowerCase());
  const ix=n=>h.indexOf(n),ti=Math.max(0,ix('timestamp')),qi=Math.max(1,ix('question_id')),ci=ix('correct')>=0?ix('correct'):3,si=ix('selected_answer')>=0?ix('selected_answer'):2,timei=ix('time_seconds')>=0?ix('time_seconds'):4,mi=ix('marked_revision')>=0?ix('marked_revision'):5,ai=ix('attempt_id')>=0?ix('attempt_id'):6,topici=ix('topic')>=0?ix('topic'):7,concepti=ix('concept_id')>=0?ix('concept_id'):8,modulei=ix('module');
  const all=[],byId={},seen=new Set(),seenAttempt=new Set(),todayByModule={},today=todayKey_();
  vals.slice(1).forEach((r,n)=>{
    const id=String(r[qi]||'').trim();if(!id)return;const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;
    const attemptId=String(r[ai]||'').trim(),dedupe=attemptId?('A|'+attemptId):('L|'+id+'|'+d.getTime()+'|'+n);if(seenAttempt.has(dedupe))return;seenAttempt.add(dedupe);
    const a={id,ts:d,correct:truthy_(r[ci]),selected:String(r[si]||''),time:Number(r[timei]||0),marked:truthy_(r[mi]),attemptId,topic:String(r[topici]||''),conceptId:String(r[concepti]||''),module:String(modulei>=0?r[modulei]||'':'').trim(),row:n+2};
    all.push(a);(byId[id]||(byId[id]=[])).push(a);seen.add(id);
    if(dateKey_(d)===today){const k=a.module||'legacy';if(!todayByModule[k])todayByModule[k]=new Set();todayByModule[k].add(id);}
  });
  all.sort((a,b)=>a.ts-b.ts);Object.keys(byId).forEach(id=>byId[id].sort((a,b)=>a.ts-b.ts));
  return {all,byId,seen,todayByModule};
}

function learningProfileV2_(attempts){
  attempts=(attempts||[]).slice().sort((a,b)=>a.ts-b.ts);const n=attempts.length;
  if(!n)return {state:'New',attempts:0,correct:0,wrong:0,firstCorrect:null,retentionAttempts:0,retentionCorrect:0,retentionWrong:0,retentionAccuracy:null,afterReviewAttempts:0,afterReviewCorrect:0,afterReviewAccuracy:null,lastCorrect:null,correctStreak:0,provenMastery:false};
  const correct=attempts.filter(a=>a.correct).length,wrong=n-correct,firstCorrect=!!attempts[0].correct;let retentionAttempts=0,retentionCorrect=0,retentionWrong=0,afterReviewAttempts=0,afterReviewCorrect=0,streak=0;
  attempts.forEach((a,i)=>{if(a.correct)streak++;else streak=0;if(i===0)return;const gap=a.ts-attempts[i-1].ts;if(gap>=EP_RETENTION_GAP_MS){retentionAttempts++;if(a.correct)retentionCorrect++;else retentionWrong++;}else{afterReviewAttempts++;if(a.correct)afterReviewCorrect++;}});
  const retentionAccuracy=retentionAttempts?retentionCorrect/retentionAttempts:null,afterReviewAccuracy=afterReviewAttempts?afterReviewCorrect/afterReviewAttempts:null,lastCorrect=!!attempts[n-1].correct;
  const persistent=wrong>=3||retentionWrong>=2;let state='Learning';
  if(persistent)state='Persistent Weak';
  else if(!lastCorrect||(wrong>0&&correct===0))state='Weak';
  else if(wrong>0&&(retentionCorrect<2||retentionAttempts<2))state='Fragile';
  else if(n===1)state='Learning';
  else if(retentionCorrect>=2&&retentionAccuracy!==null&&retentionAccuracy>=.8)state='Strong';
  else if(retentionAttempts===0)state='Fragile';
  else if(retentionAccuracy!==null&&retentionAccuracy<.7)state='Weak';
  else state='Fragile';
  const spaced=attempts.filter((a,i)=>i>0&&a.ts-attempts[i-1].ts>=EP_RETENTION_GAP_MS),lastTwoSpaced=spaced.slice(-2);
  const provenMastery=n>=3&&retentionCorrect>=2&&retentionAccuracy!==null&&retentionAccuracy>=.8&&lastCorrect&&lastTwoSpaced.length>=2&&lastTwoSpaced.every(a=>a.correct);
  return {state,attempts:n,correct,wrong,firstCorrect,retentionAttempts,retentionCorrect,retentionWrong,retentionAccuracy,afterReviewAttempts,afterReviewCorrect,afterReviewAccuracy,lastCorrect,correctStreak:streak,lastAttempt:attempts[n-1].ts,provenMastery};
}

function learningProfilesV2_(facts){facts=facts||performanceFactsV2_();const out={};Object.keys(facts.byId).forEach(id=>out[id]=learningProfileV2_(facts.byId[id]));return out;}
function learningPctV2_(n,d){return d?Math.round(1000*n/d)/10:0;}

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

function statusRowsV2_(id){
  const s=sheet_(EP.sheets.status);if(s.getLastRow()<2)return {sheet:s,rows:[],headers:[]};const headers=s.getRange(1,1,1,s.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),found=s.getRange(2,1,s.getLastRow()-1,1).createTextFinder(String(id)).matchEntireCell(true).findAll();return {sheet:s,rows:found.map(c=>c.getRow()),headers};
}

function writeStatusSummaryV2_(q,profile,markedOverride,facts){
  const id=q.id,meta=statusRowsV2_(id),s=meta.sheet,rows=meta.rows,h=meta.headers,idx=n=>h.indexOf(n),existing=rows.map(r=>s.getRange(r,1,1,h.length).getValues()[0]);
  const mastered=existing.some(r=>truthy_(r[idx('Mastered')>=0?idx('Mastered'):16])),masteredOn=(existing.map(r=>r[idx('Mastered_On')>=0?idx('Mastered_On'):17]).filter(Boolean).sort((a,b)=>new Date(b)-new Date(a))[0]||''),suppressed=(existing.map(r=>r[idx('Repeat_Suppressed_Until')>=0?idx('Repeat_Suppressed_Until'):18]).filter(Boolean)[0]||''),recall=Math.max(0,...existing.map(r=>Number(r[idx('Recall_Check_Count')>=0?idx('Recall_Check_Count'):19]||0)));
  const starMap=currentStarredMapV2_(),marked=markedOverride===undefined?!!starMap[id]:!!markedOverride,attempts=(facts&&facts.byId&&facts.byId[id])||performanceFactsV2_().byId[id]||[],validTimes=attempts.map(a=>Number(a.time||0)).filter(x=>x>0&&x<=EP_MAX_ACTIVE_ANSWER_SECONDS),avg=validTimes.length?validTimes.reduce((a,b)=>a+b,0)/validTimes.length:0,last=attempts.length?attempts[attempts.length-1]:null,markedCount=attempts.filter(a=>a.marked).length;
  const status=mastered?'Mastered':profile.state,next=last?new Date(last.ts.getTime()+({"Persistent Weak":1,"Weak":1,"Fragile":2,"Learning":4,"Strong":14}[profile.state]||4)*86400000):'';
  const row=[id,profile.attempts,profile.correct,profile.wrong,profile.attempts?profile.correct/profile.attempts:0,markedCount,avg,last?last.ts:'',last?!!last.correct:'',last?Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(last.time||0))):0,marked,profile.correctStreak,status,next,q.topic||'',q.conceptId||'',mastered,masteredOn,suppressed,recall];
  let target=rows.length?rows[0]:s.getLastRow()+1;s.getRange(target,1,1,20).setValues([row]);if(rows.length>1)rows.slice(1).forEach(r=>s.getRange(r,1,1,20).clearContent());
  const qs=sheet_(EP.sheets.questions),qr=findRow_(qs,1,id);if(qr>1){qs.getRange(qr,18).setValue(mastered?'Mastered':profile.state);if(profile.attempts){qs.getRange(qr,20).setValue(attempts[0].ts);qs.getRange(qr,21).setValue(last.ts);qs.getRange(qr,22).setValue(profile.attempts);}}
  try{CacheService.getScriptCache().remove(EP.cache.status)}catch(e){}return {row:target,duplicatesRemoved:Math.max(0,rows.length-1)};
}

function ensureLearningStatusMigration_(){
  const props=PropertiesService.getScriptProperties();if(props.getProperty(EP_LEARNING_MIGRATION_KEY)==='1')return;
  const lock=LockService.getScriptLock();if(!lock.tryLock(5000))return;try{if(props.getProperty(EP_LEARNING_MIGRATION_KEY)==='1')return;const s=sheet_(EP.sheets.status),groups={};if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,1).getValues().forEach((r,i)=>{const id=String(r[0]||'').trim();if(id)(groups[id]||(groups[id]=[])).push(i+2);});const facts=performanceFactsV2_(),profiles=learningProfilesV2_(facts),qmap=Object.fromEntries(allQuestions_().map(q=>[q.id,q])),stars=currentStarredMapV2_();Object.keys(groups).filter(id=>groups[id].length>1&&qmap[id]).forEach(id=>writeStatusSummaryV2_(qmap[id],profiles[id]||learningProfileV2_([]),!!stars[id],facts));props.setProperty(EP_LEARNING_MIGRATION_KEY,'1');}finally{lock.releaseLock();}
}

function submitAnswerV2(payload){
  payload=payload||{};const lock=LockService.getScriptLock();lock.waitLock(15000);try{ensurePerformanceModuleColumn_();const id=String(payload.questionId||'').trim(),q=findQuestion_(id);if(!q)throw new Error('Question not found');const selected=String(payload.selectedKey||'').toUpperCase();if(!['A','B','C','D'].includes(selected))throw new Error('Invalid answer');const attemptId=String(payload.attemptId||'').trim()||id+'-'+Date.now()+'-'+Math.random().toString(36).slice(2,8),perf=sheet_(EP.sheets.performance),headers=perf.getRange(1,1,1,perf.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),ai=headers.indexOf('Attempt_ID');if(ai>=0&&perf.getLastRow()>1&&perf.getRange(2,ai+1,perf.getLastRow()-1,1).createTextFinder(attemptId).matchEntireCell(true).findNext())return {ok:true,deduped:true,correctKey:String(q.correct||'').toUpperCase()};const now=new Date(),isCorrect=selected===String(q.correct||'').toUpperCase(),secs=Math.min(EP_MAX_ACTIVE_ANSWER_SECONDS,Math.max(0,Number(payload.timeSeconds||0))),module=String(payload.module||'practice').trim();const obj={Timestamp:now,Question_ID:id,Selected_Answer:selected,Correct:isCorrect,Time_Seconds:secs,Marked_Revision:!!payload.marked,Attempt_ID:attemptId,Topic:q.topic||'',Concept_ID:q.conceptId||'',Module:module};perf.appendRow(headers.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));const facts=performanceFactsV2_(),profile=learningProfileV2_(facts.byId[id]||[]);writeStatusSummaryV2_(q,profile,payload.marked,facts);if(module==='daily')markDaily_(id);try{PropertiesService.getScriptProperties().deleteProperty(EP_LEARNING_PROGRESS_KEY)}catch(e){}return {ok:true,isCorrect,correctKey:String(q.correct||'').toUpperCase(),status:profile.state,nextReview:profile.lastAttempt?new Date(profile.lastAttempt.getTime()+86400000):''};}finally{lock.releaseLock();}
}

function setMarkedV2(questionId,marked){
  const id=String(questionId||'').trim(),q=findQuestion_(id);if(!q)throw new Error('Question not found');const lock=LockService.getScriptLock();lock.waitLock(10000);try{const facts=performanceFactsV2_(),profile=learningProfileV2_(facts.byId[id]||[]);writeStatusSummaryV2_(q,profile,!!marked,facts);return {ok:true,questionId:id,marked:!!marked};}finally{lock.releaseLock();}
}
function setHinduMarkedV2(id,marked){const r=upsertHinduVocab_(id,{marked:!!marked});if(r.questionId)setMarkedV2(r.questionId,!!marked);return r;}

function setCentralDifficult(questionId,difficult){
  const id=String(questionId||'').trim(),q=findQuestion_(id);if(!q||!isActive_(q))return {ok:false,reason:'not-active-question'};if(currentMasteredMapV2_()[id])return {ok:false,reason:'mastered'};const s=starredRevisionDifficultSheet_(),row=findRow_(s,1,id),now=new Date(),value=!!difficult;if(row>1)s.getRange(row,2,1,2).setValues([[value,now]]);else s.appendRow([id,value,now]);return {ok:true,questionId:id,difficult:value};
}
function centralDifficultMapV2_(){return starredRevisionDifficultMap_();}
function getCentralDifficultBatch(){const diff=centralDifficultMapV2_(),mastered=currentMasteredMapV2_();const pool=shuffle_(allQuestions_().filter(q=>isActive_(q)&&!mastered[q.id]&&!!diff[q.id]));return pool.map(q=>{const x=serveQuestion_(q);x.difficult=true;return x;});}

function markMasteredV2(questionId){const id=String(questionId||'').trim(),q=findQuestion_(id);if(!q)throw new Error('Question not found');const p=learningProfileV2_((performanceFactsV2_().byId[id]||[]));if(!p.provenMastery)throw new Error('Retention not proven yet');return markMastered(id);}

function isGenuineBankQuestionV2_(q){const id=String(q.id||''),topic=String(q.topic||'').toLowerCase(),source=String(q.sourceId||q.sourceFile||'').toLowerCase();if(!isActive_(q))return false;if(/^MYWORD_/i.test(id)||/^HV20\d{6}_/i.test(id))return false;if(topic.includes('the hindu')||source.includes('my_saved_words')||source.includes('my saved words')||source.includes('the hindu daily')||source.includes('daily news vocabulary'))return false;return true;}

function getLearningDataAudit(){
  const s=sheet_(EP.sheets.status),dup={},zeroMarked=[];if(s.getLastRow()>1){const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim()),qi=h.indexOf('Question_ID'),ai=h.indexOf('Attempts'),li=h.indexOf('Last_Marked');vals.slice(1).forEach((r,i)=>{const id=String(r[qi>=0?qi:0]||'').trim();if(!id)return;(dup[id]||(dup[id]=[])).push(i+2);if(Number(r[ai>=0?ai:1]||0)===0&&truthy_(r[li>=0?li:10]))zeroMarked.push(id);});}
  const facts=performanceFactsV2_(),attemptIds={},duplicateAttempts=[];facts.all.forEach(a=>{if(!a.attemptId)return;if(attemptIds[a.attemptId])duplicateAttempts.push(a.attemptId);attemptIds[a.attemptId]=1;});const malformed=[],missing=[],conceptCats={};allQuestions_().forEach(q=>{const c=String(q.conceptId||'').trim();if(!c){missing.push(q.id);return}if(c.length>80||/\s/.test(c)||!/^[A-Za-z0-9_.:-]+$/.test(c))malformed.push({id:q.id,conceptId:c});const k=c.toUpperCase(),cat=canonicalCategory_(q.topic);(conceptCats[k]||(conceptCats[k]=new Set())).add(cat);});const cross=Object.keys(conceptCats).filter(k=>conceptCats[k].size>1);return {duplicateStatusIds:Object.keys(dup).filter(id=>dup[id].length>1),zeroAttemptMarkedIds:[...new Set(zeroMarked)],duplicateAttemptIds:[...new Set(duplicateAttempts)],timingOutliers:facts.all.filter(a=>a.time>EP_MAX_ACTIVE_ANSWER_SECONDS).length,malformedConcepts:malformed.slice(0,100),missingConceptIds:missing.slice(0,100),crossCategoryConceptIds:cross.slice(0,100),counts:{duplicateStatus:Object.keys(dup).filter(id=>dup[id].length>1).length,zeroAttemptMarked:new Set(zeroMarked).size,duplicateAttempts:new Set(duplicateAttempts).size,malformedConcepts:malformed.length,missingConceptIds:missing.length,crossCategoryConceptIds:cross.length}};
}

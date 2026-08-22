const EP_RETENTION_MIN_HOURS=20;
const EP_RETENTION_MIN_MS=EP_RETENTION_MIN_HOURS*60*60*1000;
const EP_BANK_LOG='Bank_Coverage_Log';
const EP_SAFE_ATTEMPT_SECONDS=180;

function performanceTimeline_(){
  const qMap=Object.fromEntries(allQuestions_().map(q=>[q.id,q]));
  const s=sheet_(EP.sheets.performance),byId={},seenAttemptIds=new Set(),duplicates=0;
  if(s.getLastRow()<2)return {byId,duplicates:0,attempts:[]};
  const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim().toLowerCase());
  const idx=name=>h.findIndex(x=>x===name);
  let ti=idx('timestamp'),qi=idx('question_id'),ci=idx('correct'),si=idx('time_seconds'),ai=idx('attempt_id');
  if(ti<0)ti=0;if(qi<0)qi=1;if(ci<0)ci=3;if(si<0)si=4;if(ai<0)ai=6;
  const attempts=[];
  vals.slice(1).forEach((r,rowIndex)=>{
    const id=String(r[qi]||'').trim();if(!id||!qMap[id])return;
    const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;
    const attemptId=String(r[ai]||'').trim();
    const fallback=id+'|'+d.getTime()+'|'+String(r[2]||'')+'|'+String(r[ci]||'');
    const key=attemptId||fallback;if(seenAttemptIds.has(key)){duplicates++;return}seenAttemptIds.add(key);
    const raw=Number(r[si]||0),timeValid=Number.isFinite(raw)&&raw>=0&&raw<=EP_SAFE_ATTEMPT_SECONDS;
    const a={id,at:d,correct:truthy_(r[ci]),timeSeconds:timeValid?raw:null,attemptId:attemptId||fallback,row:rowIndex+2,topic:qMap[id].topic||'',conceptId:qMap[id].conceptId||''};
    attempts.push(a);if(!byId[id])byId[id]=[];byId[id].push(a);
  });
  Object.values(byId).forEach(a=>a.sort((x,y)=>x.at-y.at));attempts.sort((x,y)=>x.at-y.at);
  return {byId,duplicates,attempts};
}

function learningStateFor_(q,attempts,status){
  attempts=attempts||[];status=status||{};
  if(!attempts.length)return {state:'UNSEEN',wrong:0,retentionAttempts:0,retentionCorrect:0,firstCorrect:null,afterReviewAttempts:0,afterReviewCorrect:0};
  let wrong=0,retentionAttempts=0,retentionCorrect=0,afterReviewAttempts=0,afterReviewCorrect=0;
  attempts.forEach((a,i)=>{if(!a.correct)wrong++;if(i===0)return;const spaced=(a.at-attempts[i-1].at)>=EP_RETENTION_MIN_MS;if(spaced){retentionAttempts++;if(a.correct)retentionCorrect++;}else{afterReviewAttempts++;if(a.correct)afterReviewCorrect++;}});
  const last=attempts[attempts.length-1],recentSpaced=[];
  for(let i=1;i<attempts.length;i++)if((attempts[i].at-attempts[i-1].at)>=EP_RETENTION_MIN_MS)recentSpaced.push(attempts[i]);
  const recent3=recentSpaced.slice(-3),recentSpacedWrong=recent3.filter(a=>!a.correct).length;
  const persistent=wrong>=3||recentSpacedWrong>=2;
  let state='LEARNING';
  if(persistent)state='PERSISTENT_WEAK';
  else if(!last.correct)state='WEAK';
  else if(wrong>0&&(retentionCorrect<2||recentSpacedWrong>0))state='FRAGILE';
  else if(retentionCorrect>=2&&recentSpacedWrong===0)state='STRONG';
  else state='LEARNING';
  const provenMastered=!!status.mastered&&retentionCorrect>=2&&recentSpacedWrong===0;
  if(provenMastered)state='MASTERED';
  return {state,wrong,retentionAttempts,retentionCorrect,firstCorrect:attempts[0].correct,afterReviewAttempts,afterReviewCorrect,provenMastered,lastCorrect:last.correct};
}

function learningFacts_(){
  const timeline=performanceTimeline_(),status=statusMap_(),all=allQuestions_().filter(q=>isActive_(q)),byQuestion={},topicAgg={};
  const totals={firstAttempts:0,firstCorrect:0,afterReviewAttempts:0,afterReviewCorrect:0,retentionAttempts:0,retentionCorrect:0};
  all.forEach(q=>{
    const attempts=timeline.byId[q.id]||[],x=learningStateFor_(q,attempts,status[q.id]||{});byQuestion[q.id]=x;
    if(attempts.length){totals.firstAttempts++;if(x.firstCorrect)totals.firstCorrect++;}
    totals.afterReviewAttempts+=x.afterReviewAttempts;totals.afterReviewCorrect+=x.afterReviewCorrect;totals.retentionAttempts+=x.retentionAttempts;totals.retentionCorrect+=x.retentionCorrect;
    const topic=String(q.topic||'Other').trim()||'Other';if(!topicAgg[topic])topicAgg[topic]={topic,total:0,exposed:0,firstAttempts:0,firstCorrect:0,retentionAttempts:0,retentionCorrect:0,weak:0,persistentWeak:0,fragile:0,strong:0,mastered:0};
    const g=topicAgg[topic];g.total++;if(attempts.length){g.exposed++;g.firstAttempts++;if(x.firstCorrect)g.firstCorrect++;}g.retentionAttempts+=x.retentionAttempts;g.retentionCorrect+=x.retentionCorrect;
    if(x.state==='WEAK')g.weak++;if(x.state==='PERSISTENT_WEAK')g.persistentWeak++;if(x.state==='FRAGILE')g.fragile++;if(x.state==='STRONG')g.strong++;if(x.state==='MASTERED')g.mastered++;
  });
  return {timeline,status,all,byQuestion,topicAgg,totals};
}

function pct1_(n,d){return d?Math.round(Number(n||0)*1000/Number(d))/10:0;}
function isLowPressureHindu_(q){const t=[q&&q.topic,q&&q.sourceId,q&&q.sourceFile].map(x=>String(x||'').toLowerCase()).join(' ');return t.includes('hindu')||/^HV\d/i.test(String(q&&q.id||''));}
function getLearningAnalytics(){
  const f=learningFacts_(),eligible=bankEligibleQuestions_(f.all),exposed=eligible.filter(q=>(f.timeline.byId[q.id]||[]).length>0).length;
  const states=Object.values(f.byQuestion),conceptWeak=new Set();
  f.all.forEach(q=>{const st=f.byQuestion[q.id]?.state;if((st==='WEAK'||st==='PERSISTENT_WEAK')&&String(q.conceptId||'').trim())conceptWeak.add(String(q.conceptId).trim())});
  return {
    retentionMinHours:EP_RETENTION_MIN_HOURS,
    bankEligible:eligible.length,bankExposed:exposed,bankExposedPercent:pct1_(exposed,eligible.length),
    firstAttemptAccuracy:pct1_(f.totals.firstCorrect,f.totals.firstAttempts),afterReviewAccuracy:pct1_(f.totals.afterReviewCorrect,f.totals.afterReviewAttempts),retentionAccuracy:pct1_(f.totals.retentionCorrect,f.totals.retentionAttempts),
    weakConcepts:conceptWeak.size,weak:states.filter(x=>x.state==='WEAK').length,persistentWeak:states.filter(x=>x.state==='PERSISTENT_WEAK').length,fragile:states.filter(x=>x.state==='FRAGILE').length,strong:states.filter(x=>x.state==='STRONG').length,mastered:states.filter(x=>x.state==='MASTERED').length,
    categories:Object.values(f.topicAgg).filter(g=>!/hindu/i.test(g.topic)).map(g=>Object.assign({},g,{coveragePercent:pct1_(g.exposed,g.total),firstAttemptAccuracy:pct1_(g.firstCorrect,g.firstAttempts),retentionAccuracy:pct1_(g.retentionCorrect,g.retentionAttempts)})).sort((a,b)=>b.total-a.total||a.topic.localeCompare(b.topic))
  };
}

function bankEligibleQuestions_(all){
  return (all||allQuestions_()).filter(q=>isActive_(q)&&String(q.topic||'').trim()&&!isLowPressureHindu_(q)&&String(q.sourceId||'')!=='MY_SAVED_WORDS');
}
function bankCoverageLogSheet_(){
  const ss=ss_();let s=ss.getSheetByName(EP_BANK_LOG);if(!s){s=ss.insertSheet(EP_BANK_LOG);s.getRange(1,1,1,4).setValues([['Serve_Date','Topic','Question_ID','Served_At']]);s.setFrozenRows(1);}return s;
}
function bankTodayLog_(){const s=bankCoverageLogSheet_(),today=todayKey_(),out=[];if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,4).getValues().forEach(r=>{if(dateKey_(r[0])===today)out.push({date:today,topic:String(r[1]||''),id:String(r[2]||''),at:r[3] instanceof Date?r[3]:new Date(r[3])})});return out;}
function getBankCoverageHub(){
  const f=learningFacts_(),eligible=bankEligibleQuestions_(f.all),todayLog=bankTodayLog_(),byTopic={};
  eligible.forEach(q=>{const topic=String(q.topic||'Other');if(!byTopic[topic])byTopic[topic]={topic,total:0,exposed:0,unseen:0,todayServed:0,todayRemaining:0};const g=byTopic[topic];g.total++;const seen=(f.timeline.byId[q.id]||[]).length>0;if(seen)g.exposed++;else g.unseen++;});
  const loggedByTopic={};todayLog.forEach(x=>{if(!loggedByTopic[x.topic])loggedByTopic[x.topic]=[];loggedByTopic[x.topic].push(x)});
  Object.values(byTopic).forEach(g=>{const logs=loggedByTopic[g.topic]||[];g.todayServed=logs.length;g.todayRemaining=logs.filter(x=>{const arr=f.timeline.byId[x.id]||[];return !arr.some(a=>a.at>=x.at)}).length;g.availableToday=logs.length?g.todayRemaining:Math.min(10,g.unseen);g.coveragePercent=pct1_(g.exposed,g.total);});
  const total=eligible.length,exposed=eligible.filter(q=>(f.timeline.byId[q.id]||[]).length>0).length;
  return {date:todayKey_(),total,exposed,percent:pct1_(exposed,total),fullyExposed:exposed>=total&&total>0,categories:Object.values(byTopic).sort((a,b)=>a.topic.localeCompare(b.topic))};
}
function getBankCoverageBatch(topic){
  topic=String(topic||'').trim();if(!topic)throw new Error('Bank category required');
  const lock=LockService.getScriptLock();lock.waitLock(10000);
  try{
    const f=learningFacts_(),eligible=bankEligibleQuestions_(f.all).filter(q=>String(q.topic||'')===topic),today=todayKey_(),s=bankCoverageLogSheet_(),logs=bankTodayLog_().filter(x=>x.topic===topic);
    let chosen=[];
    if(logs.length){chosen=logs.filter(x=>{const arr=f.timeline.byId[x.id]||[];return !arr.some(a=>a.at>=x.at)}).map(x=>eligible.find(q=>q.id===x.id)).filter(Boolean);}
    else{
      const unseen=eligible.filter(q=>(f.timeline.byId[q.id]||[]).length===0);shuffle_(unseen);chosen=unseen.slice(0,10);
      if(chosen.length){const now=new Date(),rows=chosen.map(q=>[today,topic,q.id,now]);s.getRange(s.getLastRow()+1,1,rows.length,4).setValues(rows);}
    }
    return chosen.map(serveQuestion_);
  }finally{lock.releaseLock();}
}

function categoryWeakWeight_(topic,f){const g=f.topicAgg[String(topic||'')]||{};const exposed=Math.max(1,Number(g.exposed||0));return (Number(g.persistentWeak||0)*3+Number(g.weak||0)*2+Number(g.fragile||0))/exposed;}
function selectAdaptiveDaily_(questions,status,limit){
  const f=learningFacts_(),now=new Date(),rank={PERSISTENT_WEAK:500,WEAK:400,FRAGILE:300,LEARNING:100,STRONG:60,MASTERED:-1000,UNSEEN:120},marked=typeof currentMarkedIds_==='function'?currentMarkedIds_():new Set(),diff=typeof starredRevisionDifficultMap_==='function'?starredRevisionDifficultMap_():{};
  const rows=[];
  questions.forEach(q=>{const lf=f.byQuestion[q.id]||{state:'UNSEEN'},st=status[q.id]||{};if(st.mastered)return;const manual=marked.has(q.id)||!!diff[q.id];if(isLowPressureHindu_(q)&&!manual&&!['PERSISTENT_WEAK','WEAK','FRAGILE'].includes(lf.state))return;let reason='Controlled New',base=rank[lf.state]??80;
    if(lf.state==='PERSISTENT_WEAK')reason='Persistent Weak';else if(lf.state==='WEAK')reason='Weak';else if(lf.state==='FRAGILE')reason='Fragile';else if(st.nextReview&&new Date(st.nextReview)<=now){reason='Due Spaced Revision';base=Math.max(base,220);}else if(lf.state!=='UNSEEN')reason='Learning Review';
    const score=base+categoryWeakWeight_(q.topic,f)*40+Math.random()*10+(manual?12:0);rows.push({q,priority:Math.round(score),reason});
  });
  rows.sort((a,b)=>b.priority-a.priority);const out=[],seen=new Set();rows.forEach(x=>{if(out.length<limit&&!seen.has(x.q.id)){seen.add(x.q.id);out.push(x)}});return out;
}

function getLearningDataAudit(){
  const f=learningFacts_(),statusSheet=sheet_(EP.sheets.status),statusVals=statusSheet.getLastRow()>1?statusSheet.getRange(2,1,statusSheet.getLastRow()-1,20).getValues():[],statusSeen=new Set(),duplicateStatus=0,zeroAttemptMarked=0;
  statusVals.forEach(r=>{const id=String(r[0]||'').trim();if(!id)return;if(statusSeen.has(id))duplicateStatus++;statusSeen.add(id);if(Number(r[1]||0)===0&&(truthy_(r[10])||String(r[12]||'').toLowerCase()==='marked'))zeroAttemptMarked++;});
  let malformedConcept=0,missingConcept=0;f.all.forEach(q=>{const c=String(q.conceptId||'').trim();if(!c){missingConcept++;return}if(c.length>80||/\s{2,}|[.!?].*\s/.test(c)||c.split(/\s+/).length>6)malformedConcept++;});
  return {duplicateAttemptIds:f.timeline.duplicates,duplicateStatusRows:duplicateStatus,zeroAttemptMarkedRows:zeroAttemptMarked,malformedConceptIds:malformedConcept,missingConceptIds:missingConcept,performanceAttempts:f.timeline.attempts.length,statusRows:statusVals.length};
}

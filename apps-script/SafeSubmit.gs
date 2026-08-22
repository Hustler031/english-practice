function submitAnswerV2(payload){
  payload=payload||{};const id=String(payload.questionId||'').trim(),selectedKey=String(payload.selectedKey||'').toUpperCase();
  if(!id||!['A','B','C','D'].includes(selectedKey))throw new Error('Invalid answer');
  if(id.startsWith('HINDU_'))return {correct:!!payload.localCorrect,correctKey:String(payload.correctKey||'')};
  const q=findQuestion_(id);if(!q)throw new Error('Question not found');
  const correctKey=String(q.correct||'').toUpperCase(),isCorrect=selectedKey===correctKey,now=new Date(),raw=Math.max(0,Number(payload.timeSeconds||0)),secs=Math.min(EP_SAFE_ATTEMPT_SECONDS,raw),marked=!!payload.marked;
  const attemptId=String(payload.attemptId||'').trim()||id+'-'+now.getTime()+'-'+Math.random().toString(36).slice(2,8),perf=sheet_(EP.sheets.performance);
  const lock=LockService.getScriptLock();lock.waitLock(10000);
  try{
    if(findRow_(perf,7,attemptId)>1)return {correct:isCorrect,correctKey,duplicate:true};
    perf.appendRow([now,id,selectedKey,isCorrect,secs,marked,attemptId,q.topic||'',q.conceptId||'']);
    const st=upsertStatus_(q,isCorrect,secs,marked,now);markDaily_(id);setQuestionLearningStatus_(id,st.status==='Strong'?'Active':'Learning');clearStatusCache_();
    try{PropertiesService.getScriptProperties().deleteProperty(EP_PROGRESS_SNAPSHOT_KEY)}catch(e){}
    return {correct:isCorrect,correctKey,status:st.status,nextReview:st.nextReview,attemptId,timeCapped:raw>EP_SAFE_ATTEMPT_SECONDS};
  }finally{lock.releaseLock();}
}

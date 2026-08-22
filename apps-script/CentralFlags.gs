function setMarkedCentralV3(questionId,marked){
  if(typeof setMarkedCentralV4==='function')return setMarkedCentralV4(questionId,!!marked);
  const result=typeof setMarkedFastV3==='function'?setMarkedFastV3(questionId,!!marked):setMarkedV2(questionId,!!marked);
  try{if(result&&result.questionId)logStarredRevisionEvent_(result.questionId,!!marked);}catch(e){}
  return result;
}

function setHinduMarkedCentralV3(questionId,marked){
  if(typeof setHinduMarkedCentralV4==='function')return setHinduMarkedCentralV4(questionId,!!marked);
  const raw=String(questionId||'').trim();
  const result=typeof setHinduMarkedFastV3==='function'?setHinduMarkedFastV3(raw,!!marked):setHinduMarkedV2(raw,!!marked);
  try{const id=(result&&result.questionId)||resolveHinduQuestionId_(raw);if(id)logStarredRevisionEvent_(id,!!marked);}catch(e){}
  return result;
}

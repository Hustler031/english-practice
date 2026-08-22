function setMarkedCentralV3(questionId,marked){
  const result=setMarkedV2(questionId,!!marked);
  try{if(result&&result.questionId)logStarredRevisionEvent_(result.questionId,!!marked);}catch(e){}
  return result;
}

function setHinduMarkedCentralV3(questionId,marked){
  const raw=String(questionId||'').trim();
  const result=setHinduMarkedV2(raw,!!marked);
  try{const id=(result&&result.questionId)||resolveHinduQuestionId_(raw);if(id)logStarredRevisionEvent_(id,!!marked);}catch(e){}
  return result;
}

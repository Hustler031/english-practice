function getHinduPracticeProgressCentral(){
  if(typeof getHinduPracticeProgressFastV4_==='function')return getHinduPracticeProgressFastV4_();
  const words=getHinduToday(),facts=performanceFactsV2_(),counts=words.map(w=>{const id=resolveHinduQuestionId_(String(w.id||''));return id?(facts.byId[id]||[]).filter(a=>a.module==='hindu').length:0}),total=words.length,roundsCompleted=counts.length?Math.min(...counts):0;
  return {total,completed:counts.filter(n=>n>0).length,roundsCompleted,nextRound:roundsCompleted+1};
}

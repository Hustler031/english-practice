function getEnglishUiBootstrap(){
  const out={generatedAt:new Date().toISOString()};
  const safe=(key,fn)=>{try{out[key]=fn()}catch(e){out[key]=null;out.errors=out.errors||{};out.errors[key]=String(e&&e.message||e)}};
  safe('savedHub',()=>getMySavedHub());
  safe('savedWords',()=>getMyWords());
  safe('newHub',()=>getNewPracticeHub());
  safe('sourceHub',()=>getSourceHub());
  safe('topicHub',()=>getTopicPracticeHub());
  safe('demandHub',()=>getDemandBatches());
  safe('demandStats',()=>getDemandHubStats());
  safe('hinduToday',()=>getHinduToday());
  safe('hinduProgress',()=>getHinduPracticeProgress());
  // Heavy progress calculations and full starred-item rows are intentionally
  // excluded from the normal UI warmup. They have their own long-lived caches
  // and are fetched only when actually needed.
  return out;
}

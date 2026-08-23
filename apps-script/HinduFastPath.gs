const EP_HINDU_FAST_MAP_V4='EP_HINDU_FAST_MAP_V4_';

function hinduFastNormV4_(v){return String(v||'').trim().toLocaleLowerCase();}
function hinduFastRawV4_(id){return String(id||'').trim().replace(/^HINDU_/,'');}
function hinduFastDateSeqV4_(raw){
  const m=String(raw||'').match(/HINDU(20\d{6})_(\d+)/i);
  return m?{date:m[1],seq:Number(m[2]||0)}:{date:'',seq:0};
}
function hinduFastMapCacheKeyV4_(words){
  const dates=[...new Set((words||[]).map(w=>hinduFastDateSeqV4_(hinduFastRawV4_(w.id)).date).filter(Boolean))].sort();
  return EP_HINDU_FAST_MAP_V4+(dates.join('_')||todayKey_().replace(/-/g,''));
}
function hinduFastCentralMapV4_(words){
  words=words||[];const cache=CacheService.getScriptCache(),key=hinduFastMapCacheKeyV4_(words),rawIds=words.map(w=>hinduFastRawV4_(w.id)).filter(Boolean);let cached={};
  try{cached=JSON.parse(cache.get(key)||'{}')||{}}catch(e){cached={}}
  if(rawIds.length&&rawIds.every(id=>String(cached[id]||'').trim()))return cached;

  const all=allQuestions_(),byId=Object.fromEntries(all.map(q=>[String(q.id||'').trim(),q])),byDateWord={};
  all.forEach(q=>{
    const id=String(q.id||'').trim(),m=id.match(/^HV(20\d{6})_/i),word=hinduFastNormV4_(q.word);
    if(m&&word&&!byDateWord[m[1]+'|'+word])byDateWord[m[1]+'|'+word]=id;
  });
  const out=Object.assign({},cached);
  words.forEach(w=>{
    const raw=hinduFastRawV4_(w.id),meta=hinduFastDateSeqV4_(raw),word=hinduFastNormV4_(w.word);if(!raw)return;
    const direct=meta.date&&meta.seq?('HV'+meta.date+'_'+String(meta.seq).padStart(3,'0')):'';
    if(direct&&byId[direct]&&(!word||hinduFastNormV4_(byId[direct].word)===word))out[raw]=direct;
    else if(meta.date&&word&&byDateWord[meta.date+'|'+word])out[raw]=byDateWord[meta.date+'|'+word];
  });
  try{cache.put(key,JSON.stringify(out),21600)}catch(e){}
  return out;
}

function hinduQuizFromWordsFastV4_(words,centralMap,stars){
  words=words||[];const meanings=words.map(w=>String(w.meaning||'').trim()).filter(Boolean);if(words.length<2||meanings.length<2)return[];
  return words.filter(w=>w.word&&w.meaning).map(w=>{
    const distractors=shuffle_(meanings.filter(m=>m!==w.meaning)).slice(0,3);while(distractors.length<3)distractors.push('None of these meanings');
    const opts=shuffle_([{key:'CORRECT',text:w.meaning},...distractors.map((x,i)=>({key:'D'+i,text:x}))]),correctIndex=opts.findIndex(o=>o.key==='CORRECT'),raw=hinduFastRawV4_(w.id),centralId=String(centralMap[raw]||'').trim();
    return {id:'HINDU_'+raw,centralQuestionId:centralId,category:'HINDU_VOCAB',topic:'The Hindu Vocabulary',word:w.word,question:'What is the closest meaning of '+w.word+'?',options:opts.map((o,i)=>({key:['A','B','C','D'][i],text:o.text})),correctKey:['A','B','C','D'][correctIndex],explanation:w.meaning,example:w.example,usageNote:w.usage,tip:w.tip,memoryAid:w.memory,related:w.synonyms?('Synonyms: '+w.synonyms):'',source:w.sourceName||'The Hindu',sourcePage:'',marked:!!(centralId&&stars&&stars[centralId])};
  });
}

function getHinduQuizFastV4(){
  const words=getHinduToday(),centralMap=hinduFastCentralMapV4_(words),stars=currentStarredMapV2_();
  return hinduQuizFromWordsFastV4_(words,centralMap,stars);
}

function getHinduPracticeProgressFastV4_(){
  const words=getHinduToday(),centralMap=hinduFastCentralMapV4_(words),facts=performanceFactsV2_(),counts=words.map(w=>{const id=String(centralMap[hinduFastRawV4_(w.id)]||'').trim();return id?(facts.byId[id]||[]).filter(a=>a.module==='hindu').length:0}),total=words.length,roundsCompleted=counts.length?Math.min(...counts):0;
  return {total,completed:counts.filter(n=>n>0).length,roundsCompleted,nextRound:roundsCompleted+1};
}

function getHinduFastPathAuditV4(){
  const words=getHinduToday(),map=hinduFastCentralMapV4_(words),linked=words.filter(w=>String(map[hinduFastRawV4_(w.id)]||'').trim()).length;
  return {ok:true,total:words.length,linked,unlinked:Math.max(0,words.length-linked),usesDifficultMap:false};
}

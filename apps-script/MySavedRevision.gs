function mySavedRevisionIndex_(){
  const words=getMyWords(),qMap=Object.fromEntries(allQuestions_().map(q=>[q.id,q])),status=statusMap_(),diff=starredRevisionDifficultMap_(),facts=learningFacts_(),out=[];
  words.forEach(w=>{const id=String(w.practiceQuestionId||'').trim(),q=qMap[id];if(!id||!q)return;const date=String(w.created||'').trim()||todayKey_();const day=typeof dailyDayNoV2_==='function'?dailyDayNoV2_(date):1,st=status[id]||{},lf=facts.byQuestion[id]||{state:'UNSEEN'};out.push({id,day,date,word:q.word||w.word||'',question:q.question||'',topic:q.topic||'',source:q.sourceFile||'',mastered:!!st.mastered,difficult:!!diff[id],weak:lf.state==='WEAK'||lf.state==='PERSISTENT_WEAK',persistentWeak:lf.state==='PERSISTENT_WEAK',attempts:(facts.timeline.byId[id]||[]).length,state:lf.state});});
  return out;
}
function mySavedRevisionStats_(rows){return {saved:rows.length,focus:rows.filter(x=>!x.mastered).length,newCount:rows.filter(x=>!x.mastered&&!x.attempts).length,weak:rows.filter(x=>!x.mastered&&x.weak).length,difficult:rows.filter(x=>!x.mastered&&x.difficult).length,mastered:rows.filter(x=>x.mastered).length};}
function getMySavedRevisionHub(){
  const rows=mySavedRevisionIndex_(),days={};rows.forEach(x=>{if(!days[x.day])days[x.day]=[];days[x.day].push(x)});
  return {stats:mySavedRevisionStats_(rows),groups:Object.keys(days).map(Number).sort((a,b)=>b-a).map(day=>({day,label:'Day '+day,fromDay:day,toDay:day,stats:mySavedRevisionStats_(days[day])}))};
}
function mySavedScope_(scope){scope=scope||{};const from=Math.max(1,Number(scope.fromDay||1)),to=Math.max(from,Number(scope.toDay||999999));return {fromDay:from,toDay:to};}
function getMySavedRevisionItems(scope,kind){const sc=mySavedScope_(scope),mode=String(kind||'all').toLowerCase();return mySavedRevisionIndex_().filter(x=>x.day>=sc.fromDay&&x.day<=sc.toDay).filter(x=>mode==='mastered'?x.mastered:mode==='difficult'?!x.mastered&&x.difficult:mode==='weak'?!x.mastered&&x.weak:true).sort((a,b)=>b.day-a.day||String(a.word||a.id).localeCompare(String(b.word||b.id)));}
function getMySavedRevisionBatch(scope,kind,count){
  const sc=mySavedScope_(scope),mode=String(kind||'all').toLowerCase(),index=mySavedRevisionIndex_(),byId=Object.fromEntries(index.map(x=>[x.id,x]));
  let pool=allQuestions_().filter(q=>{const x=byId[q.id];return !!x&&x.day>=sc.fromDay&&x.day<=sc.toDay&&isActive_(q)&&(mode==='mastered'?x.mastered:!x.mastered)});
  if(mode==='new')pool=pool.filter(q=>Number(byId[q.id].attempts||0)===0);
  if(mode==='weak')pool=pool.filter(q=>byId[q.id].weak);
  if(mode==='difficult')pool=pool.filter(q=>byId[q.id].difficult);
  if(['all','new','weak','difficult'].includes(mode))shuffle_(pool);
  if(['new','weak'].includes(mode)){const n=Math.max(1,Math.min(100,Number(count||10)));pool=pool.slice(0,n)}
  return pool.map(q=>{const s=serveQuestion_(q);s.difficult=!!byId[q.id]?.difficult;return s});
}

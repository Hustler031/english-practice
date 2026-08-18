const STARRED_REVISION_LOG='Starred_Revision_Log';
const STARRED_REVISION_SEEDED='STARRED_REVISION_SEEDED_V1';

function starredRevisionLogSheet_(){
  const ss=ss_();let s=ss.getSheetByName(STARRED_REVISION_LOG);
  if(!s){s=ss.insertSheet(STARRED_REVISION_LOG);s.getRange(1,1,1,5).setValues([['Question_ID','Event_At','Starred_Date','Day_No','Action']]);s.setFrozenRows(1);}
  return s;
}
function starredRevisionActiveDate_(){
  try{const rows=table_(EP.sheets.daily).filter(r=>String(r.Question_ID||'').trim());if(rows.length){const k=dateKey_(rows[0].Quiz_Date);if(k)return k;}}catch(e){}
  return todayKey_();
}
function starredRevisionActiveDay_(){const d=starredRevisionActiveDate_();return typeof dailyDayNoV2_==='function'?dailyDayNoV2_(d):1;}
function logStarredRevisionEventAt_(questionId,marked,when){
  const id=String(questionId||'').trim();if(!id)return;const now=when instanceof Date?when:new Date(),date=starredRevisionActiveDate_(),day=starredRevisionActiveDay_();
  starredRevisionLogSheet_().appendRow([id,now,date,day,marked?'STAR':'UNSTAR']);
}
function logStarredRevisionEvent_(questionId,marked){logStarredRevisionEventAt_(questionId,marked,new Date());}
function logStarredRevisionFromUi(questionId,marked){
  let id=String(questionId||'').trim();if(!id)return {ok:false};
  if(/^HINDU_/.test(id)&&typeof resolveHinduQuestionId_==='function')id=resolveHinduQuestionId_(id)||id;
  if(!/^HINDU_/.test(id))logStarredRevisionEvent_(id,!!marked);
  return {ok:true,questionId:id,marked:!!marked};
}
function setMarkedAndLog(questionId,marked){const r=setMarked(questionId,marked);try{logStarredRevisionEvent_(questionId,!!marked)}catch(e){}return r;}
function setHinduMarkedAndLog(id,marked){const r=setHinduMarked(id,marked);try{if(r&&r.questionId)logStarredRevisionEvent_(r.questionId,!!marked)}catch(e){}return r;}

function starredRevisionLegacyDates_(){
  const out={},s=sheet_(EP.sheets.performance);if(s.getLastRow()<2)return out;
  const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim().toLowerCase());
  let ti=h.findIndex(x=>x==='timestamp'||x==='time'||x==='attempt_time'||x==='attempt timestamp'),qi=h.findIndex(x=>x==='question_id'||x==='question id'||x==='questionid'),mi=h.findIndex(x=>x==='marked');
  if(ti<0)ti=0;if(qi<0)qi=1;if(mi<0)mi=5;
  vals.slice(1).forEach(r=>{if(!truthy_(r[mi]))return;const id=String(r[qi]||'').trim(),d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(!id||isNaN(d))return;if(!out[id]||d<out[id])out[id]=d;});
  return out;
}
function ensureStarredRevisionSeed_(){
  const props=PropertiesService.getScriptProperties();if(props.getProperty(STARRED_REVISION_SEEDED)==='1')return;
  const lock=LockService.getScriptLock();if(!lock.tryLock(5000))return;
  try{
    if(props.getProperty(STARRED_REVISION_SEEDED)==='1')return;
    const s=starredRevisionLogSheet_(),existing=new Set();if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,1).getValues().forEach(r=>existing.add(String(r[0]||'').trim()));
    const legacy=starredRevisionLegacyDates_(),status=statusMap_(),rows=[];
    Object.keys(status).forEach(id=>{const st=status[id]||{},wasStarred=Object.prototype.hasOwnProperty.call(legacy,id)||isStarredStatus_(st);if(!wasStarred||existing.has(id))return;const d=legacy[id]||new Date(),date=legacy[id]?(dateKey_(d)||todayKey_()):starredRevisionActiveDate_(),day=legacy[id]&&typeof dailyDayNoV2_==='function'?dailyDayNoV2_(date):starredRevisionActiveDay_();rows.push([id,d,date,day,'STAR']);});
    if(rows.length)s.getRange(s.getLastRow()+1,1,rows.length,5).setValues(rows);
    props.setProperty(STARRED_REVISION_SEEDED,'1');
  }finally{lock.releaseLock();}
}
function starredRevisionIndex_(){
  ensureStarredRevisionSeed_();
  const status=statusMap_(),all=allQuestions_(),qmap=Object.fromEntries(all.map(q=>[q.id,q])),events={},s=starredRevisionLogSheet_();
  if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,5).getValues().forEach(r=>{const id=String(r[0]||'').trim();if(!id)return;const d=r[1] instanceof Date?r[1]:new Date(r[1]);if(!events[id]||(!isNaN(d)&&d>=events[id].eventAt))events[id]={eventAt:isNaN(d)?new Date(0):d,date:dateKey_(r[2])||dateKey_(d),day:Number(r[3]||0),action:String(r[4]||'').toUpperCase()};});
  const rows=[];
  Object.keys(qmap).forEach(id=>{
    const st=status[id]||{},ev=events[id],currentlyStarred=isStarredStatus_(st),mastered=!!st.mastered;
    const ever=!!ev||currentlyStarred;if(!ever)return;
    const active=ev?ev.action!=='UNSTAR':currentlyStarred;if(!active&&!mastered)return;
    let d=ev&&ev.date?ev.date:starredRevisionActiveDate_(),day=ev&&ev.day?ev.day:starredRevisionActiveDay_();if(!day||day<1)day=1;
    const q=qmap[id];rows.push({id,day,date:d,starred:active,mastered,weak:isWeakStatus_(st),attempts:Number(st.attempts||0),word:q.word||'',question:q.question||'',topic:q.topic||'',source:q.sourceFile||q.sourceId||''});
  });
  return rows;
}
function starredRevisionScope_(scope){scope=scope||{};const from=Math.max(1,Number(scope.fromDay||1)),to=Math.max(from,Number(scope.toDay||999999));return {fromDay:from,toDay:to};}
function starredRevisionStats_(rows){const mastered=rows.filter(x=>x.mastered).length,focus=rows.filter(x=>x.starred&&!x.mastered).length;return {starred:rows.length,mastered,focus};}
function starredRevisionHierarchy_(rows,currentDay){
  const groups=[],currentMonth=Math.floor((currentDay-1)/30)+1,currentMonthStart=(currentMonth-1)*30+1,currentBlockStart=Math.floor((currentDay-1)/10)*10+1;
  const dayStats=d=>starredRevisionStats_(rows.filter(x=>x.day===d));
  for(let d=currentDay;d>=currentBlockStart;d--){const st=dayStats(d);if(st.starred)groups.push({type:'day',label:'Day '+d,fromDay:d,toDay:d,stats:st,expanded:true});}
  for(let start=currentBlockStart-10;start>=currentMonthStart;start-=10){const end=Math.min(start+9,currentDay),part=rows.filter(x=>x.day>=start&&x.day<=end),st=starredRevisionStats_(part);if(st.starred)groups.push({type:'block',label:'Days '+start+'–'+end,fromDay:start,toDay:end,stats:st,expanded:false});}
  for(let month=currentMonth-1;month>=1;month--){const start=(month-1)*30+1,end=month*30,part=rows.filter(x=>x.day>=start&&x.day<=end),st=starredRevisionStats_(part);if(st.starred)groups.push({type:'month',label:'Month '+month+' · Days '+start+'–'+end,fromDay:start,toDay:end,stats:st,expanded:false});}
  return groups;
}
function getStarredRevisionHub(){const rows=starredRevisionIndex_(),currentDay=starredRevisionActiveDay_();return {currentDay,stats:starredRevisionStats_(rows),groups:starredRevisionHierarchy_(rows,currentDay)};}
function getStarredRevisionGroup(fromDay,toDay){const rows=starredRevisionIndex_().filter(x=>x.day>=Number(fromDay)&&x.day<=Number(toDay)),days=[];for(let d=Number(toDay);d>=Number(fromDay);d--){const part=rows.filter(x=>x.day===d),st=starredRevisionStats_(part);if(st.starred)days.push({label:'Day '+d,fromDay:d,toDay:d,stats:st});}return {stats:starredRevisionStats_(rows),days};}
function getStarredRevisionItems(scope,kind){const sc=starredRevisionScope_(scope),mode=String(kind||'all').toLowerCase();return starredRevisionIndex_().filter(x=>x.day>=sc.fromDay&&x.day<=sc.toDay).filter(x=>mode==='mastered'?x.mastered:true).sort((a,b)=>b.day-a.day||String(a.word||a.id).localeCompare(String(b.word||b.id)));}
function getStarredRevisionBatch(scope,kind,count){
  const sc=starredRevisionScope_(scope),mode=String(kind||'all').toLowerCase(),status=statusMap_(),byId=Object.fromEntries(starredRevisionIndex_().map(x=>[x.id,x]));
  let pool=allQuestions_().filter(q=>{const x=byId[q.id];if(!x||x.day<sc.fromDay||x.day>sc.toDay)return false;if(mode==='mastered')return x.mastered;return x.starred&&!x.mastered&&isActive_(q);});
  if(mode==='weak')pool=pool.filter(q=>isWeakStatus_(status[q.id]||{}));
  if(mode==='new')pool.sort((a,b)=>(byId[b.id]?.day||0)-(byId[a.id]?.day||0)||Number((status[a.id]||{}).attempts||0)-Number((status[b.id]||{}).attempts||0));
  if(mode==='random'||mode==='weak')shuffle_(pool);
  const n=Math.max(1,Math.min(100,Number(count||10)));if(['random','weak','new'].includes(mode))pool=pool.slice(0,n);
  return pool.map(serveQuestion_);
}

const STARRED_ORIGIN_REPAIR_V4='STARRED_ORIGIN_REPAIR_V4_20260823';

function starredStatusLastMarkedMapV4_(){
  const out={},s=sheet_(EP.sheets.status);if(s.getLastRow()<2)return out;
  const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim().toLowerCase()),qi=h.indexOf('question_id'),mi=h.indexOf('last_marked');
  if(mi<0)return out;
  vals.slice(1).forEach(r=>{const id=String(r[qi>=0?qi:0]||'').trim();if(id&&truthy_(r[mi]))out[id]=true;});
  return out;
}
function starredEventStateV4_(){
  const s=starredRevisionLogSheet_(),latest={},ever=new Set();
  if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,5).getValues().forEach(r=>{const id=String(r[0]||'').trim();if(!id)return;ever.add(id);const d=r[1] instanceof Date?r[1]:new Date(r[1]),t=isNaN(d)?0:d.getTime();if(!latest[id]||t>=latest[id].t)latest[id]={t,eventAt:isNaN(d)?new Date(0):d,date:dateKey_(r[2])||dateKey_(d),day:Number(r[3]||0),action:String(r[4]||'').toUpperCase()};});
  return {latest,ever};
}
function starredDateFromKeyV4_(key){const p=String(key||'').split('-').map(Number);return p.length===3&&p.every(Number.isFinite)?new Date(p[0],p[1]-1,p[2],12,0,0,0):new Date();}
function starredPreviousActiveAnchorV4_(){
  const currentDay=Math.max(1,Number(starredRevisionActiveDay_()||1)),activeKey=starredRevisionActiveDate_(),d=starredDateFromKeyV4_(activeKey);if(currentDay>1)d.setDate(d.getDate()-1);
  return {eventAt:d,date:dateKey_(d)||activeKey,day:Math.max(1,currentDay-1),source:'previous-visible-day'};
}
function starredPerformanceOriginV4_(id,facts){
  const a=((facts&&facts.byId&&facts.byId[id])||[]).slice().sort((x,y)=>x.ts-y.ts);if(!a.length||!a[a.length-1].marked)return null;
  let i=a.length-1;while(i>0&&a[i-1].marked)i--;const ts=a[i].ts,date=dateKey_(ts);if(!date)return null;const day=typeof dailyDayNoV2_==='function'?Math.max(1,Number(dailyDayNoV2_(date)||1)):1;return {eventAt:ts,date,day,source:'performance-mark-history'};
}
function repairExistingStarredOrphansV4_(){
  const props=PropertiesService.getScriptProperties();if(props.getProperty(STARRED_ORIGIN_REPAIR_V4))return {already:true};
  const lock=LockService.getScriptLock();if(!lock.tryLock(10000))return {deferred:true};
  try{
    if(props.getProperty(STARRED_ORIGIN_REPAIR_V4))return {already:true};
    const active=starredStatusLastMarkedMapV4_(),events=starredEventStateV4_(),qids=new Set(allQuestions_().map(q=>String(q.id||'').trim())),facts=performanceFactsV2_(),fallback=starredPreviousActiveAnchorV4_(),rows=[];let inferred=0,anchored=0;
    Object.keys(active).forEach(id=>{if(!qids.has(id)||events.ever.has(id))return;const origin=starredPerformanceOriginV4_(id,facts)||fallback;if(origin.source==='performance-mark-history')inferred++;else anchored++;rows.push([id,origin.eventAt,origin.date,origin.day,'STAR']);});
    if(rows.length)starredRevisionLogSheet_().getRange(starredRevisionLogSheet_().getLastRow()+1,1,rows.length,5).setValues(rows);
    const meta={at:new Date().toISOString(),repaired:rows.length,inferred,anchored,fallbackDay:fallback.day,fallbackDate:fallback.date};props.setProperty(STARRED_ORIGIN_REPAIR_V4,JSON.stringify(meta));return meta;
  }finally{lock.releaseLock();}
}
function healFutureStarredOrphansV4_(){
  const active=starredStatusLastMarkedMapV4_(),events=starredEventStateV4_(),qids=new Set(allQuestions_().map(q=>String(q.id||'').trim())),missing=Object.keys(active).filter(id=>qids.has(id)&&!events.ever.has(id));if(!missing.length)return {healed:0};
  const lock=LockService.getScriptLock();if(!lock.tryLock(5000))return {deferred:true,missing:missing.length};
  try{
    const again=starredEventStateV4_(),now=new Date(),date=starredRevisionActiveDate_(),day=starredRevisionActiveDay_(),rows=missing.filter(id=>!again.ever.has(id)).map(id=>[id,now,date,day,'STAR']);if(rows.length)starredRevisionLogSheet_().getRange(starredRevisionLogSheet_().getLastRow()+1,1,rows.length,5).setValues(rows);return {healed:rows.length};
  }finally{lock.releaseLock();}
}
function ensureStableStarredOriginsV4_(){ensureStarredRevisionSeed_();const repaired=repairExistingStarredOrphansV4_();const healed=healFutureStarredOrphansV4_();return {repaired,healed};}
function starredRevisionIndexStableV4_(){
  ensureStableStarredOriginsV4_();
  const status=statusMap_(),centralStars=currentStarredMapV2_(),all=allQuestions_(),qmap=Object.fromEntries(all.map(q=>[q.id,q])),difficult=starredRevisionDifficultMap_(),events=starredEventStateV4_().latest,rows=[];
  Object.keys(qmap).forEach(id=>{
    const st=status[id]||{},ev=events[id],currentlyStarred=!!centralStars[id],mastered=!!st.mastered,ever=!!ev||currentlyStarred;if(!ever)return;if(!currentlyStarred&&!mastered)return;if(!ev||!ev.date||!ev.day)return;
    const q=qmap[id];rows.push({id,day:Math.max(1,Number(ev.day||1)),date:ev.date,starred:currentlyStarred,mastered,difficult:!!difficult[id],weak:isWeakStatus_(st),attempts:Number(st.attempts||0),word:q.word||'',question:q.question||'',topic:q.topic||'',source:q.sourceFile||q.sourceId||''});
  });
  return rows;
}
function getStarredRevisionHubStableV4(){const rows=starredRevisionIndexStableV4_(),currentDay=starredRevisionActiveDay_();return {currentDay,stats:starredRevisionStats_(rows),groups:starredRevisionHierarchy_(rows,currentDay)};}
function getStarredRevisionGroupStableV4(fromDay,toDay){const rows=starredRevisionIndexStableV4_().filter(x=>x.day>=Number(fromDay)&&x.day<=Number(toDay)),days=[];for(let d=Number(toDay);d>=Number(fromDay);d--){const part=rows.filter(x=>x.day===d),st=starredRevisionStats_(part);if(st.starred)days.push({label:'Day '+d,fromDay:d,toDay:d,stats:st});}return {stats:starredRevisionStats_(rows),days};}
function getStarredRevisionItemsStableV4(scope,kind){const sc=starredRevisionScope_(scope),mode=String(kind||'all').toLowerCase();return starredRevisionIndexStableV4_().filter(x=>x.day>=sc.fromDay&&x.day<=sc.toDay).filter(x=>mode==='mastered'?x.mastered:mode==='difficult'?x.starred&&!x.mastered&&x.difficult:true).sort((a,b)=>b.day-a.day||String(a.word||a.id).localeCompare(String(b.word||b.id)));}
function getStarredRevisionBatchStableV4(scope,kind,count){
  const sc=starredRevisionScope_(scope),mode=String(kind||'all').toLowerCase(),status=statusMap_(),index=starredRevisionIndexStableV4_(),byId=Object.fromEntries(index.map(x=>[x.id,x]));
  let pool=allQuestions_().filter(q=>{const x=byId[q.id];if(!x||x.day<sc.fromDay||x.day>sc.toDay)return false;if(mode==='mastered')return x.mastered;return x.starred&&!x.mastered&&isActive_(q);});
  if(mode==='weak')pool=pool.filter(q=>isWeakStatus_(status[q.id]||{}));if(mode==='difficult')pool=pool.filter(q=>!!byId[q.id]?.difficult);if(['all','weak','new','difficult','random'].includes(mode))shuffle_(pool);if(mode!=='all'&&mode!=='difficult'){const n=Math.max(1,Math.min(100,Number(count||10)));if(['random','weak','new'].includes(mode))pool=pool.slice(0,n);}
  return pool.map(q=>{const served=serveQuestion_(q);served.difficult=!!byId[q.id]?.difficult;served.marked=!!byId[q.id]?.starred;return served;});
}
function getStarredOriginAuditV4(){
  const active=starredStatusLastMarkedMapV4_(),events=starredEventStateV4_(),missing=Object.keys(active).filter(id=>!events.ever.has(id)),props=PropertiesService.getScriptProperties(),repair=props.getProperty(STARRED_ORIGIN_REPAIR_V4);return {activeStatusStars:Object.keys(active).length,loggedQuestionIds:events.ever.size,missingOriginIds:missing.slice(0,100),missingOriginCount:missing.length,repair:repair?JSON.parse(repair):null,currentDay:starredRevisionActiveDay_(),currentDate:starredRevisionActiveDate_()};
}

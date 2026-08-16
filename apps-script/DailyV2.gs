const DAILY_V2_ROLLOUT='2026-08-16';
const DAILY_V2_DAY1='2026-08-14';
const DAILY_V2_HISTORY='Daily_History';

function getBootstrapV2(){
  const cfg=config_(),all=allQuestions_(),status=statusMap_();
  const daily=ensureDailyV2_(all,status,Number(cfg.DAILY_TARGET||120));
  const counts={};
  all.forEach(q=>{if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;const id=canonicalCategory_(q.topic);counts[id]=(counts[id]||0)+1;});
  const categories=table_(EP.sheets.categories).filter(r=>truthy_(r.Active)).sort((a,b)=>Number(a.Display_Order||99)-Number(b.Display_Order||99)).map(r=>({id:r.Category_ID,name:r.Category_Name,parent:r.Parent_Category,home:truthy_(r.Home_Visible),count:Number(counts[r.Category_ID]||0)}));
  const today=todayKey_();
  const hinduToday=table_(EP.sheets.hindu).filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today).length;
  const recallIds=recallIds_(status);
  const recall=all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&recallIds.has(q.id)).length;
  const mastered=Object.keys(status).filter(id=>status[id].mastered).length;
  return {schemaVersion:Number(cfg.SCHEMA_VERSION||3),dailyTarget:Number(cfg.DAILY_TARGET||120),extraCounts:String(cfg.EXTRA_COUNTS||'10,20,30,50').split(',').map(Number).filter(Number.isFinite),categories,dailyInfo:daily.info,stats:{dailyTotal:daily.rows.length,dailyCompleted:daily.rows.filter(r=>String(r.Status||'').toLowerCase()==='completed').length,hinduToday,recall,mastered,totalActive:all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)).length}};
}

function getDailyBatchV2(){
  const all=allQuestions_(),status=statusMap_(),daily=ensureDailyV2_(all,status,Number(config_().DAILY_TARGET||120));
  const map=Object.fromEntries(all.map(q=>[q.id,q]));
  return daily.rows.filter(r=>String(r.Status||'').toLowerCase()!=='completed').map(r=>map[String(r.Question_ID||'').trim()]).filter(Boolean).filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)).map(serveQuestion_);
}

function ensureDailyV2_(all,status,target){
  target=Math.max(1,Number(target||120));
  const today=todayKey_(),s=sheet_(EP.sheets.daily);
  let rows=table_(EP.sheets.daily).filter(r=>String(r.Question_ID||'').trim());
  rows=normalizeDailyRowsV2_(rows,all,status,s);
  rows=syncDailyCompletionsFromPerformanceV2_(rows,s);

  // Preserve the already-created/completed 15 Aug set exactly as it is.
  if(today<DAILY_V2_ROLLOUT){
    const todayRows=rows.filter(r=>dateKey_(r.Quiz_Date)===today);
    return {rows:todayRows,info:dailyInfoV2_(todayRows,today,false,target)};
  }

  const batchDate=rows.length?dateKey_(rows[0].Quiz_Date):'';
  if(batchDate&&batchDate!==today){
    const done=rows.filter(r=>String(r.Status||'').toLowerCase()==='completed').length;
    if(done<rows.length){
      return {rows,info:dailyInfoV2_(rows,batchDate,true,target)};
    }
    archiveDailyV2_(rows,batchDate);
    const carryIds=previousMarkedIdsV2_(rows,status);
    if(s.getLastRow()>1)s.getRange(2,1,s.getLastRow()-1,Math.max(7,s.getLastColumn())).clearContent();
    rows=createDailyV2_(all,status,target,today,carryIds,s);
    return {rows,info:dailyInfoV2_(rows,today,false,target)};
  }

  if(batchDate===today&&rows.length)return {rows,info:dailyInfoV2_(rows,today,false,target)};
  rows=createDailyV2_(all,status,target,today,[],s);
  return {rows,info:dailyInfoV2_(rows,today,false,target)};
}

function createDailyV2_(all,status,target,today,carryIds,s){
  const active=q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered);
  const map=Object.fromEntries(all.map(q=>[q.id,q]));
  const carry=shuffle_((carryIds||[]).map(id=>map[id]).filter(q=>q&&active(q))).slice(0,Math.min(20,target));
  const carrySet=new Set(carry.map(q=>q.id));
  const fresh=all.filter(q=>active(q)&&!carrySet.has(q.id)&&Number((status[q.id]||{}).attempts||0)===0);
  const recent=[],other=[];
  fresh.forEach(q=>{const d=typeof recentContentDate_==='function'?recentContentDate_(q):null;(d?recent:other).push(q)});
  shuffle_(recent);shuffle_(other);
  const freshNeed=Math.max(0,target-carry.length),freshSelected=recent.concat(other).slice(0,freshNeed);
  const selected=[];
  freshSelected.forEach(q=>selected.push({q,priority:70,reason:(typeof recentContentDate_==='function'&&recentContentDate_(q))?'Fresh · Recent':'Fresh · Unseen'}));
  carry.forEach(q=>selected.push({q,priority:90,reason:'Yesterday Marked'}));
  shuffle_(selected);
  if(selected.length){const out=selected.map(x=>[x.q.id,x.priority,x.reason,today,'New',x.q.topic||'',x.q.conceptId||'']);s.getRange(2,1,out.length,7).setValues(out);}
  return table_(EP.sheets.daily).filter(r=>dateKey_(r.Quiz_Date)===today&&String(r.Question_ID||'').trim());
}

function previousMarkedIdsV2_(rows,status){
  return rows.map(r=>String(r.Question_ID||'').trim()).filter(id=>id&&status[id]&&status[id].marked);
}

function normalizeDailyRowsV2_(rows,all,status,s){
  const map=Object.fromEntries(all.map(q=>[q.id,q]));
  rows.forEach((r,i)=>{const id=String(r.Question_ID||'').trim(),q=map[id],done=String(r.Status||'').toLowerCase()==='completed';if(!done&&(!q||!isActive_(q)||(status[id]&&status[id].mastered))){s.getRange(i+2,5).setValue('Completed');r.Status='Completed';}});
  return rows;
}

function syncDailyCompletionsFromPerformanceV2_(rows,s){
  if(!rows.length)return rows;
  const perf=sheet_(EP.sheets.performance);
  if(perf.getLastRow()<2)return rows;
  const values=perf.getDataRange().getValues();
  if(values.length<2)return rows;
  const header=values[0].map(x=>String(x||'').trim().toLowerCase());
  let ti=header.findIndex(x=>x==='timestamp'||x==='time'||x==='attempt_time'||x==='attempt timestamp');
  let qi=header.findIndex(x=>x==='question_id'||x==='question id'||x==='questionid');
  if(ti<0)ti=0;if(qi<0)qi=1;
  const latest={};
  values.slice(1).forEach(r=>{const id=String(r[qi]||'').trim();if(!id)return;const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;if(!latest[id]||d>latest[id])latest[id]=d;});
  rows.forEach((r,i)=>{
    if(String(r.Status||'').toLowerCase()==='completed')return;
    const id=String(r.Question_ID||'').trim(),batchKey=dateKey_(r.Quiz_Date),attempt=latest[id];
    if(!id||!batchKey||!attempt)return;
    const parts=batchKey.split('-').map(Number),start=new Date(parts[0],parts[1]-1,parts[2],0,0,0,0);
    if(attempt>=start){s.getRange(i+2,5).setValue('Completed');r.Status='Completed';}
  });
  return rows;
}

function dailyInfoV2_(rows,activeDate,pending,target){
  const today=todayKey_(),dayNo=dailyDayNoV2_(activeDate||today),todayDayNo=dailyDayNoV2_(today);
  const reasons=rows.map(r=>String(r.Reason||''));
  return {activeDate:activeDate||today,dayNo,todayDayNo,pendingFromPrevious:!!pending,target:Number(target||120),freshCount:reasons.filter(x=>/^Fresh/.test(x)).length,carryCount:reasons.filter(x=>x==='Yesterday Marked').length,available:rows.length};
}

function dailyDayNoV2_(key){
  const a=String(DAILY_V2_DAY1).split('-').map(Number),b=String(key||todayKey_()).split('-').map(Number);
  const diff=Math.floor((Date.UTC(b[0],b[1]-1,b[2])-Date.UTC(a[0],a[1]-1,a[2]))/86400000);
  return Math.max(1,diff+1);
}

function ensureDailyHistoryV2_(){
  const ss=ss_();let s=ss.getSheetByName(DAILY_V2_HISTORY);if(!s){s=ss.insertSheet(DAILY_V2_HISTORY);s.getRange(1,1,1,9).setValues([['Quiz_Date','Day_No','Question_ID','Priority','Reason','Status','Topic','Concept_ID','Archived_At']]);s.setFrozenRows(1);}return s;
}

function archiveDailyV2_(rows,dateKey){
  if(!rows.length)return;const h=ensureDailyHistoryV2_(),existing=new Set();
  if(h.getLastRow()>1)h.getRange(2,1,h.getLastRow()-1,3).getValues().forEach(r=>existing.add(dateKey_(r[0])+'|'+String(r[2]||'')));
  const day=dailyDayNoV2_(dateKey),now=new Date(),out=[];
  rows.forEach(r=>{const id=String(r.Question_ID||'').trim(),k=dateKey+'|'+id;if(id&&!existing.has(k))out.push([dateKey,day,id,r.Priority||'',r.Reason||'',r.Status||'',r.Topic||'',r.Concept_ID||'',now]);});
  if(out.length)h.getRange(h.getLastRow()+1,1,out.length,9).setValues(out);
}

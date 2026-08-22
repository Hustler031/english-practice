const DAILY_V2_ROLLOUT='2026-08-16';
const DAILY_V2_DAY1='2026-08-14';
const DAILY_V2_HISTORY='Daily_History';

// Compatibility API: every existing caller keeps using V2 names, while the
// implementation is now the retention-aware adaptive V3 engine.
function getBootstrapV2(){return getBootstrapV3();}
function getDailyBatchV2(){return getDailyBatchV3();}
function ensureDailyV2_(all,status,target){return ensureDailyAdaptiveV3_(all,target);}
function createDailyV2_(all,status,target,batchDate,carryIds,s){return createDailyAdaptiveV3_(all,target,batchDate,s||sheet_(EP.sheets.daily));}

function previousMarkedIdsV2_(rows,status){const stars=currentStarredMapV2_();return rows.map(r=>String(r.Question_ID||'').trim()).filter(id=>id&&stars[id]);}
function normalizeDailyRowsV2_(rows,all,status,s){return normalizeDailyRowsV3_(rows,all,currentMasteredMapV2_(),s);}
function syncDailyCompletionsFromPerformanceV2_(rows,s){return syncDailyCompletionsV3_(rows,s);}

function repairSkippedDailyDateV2_(rows,s,today){
  if(!rows.length)return rows;const batchDate=dateKey_(rows[0].Quiz_Date),done=rows.filter(r=>String(r.Status||'').toLowerCase()==='completed').length;if(batchDate!==today||done>0)return rows;const latest=latestArchivedDailyDateV2_();if(!latest)return rows;const expected=addDaysKeyV2_(latest,1);if(expected>=today)return rows;if(s.getLastRow()>1)s.getRange(2,4,s.getLastRow()-1,1).setValue(expected);rows.forEach(r=>r.Quiz_Date=expected);return rows;
}
function latestArchivedDailyDateV2_(){const ss=ss_(),h=ss.getSheetByName(DAILY_V2_HISTORY);if(!h||h.getLastRow()<2)return'';const vals=h.getRange(2,1,h.getLastRow()-1,1).getValues();let latest='';vals.forEach(r=>{const k=dateKey_(r[0]);if(k&&(!latest||k>latest))latest=k;});return latest;}
function addDaysKeyV2_(key,days){const p=String(key||todayKey_()).split('-').map(Number),d=new Date(Date.UTC(p[0],p[1]-1,p[2]));d.setUTCDate(d.getUTCDate()+Number(days||0));return Utilities.formatDate(d,'UTC','yyyy-MM-dd');}
function dailyInfoV2_(rows,activeDate,pending,target){const today=todayKey_(),dayNo=dailyDayNoV2_(activeDate||today),todayDayNo=dailyDayNoV2_(today),reasons=rows.map(r=>String(r.Reason||''));return {activeDate:activeDate||today,dayNo,todayDayNo,pendingFromPrevious:!!pending,target:Number(target||120),freshCount:reasons.filter(x=>/^Fresh/.test(x)||x==='Controlled New').length,carryCount:reasons.filter(x=>x==='Yesterday Marked'||x==='Marked Review').length,available:rows.length};}
function dailyDayNoV2_(key){const a=String(DAILY_V2_DAY1).split('-').map(Number),b=String(key||todayKey_()).split('-').map(Number),diff=Math.floor((Date.UTC(b[0],b[1]-1,b[2])-Date.UTC(a[0],a[1]-1,a[2]))/86400000);return Math.max(1,diff+1);}
function ensureDailyHistoryV2_(){const ss=ss_();let s=ss.getSheetByName(DAILY_V2_HISTORY);if(!s){s=ss.insertSheet(DAILY_V2_HISTORY);s.getRange(1,1,1,9).setValues([['Quiz_Date','Day_No','Question_ID','Priority','Reason','Status','Topic','Concept_ID','Archived_At']]);s.setFrozenRows(1);}return s;}
function archiveDailyV2_(rows,dateKey){if(!rows.length)return;const h=ensureDailyHistoryV2_(),existing=new Set();if(h.getLastRow()>1)h.getRange(2,1,h.getLastRow()-1,3).getValues().forEach(r=>existing.add(dateKey_(r[0])+'|'+String(r[2]||'')));const day=dailyDayNoV2_(dateKey),now=new Date(),out=[];rows.forEach(r=>{const id=String(r.Question_ID||'').trim(),k=dateKey+'|'+id;if(id&&!existing.has(k))out.push([dateKey,day,id,r.Priority||'',r.Reason||'',r.Status||'',r.Topic||'',r.Concept_ID||'',now]);});if(out.length)h.getRange(h.getLastRow()+1,1,out.length,9).setValues(out);}

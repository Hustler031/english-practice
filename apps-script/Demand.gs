const DEMAND_SHEET = 'Demanded_Practice';

function ensureDemandSheet_(){
  const ss=ss_();
  let s=ss.getSheetByName(DEMAND_SHEET);
  if(!s){
    s=ss.insertSheet(DEMAND_SHEET);
    s.getRange(1,1,1,8).setValues([['Batch_ID','Batch_Name','Question_ID','Sequence','Created_Date','Created_By','Notes','Active']]);
    s.setFrozenRows(1);
  }
  return s;
}

function getDemandBatches(){
  const s=ensureDemandSheet_();
  if(s.getLastRow()<2) return [];
  const rows=s.getRange(2,1,s.getLastRow()-1,8).getValues();
  const groups={};
  rows.forEach(r=>{
    const active=r[7]===true || String(r[7]).toLowerCase()==='true' || String(r[7])==='1';
    if(!active) return;
    const id=String(r[0]||'').trim(), qid=String(r[2]||'').trim();
    if(!id||!qid) return;
    if(!groups[id]) groups[id]={id,name:String(r[1]||id),created:r[4],notes:String(r[6]||''),count:0};
    groups[id].count++;
  });
  return Object.values(groups).sort((a,b)=>new Date(b.created||0)-new Date(a.created||0)).map(x=>({
    id:x.id,name:x.name,count:x.count,created:x.created?Utilities.formatDate(new Date(x.created),Session.getScriptTimeZone(),'dd MMM yyyy'):'',notes:x.notes
  }));
}

function getDemandBatch(batchId){
  const id=String(batchId||'').trim();
  if(!id) throw new Error('Batch ID required');
  const s=ensureDemandSheet_();
  if(s.getLastRow()<2) return [];
  const rows=s.getRange(2,1,s.getLastRow()-1,8).getValues()
    .filter(r=>String(r[0]||'').trim()===id && (r[7]===true || String(r[7]).toLowerCase()==='true' || String(r[7])==='1'))
    .sort((a,b)=>Number(a[3]||0)-Number(b[3]||0));
  const all=allQuestions_(), map=Object.fromEntries(all.map(q=>[q.id,q])), status=statusMap_();
  return rows.map(r=>map[String(r[2]||'').trim()]).filter(q=>q&&isActive_(q)&&!(status[q.id]&&status[q.id].mastered)).map(serveQuestion_);
}

function createDemandBatch(batchName, questionIds, notes){
  const name=String(batchName||'').trim();
  const ids=[...new Set((questionIds||[]).map(x=>String(x||'').trim()).filter(Boolean))];
  if(!name) throw new Error('Batch name required');
  if(!ids.length) throw new Error('At least one Question ID required');
  const valid=new Set(allQuestions_().map(q=>q.id));
  const clean=ids.filter(id=>valid.has(id));
  if(!clean.length) throw new Error('None of the supplied Question IDs exist in Questions');
  const batchId='DEM-'+Utilities.formatDate(new Date(),Session.getScriptTimeZone(),'yyyyMMdd-HHmmss')+'-'+Math.random().toString(36).slice(2,6).toUpperCase();
  const now=new Date(), rows=clean.map((qid,i)=>[batchId,name,qid,i+1,now,'ChatGPT',String(notes||''),true]);
  const s=ensureDemandSheet_();
  s.getRange(s.getLastRow()+1,1,rows.length,8).setValues(rows);
  return {ok:true,batchId,name,count:rows.length};
}

function archiveDemandBatch(batchId){
  const id=String(batchId||'').trim(), s=ensureDemandSheet_();
  if(s.getLastRow()<2) return {ok:true};
  const vals=s.getRange(2,1,s.getLastRow()-1,8).getValues();
  vals.forEach((r,i)=>{if(String(r[0]||'').trim()===id)s.getRange(i+2,8).setValue(false)});
  return {ok:true};
}

// Cross-device sync for The Hindu daily quiz only.
// Daily 120 already syncs through Daily_Quiz + submitAnswer/markDaily_.
function getHinduQuizSynced(){
  const today=todayKey_();
  const done=new Set(
    table_(EP.sheets.hindu)
      .filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today&&String(r.Learning_Status||'').toLowerCase()==='completed')
      .map(r=>'HINDU_'+String(r.Hindu_ID||'').trim())
  );
  return getHinduQuiz().filter(q=>!done.has(q.id));
}

function submitHinduAnswer(payload){
  payload=payload||{};
  const raw=String(payload.questionId||'').trim();
  const id=raw.replace(/^HINDU_/,'');
  if(!id) throw new Error('Hindu word ID required');
  const s=sheet_(EP.sheets.hindu), row=findRow_(s,1,id);
  if(row<2) throw new Error('Hindu word not found');
  const now=new Date();
  const first=s.getRange(row,18).getValue();
  s.getRange(row,16).setValue('Completed');
  if(!first) s.getRange(row,18).setValue(now);
  s.getRange(row,19).setValue(now);
  return {ok:true,correct:!!payload.localCorrect,correctKey:String(payload.correctKey||'')};
}

function getHinduPracticeProgress(){
  const today=todayKey_();
  const rows=table_(EP.sheets.hindu).filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today);
  return {total:rows.length,completed:rows.filter(r=>String(r.Learning_Status||'').toLowerCase()==='completed').length};
}

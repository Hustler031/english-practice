const EP = Object.freeze({
  spreadsheetId: '1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak',
  sheets: {
    questions: 'Questions', performance: 'Performance', status: 'Question_Status',
    daily: 'Daily_Quiz', categories: 'Categories', sources: 'Sources', config: 'System_Config',
    hindu: 'Hindu_Words', recall: 'Recall_Check', mastered: 'Mastered_Log'
  }
});

function doGet() {
  return HtmlService.createTemplateFromFile('Index').evaluate()
    .setTitle('English Mastery')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

function include(name) { return HtmlService.createHtmlOutputFromFile(name).getContent(); }
function ss_() { return SpreadsheetApp.openById(EP.spreadsheetId); }
function sheet_(name) { const s = ss_().getSheetByName(name); if (!s) throw new Error('Missing sheet: ' + name); return s; }

function getBootstrap() {
  const cfg = table_(EP.sheets.config).reduce((a,r) => (a[String(r.Key||'').trim()] = r.Value, a), {});
  const categories = table_(EP.sheets.categories)
    .filter(r => truthy_(r.Active))
    .sort((a,b) => Number(a.Display_Order||99)-Number(b.Display_Order||99))
    .map(r => ({ id:r.Category_ID, name:r.Category_Name, parent:r.Parent_Category, home:truthy_(r.Home_Visible) }));
  const dailyRows = table_(EP.sheets.daily).filter(r => String(r.Question_ID||'').trim());
  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  const hinduToday = table_(EP.sheets.hindu).filter(r => truthy_(r.Active) && dateKey_(r.Date) === today).length;
  const recall = table_(EP.sheets.recall).filter(r => truthy_(r.Active)).length;
  const mastered = table_(EP.sheets.mastered).filter(r => truthy_(r.Active)).length;
  return {
    dailyTarget: Number(cfg.DAILY_TARGET||120),
    extraCounts: String(cfg.EXTRA_COUNTS||'10,20,30,50').split(',').map(Number).filter(Number.isFinite),
    categories,
    stats: {
      dailyTotal: dailyRows.length,
      dailyCompleted: dailyRows.filter(r => String(r.Status||'').toLowerCase()==='completed').length,
      hinduToday, recall, mastered
    }
  };
}

function getPracticeBatch(mode, options) {
  options = options || {};
  const count = Math.max(1, Math.min(120, Number(options.count||20)));
  const all = allQuestions_();
  const statusMap = statusMap_();
  const active = q => String(q.active||'').toLowerCase() !== 'false' && !(statusMap[q.id] && statusMap[q.id].mastered);
  let pool = [];

  if (mode === 'daily') {
    const ids = table_(EP.sheets.daily).filter(r => String(r.Question_ID||'').trim()).map(r => String(r.Question_ID).trim());
    const map = Object.fromEntries(all.map(q => [q.id,q]));
    pool = ids.map(id => map[id]).filter(Boolean);
  } else if (mode === 'category') {
    const wanted = String(options.category||'').trim();
    pool = all.filter(q => active(q) && canonicalCategory_(q.topic) === wanted);
  } else if (mode === 'new') {
    pool = all.filter(q => active(q) && ['','new'].includes(String(q.learningStatus||'').toLowerCase()));
  } else if (mode === 'random') {
    pool = all.filter(q => active(q) && !['','new'].includes(String(q.learningStatus||'').toLowerCase()));
  } else if (mode === 'recall') {
    const ids = new Set(table_(EP.sheets.recall).filter(r => truthy_(r.Active)).map(r => String(r.Existing_Question_ID||'').trim()));
    pool = all.filter(q => active(q) && ids.has(q.id));
  } else if (mode === 'weak') {
    const ids = new Set(Object.keys(statusMap).filter(id => ['weak','wrong'].includes(String(statusMap[id].status||'').toLowerCase()) || Number(statusMap[id].wrong||0)>0));
    pool = all.filter(q => active(q) && ids.has(q.id));
  } else if (mode === 'due') {
    const now = new Date();
    const ids = new Set(Object.keys(statusMap).filter(id => statusMap[id].nextReview && new Date(statusMap[id].nextReview) <= now));
    pool = all.filter(q => active(q) && ids.has(q.id));
  }

  if (mode !== 'daily') shuffle_(pool);
  return pool.slice(0, mode === 'daily' ? pool.length : count).map(serveQuestion_);
}

function submitAnswer(payload) {
  payload = payload || {};
  const id = String(payload.questionId||'').trim();
  const selectedKey = String(payload.selectedKey||'').toUpperCase();
  if (!id || !['A','B','C','D'].includes(selectedKey)) throw new Error('Invalid answer');
  const q = findQuestion_(id); if (!q) throw new Error('Question not found');
  const correctKey = String(q.correct||'').toUpperCase();
  const isCorrect = selectedKey === correctKey;
  const now = new Date();
  const secs = Math.max(0, Number(payload.timeSeconds||0));
  const marked = !!payload.marked;
  const attemptId = id + '-' + now.getTime() + '-' + Math.random().toString(36).slice(2,8);

  sheet_(EP.sheets.performance).appendRow([now,id,selectedKey,isCorrect,secs,marked,attemptId,q.topic||'',q.conceptId||'']);
  const status = upsertStatus_(q,isCorrect,secs,marked,now);
  markDaily_(id);
  setQuestionLearningStatus_(id, status.status === 'Strong' ? 'Active' : 'Learning');

  return { correct:isCorrect, correctKey, status:status.status, nextReview:status.nextReview };
}

function setMarked(questionId, marked) {
  const s = sheet_(EP.sheets.status), row = findRow_(s, 1, questionId);
  if (row > 1) s.getRange(row, 11).setValue(!!marked);
  return {ok:true};
}

function markMastered(questionId) {
  const q = findQuestion_(questionId); if (!q) throw new Error('Question not found');
  const statusSheet = sheet_(EP.sheets.status);
  let row = findRow_(statusSheet,1,questionId);
  if (row < 2) {
    statusSheet.appendRow([questionId,0,0,0,0,0,0,'','','',false,0,'Mastered','',q.topic||'',q.conceptId||'',true,new Date(),'','']);
  } else {
    statusSheet.getRange(row,17,1,2).setValues([[true,new Date()]]);
    statusSheet.getRange(row,13).setValue('Mastered');
  }
  sheet_(EP.sheets.mastered).appendRow([questionId,new Date(),'User marked as easy/mastered','',q.sourceFile||'',canonicalCategory_(q.topic),'',true]);
  setQuestionLearningStatus_(questionId,'Mastered');
  return {ok:true};
}

function upsertStatus_(q, ok, secs, marked, now) {
  const s=sheet_(EP.sheets.status), row=findRow_(s,1,q.id);
  let attempts=1, correct=ok?1:0, wrong=ok?0:1, markedCount=marked?1:0, avg=secs, streak=ok?1:0;
  if (row>1) {
    const r=s.getRange(row,1,1,20).getValues()[0];
    attempts=Number(r[1]||0)+1; correct=Number(r[2]||0)+(ok?1:0); wrong=Number(r[3]||0)+(ok?0:1);
    markedCount=Number(r[5]||0)+(marked?1:0); avg=((Number(r[6]||0)*(attempts-1))+secs)/attempts;
    streak=ok?Number(r[11]||0)+1:0;
  }
  const accuracy=attempts?correct/attempts:0;
  let status='Learning'; if(marked)status='Marked'; else if(!ok||accuracy<.7)status='Weak'; else if(attempts>=3&&accuracy>=.85&&streak>=2)status='Strong';
  const next=nextReview_(ok,streak,marked,now);
  const values=[[q.id,attempts,correct,wrong,accuracy,markedCount,avg,now,ok,secs,marked,streak,status,next,q.topic||'',q.conceptId||'',false,'','',0]];
  if(row>1) s.getRange(row,1,1,20).setValues(values); else s.appendRow(values[0]);
  return {status,nextReview:next.toISOString()};
}

function nextReview_(ok,streak,marked,now){ let days=marked||!ok?1:streak<=1?2:streak===2?4:streak===3?7:streak===4?14:30; const d=new Date(now); d.setDate(d.getDate()+days); return d; }
function markDaily_(id){ const s=sheet_(EP.sheets.daily), row=findRow_(s,1,id); if(row>1)s.getRange(row,5).setValue('Completed'); }
function setQuestionLearningStatus_(id,status){ const s=sheet_(EP.sheets.questions), row=findRow_(s,1,id); if(row>1)s.getRange(row,18).setValue(status); }
function findRow_(s,col,id){ const cell=s.getRange(1,col,s.getLastRow(),1).createTextFinder(String(id)).matchEntireCell(true).findNext(); return cell?cell.getRow():-1; }
function findQuestion_(id){ const s=sheet_(EP.sheets.questions), row=findRow_(s,1,id); if(row<2)return null; return questionFromRow_(s.getRange(row,1,1,32).getValues()[0]); }

function allQuestions_(){ const s=sheet_(EP.sheets.questions), last=s.getLastRow(); if(last<2)return[]; return s.getRange(2,1,last-1,32).getValues().filter(r=>String(r[0]||'').trim()).map(questionFromRow_); }
function questionFromRow_(r){ return {id:String(r[0]),topic:r[1],word:r[2],question:r[3],options:{A:r[4],B:r[5],C:r[6],D:r[7]},correct:r[8],explanation:r[9],subtopic:r[10],questionType:r[11],sourceFile:r[12],sourcePage:r[13],conceptId:r[14],difficulty:r[15],sourceId:r[16],learningStatus:r[17],contentStatus:r[18],tip:r[24],usageNote:r[25],example:r[26],memoryAid:r[27],related:r[28],sourceUrl:r[29],active:r[31]}; }
function serveQuestion_(q){
  const entries=['A','B','C','D'].map(k=>({key:k,text:String(q.options[k]||'')}));
  if (shuffleSafe_(q, entries)) shuffle_(entries);
  return {id:q.id,category:canonicalCategory_(q.topic),topic:q.topic,word:q.word,question:q.question,options:entries,explanation:q.explanation,tip:q.tip,usageNote:q.usageNote,example:q.example,memoryAid:q.memoryAid,related:q.related,source:q.sourceFile,sourcePage:q.sourcePage};
}
function shuffleSafe_(q,entries){ const type=String(q.questionType||'').toLowerCase(); if(/order|sequence|match|arrange|para/.test(type))return false; return !entries.some(o=>/all of the above|none of the above|both [a-d]|either [a-d]/i.test(o.text)); }
function shuffle_(a){ for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];} return a; }
function canonicalCategory_(topic){ const t=String(topic||'').toLowerCase(); if(t.includes('spelling'))return'SPELLING'; if(t.includes('idiom'))return'IDIOM'; if(t.includes('phrasal'))return'PHRASAL'; if(t.includes('one word'))return'OWS'; if(t.includes('synonym')||t.includes('antonym'))return'SYN_ANT'; if(t.includes('confus'))return'CONFUSED'; if(t.includes('error'))return'ERROR'; if(t.includes('grammar'))return'GRAMMAR'; if(t.includes('vocab'))return'VOC'; return 'MISC'; }
function statusMap_(){ const out={}; table_(EP.sheets.status).forEach(r=>out[String(r.Question_ID||'').trim()]={status:r.Status,wrong:r.Wrong,nextReview:r.Next_Review,mastered:truthy_(r.Mastered)}); return out; }
function table_(name){ const s=sheet_(name), lr=s.getLastRow(), lc=s.getLastColumn(); if(lr<2)return[]; const v=s.getRange(1,1,lr,lc).getValues(), h=v.shift().map(String); return v.map(r=>{const o={};h.forEach((k,i)=>{if(k)o[k]=r[i]});return o;}); }
function truthy_(v){ return v===true || String(v||'').toLowerCase()==='true'; }
function dateKey_(v){ if(!v)return''; const d=v instanceof Date?v:new Date(v); return isNaN(d)?'':Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd'); }

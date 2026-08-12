const EP = Object.freeze({
  spreadsheetId: '1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak',
  sheets: Object.freeze({ questions:'Questions', performance:'Performance', status:'Question_Status', dailyQuiz:'Daily_Quiz', sources:'Sources', config:'System_Config' }),
  schemaVersion: 3,
  maxQuestionBatch: 100
});

function doGet(e) {
  const p=(e&&e.parameter)||{};
  try {
    const action=String(p.action||'health').trim();
    let data;
    switch(action){
      case 'health': data={service:'english-practice-api',version:EP.schemaVersion}; break;
      case 'config': data=getConfig_(); break;
      case 'categories': data=getCategories_(); break;
      case 'sources': data=getSources_(); break;
      case 'questions': data=getQuestions_(p); break;
      case 'dailyQuiz': data=getDailyQuiz_(); break;
      case 'weakQuestions': data=getStatusQuestions_('Weak',p); break;
      case 'wrongQuestions': data=getWrongQuestions_(p); break;
      case 'revision': data=getRevisionQuestions_(p); break;
      case 'saveAnswer': return withLock_(function(){ return output_({ok:true,data:saveAnswer_(p)},p.callback); });
      default: return output_({ok:false,error:'UNKNOWN_ACTION'},p.callback);
    }
    return output_({ok:true,data:data},p.callback);
  } catch(err) {
    console.error(err);
    return output_({ok:false,error:err&&err.message?err.message:'SERVER_ERROR'},p.callback);
  }
}

function doPost(e){
  const p=(e&&e.parameter)||{};
  try { if(String(p.action||'')==='saveAnswer') return withLock_(function(){return output_({ok:true,data:saveAnswer_(p)},p.callback);}); return output_({ok:false,error:'UNKNOWN_ACTION'},p.callback); }
  catch(err){ return output_({ok:false,error:err&&err.message?err.message:'SERVER_ERROR'},p.callback); }
}

function withLock_(fn){ const lock=LockService.getScriptLock(); lock.waitLock(10000); try{return fn();}finally{try{lock.releaseLock();}catch(_){}} }

function output_(payload,callback){
  const json=JSON.stringify(payload);
  const cb=String(callback||'').trim();
  if(cb && /^[A-Za-z_$][0-9A-Za-z_$\.]*$/.test(cb)) return ContentService.createTextOutput(cb+'('+json+');').setMimeType(ContentService.MimeType.JAVASCRIPT);
  return ContentService.createTextOutput(json).setMimeType(ContentService.MimeType.JSON);
}

function saveAnswer_(p){
  const questionId=String(p.questionId||'').trim(), selected=String(p.selectedAnswer||'').trim().toUpperCase(), attemptId=String(p.clientAttemptId||'').trim();
  const marked=normalizeBoolean_(p.markedRevision), timeSeconds=Math.max(0,Number(p.timeSeconds||0));
  if(!questionId) throw new Error('MISSING_QUESTION_ID'); if(!['A','B','C','D'].includes(selected)) throw new Error('INVALID_ANSWER'); if(!attemptId) throw new Error('MISSING_ATTEMPT_ID');
  const perf=getSheet_(EP.sheets.performance);
  const existing=perf.getLastRow()>=2?perf.getRange(2,7,perf.getLastRow()-1,1).getDisplayValues().flat():[];
  if(existing.includes(attemptId)) return {duplicate:true,attemptId:attemptId};
  const q=findQuestion_(questionId); if(!q) throw new Error('QUESTION_NOT_FOUND');
  const correct=selected===String(q.correct||'').toUpperCase(), now=new Date();
  perf.appendRow([now,questionId,selected,correct,timeSeconds,marked,attemptId,q.topic||'',q.conceptId||'']);
  const status=upsertQuestionStatus_(q,correct,timeSeconds,marked,now); markDailyCompleted_(questionId);
  return {duplicate:false,attemptId:attemptId,questionId:questionId,correct:correct,correctAnswer:q.correct,status:status};
}

function upsertQuestionStatus_(q,isCorrect,timeSeconds,marked,now){
  const s=getSheet_(EP.sheets.status), last=s.getLastRow(); let rowIndex=-1,prev=null;
  if(last>=2){const rows=s.getRange(2,1,last-1,16).getValues();for(let i=0;i<rows.length;i++)if(String(rows[i][0]||'').trim()===String(q.id)){rowIndex=i+2;prev=rows[i];break;}}
  const attempts=Number(prev&&prev[1]||0)+1, correct=Number(prev&&prev[2]||0)+(isCorrect?1:0), wrong=Number(prev&&prev[3]||0)+(isCorrect?0:1), accuracy=attempts?correct/attempts:0;
  const markedCount=Number(prev&&prev[5]||0)+(marked?1:0), oldAvg=Number(prev&&prev[6]||0), avg=((oldAvg*(attempts-1))+timeSeconds)/attempts, oldStreak=Number(prev&&prev[11]||0), streak=isCorrect?oldStreak+1:0;
  let status='Learning'; if(marked)status='Marked'; else if(!isCorrect||accuracy<.7)status='Weak'; else if(attempts>=3&&accuracy>=.85&&streak>=2)status='Strong';
  const next=nextReviewDate_(isCorrect,streak,marked,now), values=[[q.id,attempts,correct,wrong,accuracy,markedCount,avg,now,isCorrect,timeSeconds,marked,streak,status,next,q.topic||'',q.conceptId||'']];
  if(rowIndex>0)s.getRange(rowIndex,1,1,16).setValues(values);else s.appendRow(values[0]);
  return {attempts:attempts,correct:correct,wrong:wrong,accuracy:accuracy,streak:streak,status:status,nextReview:next.toISOString()};
}
function nextReviewDate_(ok,streak,marked,now){let d=1;if(marked||!ok)d=1;else if(streak<=1)d=2;else if(streak===2)d=4;else if(streak===3)d=7;else if(streak===4)d=14;else d=30;const x=new Date(now);x.setDate(x.getDate()+d);return x;}
function markDailyCompleted_(id){const s=getSheet_(EP.sheets.dailyQuiz),last=s.getLastRow();if(last<2)return;const ids=s.getRange(2,1,last-1,1).getDisplayValues();for(let i=0;i<ids.length;i++)if(String(ids[i][0]||'').trim()===id){s.getRange(i+2,5).setValue('Completed');return;}}
function getConfig_(){const rows=readTable_(EP.sheets.config),v={};rows.forEach(r=>{const k=String(r.Key||'').trim();if(k)v[k]=r.Value;});return{schemaVersion:EP.schemaVersion,dailyTarget:Number(v.DAILY_TARGET||120),extraCounts:String(v.EXTRA_COUNTS||'10,20,30,50').split(',').map(x=>Number(x.trim())).filter(Number.isFinite),databaseRole:String(v.DATABASE_ROLE||'PRIMARY')};}
function getCategories_(){const counts={};allQuestions_().forEach(q=>{const t=String(q.topic||'').trim();if(t)counts[t]=(counts[t]||0)+1;});return Object.keys(counts).sort().map(name=>({name:name,count:counts[name]}));}
function getSources_(){return readTable_(EP.sheets.sources).filter(r=>String(r.Source_ID||'').trim()).map(r=>({sourceId:r.Source_ID,sourceType:r.Source_Type,sourceName:r.Source_Name,sourceFile:r.Source_File,sourceDate:normalizeValue_(r.Source_Date),active:normalizeBoolean_(r.Active),importedOn:normalizeValue_(r.Imported_On),questionCount:Number(r.Question_Count||0),sourceRef:r.Source_Ref,notes:r.Notes}));}
function getQuestions_(p){const limit=clamp_(Number(p.count||20),1,EP.maxQuestionBatch),topic=String(p.topic||'').trim().toLowerCase(),source=String(p.source||'').trim().toLowerCase(),qt=String(p.questionType||'').trim().toLowerCase();return allQuestions_().filter(q=>(!topic||String(q.topic).toLowerCase()===topic)&&(!source||String(q.sourceFile).toLowerCase()===source)&&(!qt||String(q.questionType).toLowerCase()===qt)).sort(()=>Math.random()-.5).slice(0,limit);}
function getDailyQuiz_(){const rows=readTable_(EP.sheets.dailyQuiz).filter(r=>String(r.Question_ID||'').trim()),map=new Map(allQuestions_().map(q=>[String(q.id),q]));return rows.map(r=>{const q=map.get(String(r.Question_ID).trim());if(!q)return null;q.daily={priority:r.Priority,reason:r.Reason,quizDate:normalizeValue_(r.Quiz_Date),status:r.Status};return q;}).filter(Boolean);}
function getStatusQuestions_(name,p){const ids=readTable_(EP.sheets.status).filter(r=>String(r.Status||'').trim().toLowerCase()===name.toLowerCase()).map(r=>String(r.Question_ID||'').trim());return questionsByIds_(ids).slice(0,clamp_(Number(p.count||20),1,EP.maxQuestionBatch));}
function getWrongQuestions_(p){const ids=readTable_(EP.sheets.status).filter(r=>Number(r.Wrong||0)>0).map(r=>String(r.Question_ID||'').trim());return questionsByIds_(ids).slice(0,clamp_(Number(p.count||20),1,EP.maxQuestionBatch));}
function getRevisionQuestions_(p){const now=new Date(),ids=readTable_(EP.sheets.status).filter(r=>{if(!r.Next_Review)return false;const d=r.Next_Review instanceof Date?r.Next_Review:new Date(r.Next_Review);return !isNaN(d.getTime())&&d<=now;}).map(r=>String(r.Question_ID||'').trim());return questionsByIds_(ids).slice(0,clamp_(Number(p.count||20),1,EP.maxQuestionBatch));}
function questionsByIds_(ids){const set=new Set(ids.filter(Boolean));return allQuestions_().filter(q=>set.has(String(q.id)));}
function allQuestions_(){const s=getSheet_(EP.sheets.questions),last=s.getLastRow();if(last<2)return[];return s.getRange(2,1,last-1,16).getValues().filter(r=>String(r[0]||'').trim()).map(questionFromRow_);}
function findQuestion_(id){return allQuestions_().find(q=>String(q.id)===String(id))||null;}
function questionFromRow_(r){return{id:r[0],topic:r[1],word:r[2],question:r[3],options:[r[4],r[5],r[6],r[7]],correct:r[8],explanation:r[9],subtopic:r[10],questionType:r[11],sourceFile:r[12],sourcePage:r[13],conceptId:r[14],difficulty:r[15]};}
function readTable_(name){const s=getSheet_(name),last=s.getLastRow(),cols=s.getLastColumn();if(last<2||cols<1)return[];const v=s.getRange(1,1,last,cols).getValues(),h=v.shift().map(x=>String(x||'').trim());return v.map(r=>{const o={};h.forEach((x,i)=>{if(x)o[x]=r[i];});return o;});}
function getSheet_(name){const s=SpreadsheetApp.openById(EP.spreadsheetId).getSheetByName(name);if(!s)throw new Error('MISSING_SHEET_'+name);return s;}
function clamp_(v,min,max){return Number.isFinite(v)?Math.min(max,Math.max(min,Math.floor(v))):min;}
function normalizeBoolean_(v){return v===true||String(v||'').trim().toLowerCase()==='true';}
function normalizeValue_(v){return v instanceof Date?v.toISOString():v;}

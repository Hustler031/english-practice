const EP = Object.freeze({
  spreadsheetId: '1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak',
  sheets: {
    questions: 'Questions', performance: 'Performance', status: 'Question_Status',
    daily: 'Daily_Quiz', categories: 'Categories', sources: 'Sources', config: 'System_Config',
    hindu: 'Hindu_Words', recall: 'Recall_Check', mastered: 'Mastered_Log'
  },
  cache: { questionsMeta:'EP_Q_META_V2', questionsPrefix:'EP_Q2_', status:'EP_STATUS_V2' }
});

function doGet() {
  return HtmlService.createTemplateFromFile('Index').evaluate()
    .setTitle('English Mastery')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1, viewport-fit=cover')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

function include(name) { return HtmlService.createHtmlOutputFromFile(name).getContent(); }
function ss_() { return SpreadsheetApp.openById(EP.spreadsheetId); }
function sheet_(name) { const s=ss_().getSheetByName(name); if(!s) throw new Error('Missing sheet: '+name); return s; }
function todayKey_(){ return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd'); }

function getBootstrap() {
  const cfg=config_();
  const all=allQuestions_();
  const status=statusMap_();
  const daily=ensureDailyBatch_(all,status,Number(cfg.DAILY_TARGET||120));
  const counts={};
  all.forEach(q=>{
    if(!isActive_(q) || (status[q.id]&&status[q.id].mastered)) return;
    const id=canonicalCategory_(q.topic); counts[id]=(counts[id]||0)+1;
  });
  const categories=table_(EP.sheets.categories)
    .filter(r=>truthy_(r.Active))
    .sort((a,b)=>Number(a.Display_Order||99)-Number(b.Display_Order||99))
    .map(r=>({id:r.Category_ID,name:r.Category_Name,parent:r.Parent_Category,home:truthy_(r.Home_Visible),count:Number(counts[r.Category_ID]||0)}));
  const today=todayKey_();
  const hinduToday=table_(EP.sheets.hindu).filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today).length;
  const recallIds=recallIds_(status);
  const recall=all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&recallIds.has(q.id)).length;
  const mastered=Object.keys(status).filter(id=>status[id].mastered).length;
  return {
    schemaVersion:Number(cfg.SCHEMA_VERSION||3), dailyTarget:Number(cfg.DAILY_TARGET||120),
    extraCounts:String(cfg.EXTRA_COUNTS||'10,20,30,50').split(',').map(Number).filter(Number.isFinite),
    categories,
    stats:{dailyTotal:daily.rows.length,dailyCompleted:daily.rows.filter(r=>String(r.Status||'').toLowerCase()==='completed').length,hinduToday,recall,mastered,totalActive:all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)).length}
  };
}

function warmPracticeCache(){ return {count:allQuestions_().length}; }

function getPracticeBatch(mode, options) {
  options=options||{};
  const requested=Math.max(1,Math.min(120,Number(options.count||20)));
  const all=allQuestions_();
  const status=statusMap_();
  const active=q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered);
  let pool=[];

  if(mode==='daily'){
    const daily=ensureDailyBatch_(all,status,Number(config_().DAILY_TARGET||120));
    const map=Object.fromEntries(all.map(q=>[q.id,q]));
    pool=daily.rows.filter(r=>String(r.Status||'').toLowerCase()!=='completed').map(r=>map[String(r.Question_ID||'').trim()]).filter(Boolean).filter(active);
  } else if(mode==='category'){
    const wanted=String(options.category||'').trim(); pool=all.filter(q=>active(q)&&canonicalCategory_(q.topic)===wanted);
  } else if(mode==='new'){
    pool=all.filter(q=>active(q)&&['','new'].includes(String(q.learningStatus||'').toLowerCase()));
  } else if(mode==='random'){
    pool=all.filter(active);
  } else if(mode==='recall'){
    const ids=recallIds_(status);
    pool=all.filter(q=>active(q)&&ids.has(q.id));
  } else if(mode==='weak'){
    const ids=new Set(Object.keys(status).filter(id=>['weak','wrong'].includes(String(status[id].status||'').toLowerCase())||Number(status[id].wrong||0)>0));
    pool=all.filter(q=>active(q)&&ids.has(q.id));
  } else if(mode==='due'){
    const now=new Date(); const ids=new Set(Object.keys(status).filter(id=>status[id].nextReview&&new Date(status[id].nextReview)<=now));
    pool=all.filter(q=>active(q)&&ids.has(q.id));
  } else if(mode==='source'){
    const sourceKey=String(options.source||'');
    pool=all.filter(q=>active(q)&&sourceKey_(q)===sourceKey);
  }

  if(mode!=='daily') shuffle_(pool);
  const limit=mode==='daily'?pool.length:Math.min(requested,pool.length);
  return pool.slice(0,limit).map(serveQuestion_);
}

function getSources(){
  const all=allQuestions_(), status=statusMap_(), grouped={};
  all.forEach(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered)) return;
    const key=sourceKey_(q); if(!key) return;
    if(!grouped[key]) grouped[key]={key,name:q.sourceFile||q.sourceId||'Unlabelled source',sourceId:q.sourceId||'',count:0,categories:{}};
    grouped[key].count++; const cat=canonicalCategory_(q.topic); grouped[key].categories[cat]=(grouped[key].categories[cat]||0)+1;
  });
  return Object.values(grouped).sort((a,b)=>a.name.localeCompare(b.name)).map(x=>({key:x.key,name:x.name,sourceId:x.sourceId,count:x.count,categorySummary:Object.entries(x.categories).map(([k,v])=>k+': '+v).join(' · ')}));
}

function getHinduToday(){
  const today=todayKey_();
  return table_(EP.sheets.hindu).filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today).map(r=>({
    id:r.Hindu_ID,date:dateKey_(r.Date),word:r.Word,pos:r.Part_of_Speech,meaning:r.Meaning,synonyms:r.Synonyms,antonyms:r.Antonyms,
    example:r.Example_Sentence,family:r.Word_Family,usage:r.Usage_Note,tip:r.Tip,memory:r.Memory_Aid,article:r.Article_Title,sourceUrl:r.Source_URL,sourceName:r.Source_Name
  }));
}

function getHinduQuiz(){
  const words=getHinduToday(); if(words.length<2) return [];
  const meanings=words.map(w=>String(w.meaning||'').trim()).filter(Boolean);
  return words.filter(w=>w.word&&w.meaning).map(w=>{
    const distractors=shuffle_(meanings.filter(m=>m!==w.meaning)).slice(0,3);
    while(distractors.length<3) distractors.push('None of these meanings');
    const opts=shuffle_([{key:'CORRECT',text:w.meaning},...distractors.map((x,i)=>({key:'D'+i,text:x}))]);
    const correctIndex=opts.findIndex(o=>o.key==='CORRECT');
    return {id:'HINDU_'+w.id,category:'HINDU_VOCAB',topic:'The Hindu Vocabulary',word:w.word,question:'What is the closest meaning of '+w.word+'?',options:opts.map((o,i)=>({key:['A','B','C','D'][i],text:o.text})),correctKey:['A','B','C','D'][correctIndex],explanation:w.meaning,example:w.example,usageNote:w.usage,tip:w.tip,memoryAid:w.memory,related:w.synonyms?('Synonyms: '+w.synonyms):'',source:w.sourceName||'The Hindu',sourcePage:''};
  });
}

function getMasteredItems(){
  const all=allQuestions_(), map=Object.fromEntries(all.map(q=>[q.id,q])), status=statusMap_();
  return Object.keys(status).filter(id=>status[id].mastered&&map[id]).map(id=>({id,word:map[id].word,question:map[id].question,topic:map[id].topic,source:map[id].sourceFile||''})).sort((a,b)=>String(a.word||a.id).localeCompare(String(b.word||b.id)));
}

function restoreMastered(questionId){
  const id=String(questionId||'').trim(); if(!id) throw new Error('Question ID required');
  const s=sheet_(EP.sheets.status), row=findRow_(s,1,id);
  if(row>1){ s.getRange(row,13).setValue('Learning'); s.getRange(row,17).setValue(false); s.getRange(row,18).clearContent(); }
  const m=sheet_(EP.sheets.mastered); if(m.getLastRow()>1){
    const vals=m.getRange(2,1,m.getLastRow()-1,8).getValues();
    vals.forEach((r,i)=>{if(String(r[0])===id&&truthy_(r[7])) m.getRange(i+2,8).setValue(false);});
  }
  setQuestionLearningStatus_(id,'Learning'); clearStatusCache_(); return {ok:true};
}

function submitAnswer(payload){
  payload=payload||{}; const id=String(payload.questionId||'').trim(); const selectedKey=String(payload.selectedKey||'').toUpperCase();
  if(!id||!['A','B','C','D'].includes(selectedKey)) throw new Error('Invalid answer');
  if(id.startsWith('HINDU_')) return {correct:!!payload.localCorrect,correctKey:String(payload.correctKey||'')};
  const q=findQuestion_(id); if(!q) throw new Error('Question not found');
  const correctKey=String(q.correct||'').toUpperCase(), isCorrect=selectedKey===correctKey, now=new Date(), secs=Math.max(0,Number(payload.timeSeconds||0)), marked=!!payload.marked;
  const attemptId=id+'-'+now.getTime()+'-'+Math.random().toString(36).slice(2,8);
  sheet_(EP.sheets.performance).appendRow([now,id,selectedKey,isCorrect,secs,marked,attemptId,q.topic||'',q.conceptId||'']);
  const st=upsertStatus_(q,isCorrect,secs,marked,now); markDaily_(id); setQuestionLearningStatus_(id,st.status==='Strong'?'Active':'Learning'); clearStatusCache_();
  return {correct:isCorrect,correctKey,status:st.status,nextReview:st.nextReview};
}

function setMarked(questionId,marked){
  const s=sheet_(EP.sheets.status), row=findRow_(s,1,questionId);
  if(row>1) s.getRange(row,11).setValue(!!marked); else {
    const q=findQuestion_(questionId); if(q) s.appendRow([q.id,0,0,0,0,marked?1:0,0,'','',0,!!marked,0,marked?'Marked':'Learning','',q.topic||'',q.conceptId||'',false,'','','']);
  }
  clearStatusCache_(); return {ok:true};
}

function markMastered(questionId){
  const q=findQuestion_(questionId); if(!q) throw new Error('Question not found');
  const s=sheet_(EP.sheets.status), row=findRow_(s,1,questionId);
  if(row<2) s.appendRow([questionId,0,0,0,0,0,0,'','','',false,0,'Mastered','',q.topic||'',q.conceptId||'',true,new Date(),'','']);
  else {s.getRange(row,13).setValue('Mastered');s.getRange(row,17,1,2).setValues([[true,new Date()]]);}
  sheet_(EP.sheets.mastered).appendRow([questionId,new Date(),'User marked as easy/mastered','',q.sourceFile||'',canonicalCategory_(q.topic),'',true]);
  setQuestionLearningStatus_(questionId,'Mastered'); clearStatusCache_(); return {ok:true};
}

function upsertStatus_(q,ok,secs,marked,now){
  const s=sheet_(EP.sheets.status), row=findRow_(s,1,q.id); let attempts=1,correct=ok?1:0,wrong=ok?0:1,markedCount=marked?1:0,avg=secs,streak=ok?1:0;
  if(row>1){const r=s.getRange(row,1,1,20).getValues()[0];attempts=Number(r[1]||0)+1;correct=Number(r[2]||0)+(ok?1:0);wrong=Number(r[3]||0)+(ok?0:1);markedCount=Number(r[5]||0)+(marked?1:0);avg=((Number(r[6]||0)*(attempts-1))+secs)/attempts;streak=ok?Number(r[11]||0)+1:0;}
  const accuracy=attempts?correct/attempts:0; let status='Learning'; if(marked)status='Marked'; else if(!ok||accuracy<.7)status='Weak'; else if(attempts>=3&&accuracy>=.85&&streak>=2)status='Strong';
  const next=nextReview_(ok,streak,marked,now); const values=[[q.id,attempts,correct,wrong,accuracy,markedCount,avg,now,ok,secs,marked,streak,status,next,q.topic||'',q.conceptId||'',false,'','',0]];
  if(row>1) s.getRange(row,1,1,20).setValues(values); else s.appendRow(values[0]); return {status,nextReview:next.toISOString()};
}

function nextReview_(ok,streak,marked,now){let days=marked||!ok?1:streak<=1?2:streak===2?4:streak===3?7:streak===4?14:30;const d=new Date(now);d.setDate(d.getDate()+days);return d;}

function ensureDailyBatch_(all,status,target){
  const today=todayKey_(), valid=new Map(all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)).map(q=>[q.id,q]));
  const existing=table_(EP.sheets.daily).filter(r=>dateKey_(r.Quiz_Date)===today&&valid.has(String(r.Question_ID||'').trim()));
  const expected=Math.min(Number(target||120),valid.size);
  if(existing.length===expected&&expected>0) return {rows:existing,target,available:valid.size};

  const selected=selectDaily_(Array.from(valid.values()),status,expected);
  const s=sheet_(EP.sheets.daily); if(s.getLastRow()>1) s.getRange(2,1,s.getLastRow()-1,Math.max(7,s.getLastColumn())).clearContent();
  if(selected.length){
    const rows=selected.map(x=>[x.q.id,x.priority,x.reason,today,'New',x.q.topic||'',x.q.conceptId||'']);
    s.getRange(2,1,rows.length,7).setValues(rows);
  }
  return {rows:table_(EP.sheets.daily).filter(r=>dateKey_(r.Quiz_Date)===today),target,available:valid.size};
}

function selectDaily_(questions,status,limit){
  const now=new Date(), buckets=[[],[],[],[],[]];
  questions.forEach(q=>{
    const st=status[q.id]||{}, ls=String(q.learningStatus||'').toLowerCase();
    if(st.nextReview&&new Date(st.nextReview)<=now) buckets[0].push({q,priority:100,reason:'Due Revision'});
    else if(['weak','wrong'].includes(String(st.status||'').toLowerCase())||Number(st.wrong||0)>0) buckets[1].push({q,priority:90,reason:'Weak / Wrong'});
    else if(st.marked||String(st.status||'').toLowerCase()==='marked') buckets[2].push({q,priority:80,reason:'Marked Review'});
    else if(!ls||ls==='new') buckets[3].push({q,priority:60,reason:'New Learning'});
    else buckets[4].push({q,priority:40,reason:'Mixed Revision'});
  });
  buckets.forEach(shuffle_); const out=[], seen=new Set();
  buckets.flat().forEach(x=>{if(out.length<limit&&!seen.has(x.q.id)){seen.add(x.q.id);out.push(x);}}); return out;
}

function markDaily_(id){const s=sheet_(EP.sheets.daily), last=s.getLastRow();if(last<2)return;const vals=s.getRange(2,1,last-1,5).getValues(),today=todayKey_();for(let i=0;i<vals.length;i++){if(String(vals[i][0])===String(id)&&dateKey_(vals[i][3])===today){s.getRange(i+2,5).setValue('Completed');break;}}}
function setQuestionLearningStatus_(id,status){const s=sheet_(EP.sheets.questions),row=findRow_(s,1,id);if(row>1){s.getRange(row,18).setValue(status);clearQuestionCache_();}}
function findRow_(s,col,id){if(s.getLastRow()<1)return-1;const cell=s.getRange(1,col,s.getLastRow(),1).createTextFinder(String(id)).matchEntireCell(true).findNext();return cell?cell.getRow():-1;}
function findQuestion_(id){return allQuestions_().find(q=>q.id===String(id))||null;}
function sourceKey_(q){if(q.sourceId)return'ID::'+q.sourceId;if(q.sourceFile)return'FILE::'+q.sourceFile;return'';}
function isActive_(q){return String(q.active||'').toLowerCase()!=='false';}

function clearQuestionCache_(){const cache=CacheService.getScriptCache(),meta=Number(cache.get(EP.cache.questionsMeta)||0);for(let i=0;i<meta;i++)cache.remove(EP.cache.questionsPrefix+i);cache.remove(EP.cache.questionsMeta);}
function clearStatusCache_(){CacheService.getScriptCache().remove(EP.cache.status);}
function allQuestions_(){
  const cache=CacheService.getScriptCache(),meta=cache.get(EP.cache.questionsMeta);
  if(meta){const n=Number(meta),parts=[];let ok=true;for(let i=0;i<n;i++){const p=cache.get(EP.cache.questionsPrefix+i);if(p==null){ok=false;break;}parts.push(p);}if(ok){try{return JSON.parse(parts.join(''));}catch(e){}}}
  const rows=allQuestionsRaw_(),txt=JSON.stringify(rows),chunkSize=50000,chunks=[];for(let i=0;i<txt.length;i+=chunkSize)chunks.push(txt.slice(i,i+chunkSize));chunks.forEach((c,i)=>cache.put(EP.cache.questionsPrefix+i,c,600));cache.put(EP.cache.questionsMeta,String(chunks.length),600);return rows;
}
function allQuestionsRaw_(){const s=sheet_(EP.sheets.questions),last=s.getLastRow();if(last<2)return[];return s.getRange(2,1,last-1,32).getValues().filter(r=>String(r[0]||'').trim()).map(questionFromRow_);}
function questionFromRow_(r){return{id:String(r[0]),topic:r[1],word:r[2],question:r[3],options:{A:r[4],B:r[5],C:r[6],D:r[7]},correct:r[8],explanation:r[9],subtopic:r[10],questionType:r[11],sourceFile:r[12],sourcePage:r[13],conceptId:r[14],difficulty:r[15],sourceId:r[16],learningStatus:r[17],contentStatus:r[18],tip:r[24],usageNote:r[25],example:r[26],memoryAid:r[27],related:r[28],sourceUrl:r[29],active:r[31]};}
function serveQuestion_(q){const entries=['A','B','C','D'].map(k=>({key:k,text:String(q.options[k]||'')}));if(shuffleSafe_(q,entries))shuffle_(entries);return{id:q.id,category:canonicalCategory_(q.topic),topic:q.topic,word:q.word,question:q.question,options:entries,correctKey:String(q.correct||'').toUpperCase(),explanation:q.explanation,tip:q.tip,usageNote:q.usageNote,example:q.example,memoryAid:q.memoryAid,related:q.related,source:q.sourceFile,sourcePage:q.sourcePage};}
function shuffleSafe_(q,entries){const type=String(q.questionType||'').toLowerCase();if(/order|sequence|match|arrange|para/.test(type))return false;return!entries.some(o=>/all of the above|none of the above|both [a-d]|either [a-d]/i.test(o.text));}
function shuffle_(a){for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];}return a;}
function canonicalCategory_(topic){const t=String(topic||'').toLowerCase();if(t.includes('spelling'))return'SPELLING';if(t.includes('idiom'))return'IDIOM';if(t.includes('phrasal'))return'PHRASAL';if(t.includes('one word')||t.includes('field of study')||t.includes('fields of study'))return'OWS';if(t.includes('synonym')||t.includes('antonym'))return'SYN_ANT';if(t.includes('confus'))return'CONFUSED';if(t.includes('sentence improvement'))return'SENT_IMP';if(t.includes('fill in'))return'FILL';if(t.includes('cloze'))return'CLOZE';if(t.includes('para'))return'PARA';if(t.includes('reading comprehension'))return'RC';if(t.includes('error'))return'ERROR';if(t.includes('grammar'))return'GRAMMAR';if(t.includes('vocab'))return'VOC';return'MISC';}
function statusMap_(){const cache=CacheService.getScriptCache(),hit=cache.get(EP.cache.status);if(hit){try{return JSON.parse(hit)}catch(e){}}const out={};table_(EP.sheets.status).forEach(r=>out[String(r.Question_ID||'').trim()]={status:r.Status,attempts:Number(r.Attempts||0),wrong:Number(r.Wrong||0),nextReview:r.Next_Review,mastered:truthy_(r.Mastered),marked:truthy_(r.Marked_Review),lastAttempt:r.Last_Attempt});try{cache.put(EP.cache.status,JSON.stringify(out),30)}catch(e){}return out;}
function recallIds_(status){const ids=new Set(Object.keys(status||{}).filter(id=>Number(status[id].attempts||0)>0));table_(EP.sheets.recall).filter(r=>truthy_(r.Active)).forEach(r=>{const id=String(r.Existing_Question_ID||'').trim();if(id)ids.add(id);});return ids;}
function config_(){return table_(EP.sheets.config).reduce((a,r)=>(a[String(r.Key||'').trim()]=r.Value,a),{});}
function table_(name){const s=sheet_(name),lr=s.getLastRow(),lc=s.getLastColumn();if(lr<2)return[];const v=s.getRange(1,1,lr,lc).getValues(),h=v.shift().map(String);return v.map(r=>{const o={};h.forEach((k,i)=>{if(k)o[k]=r[i]});return o;});}
function truthy_(v){return v===true||String(v||'').toLowerCase()==='true';}
function dateKey_(v){if(!v)return'';if(typeof v==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(v))return v;const d=v instanceof Date?v:new Date(v);return isNaN(d)?'':Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd');}
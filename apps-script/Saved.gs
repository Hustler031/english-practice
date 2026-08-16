const MY_WORDS_SHEET='My_Words';
const MY_WORDS_HEADERS=['Saved_ID','Word','Meaning','Context','Origin_Question_ID','Origin_Module','Source','Created_At','Updated_At','Status','Practice_Question_ID','Active'];

function myWordsSheet_(){
  let s=ss_().getSheetByName(MY_WORDS_SHEET);
  if(!s){s=ss_().insertSheet(MY_WORDS_SHEET);s.getRange(1,1,1,MY_WORDS_HEADERS.length).setValues([MY_WORDS_HEADERS]);s.setFrozenRows(1);}
  return s;
}

function myWordsRows_(){
  const s=myWordsSheet_();if(s.getLastRow()<2)return [];
  const vals=s.getRange(1,1,s.getLastRow(),MY_WORDS_HEADERS.length).getValues(),h=vals[0];
  return vals.slice(1).map((r,i)=>{const o={_row:i+2};h.forEach((k,j)=>o[k]=r[j]);return o;});
}

function captureMyWord(payload){
  payload=payload||{};const word=String(payload.word||'').trim();if(!word)throw new Error('Enter a word first.');
  const meaning=String(payload.meaning||'').trim(),context=String(payload.context||'').trim(),qid=String(payload.questionId||'').trim(),module=String(payload.module||'').trim(),source=String(payload.source||'').trim(),now=new Date(),norm=word.toLocaleLowerCase();
  const s=myWordsSheet_(),existing=myWordsRows_().find(x=>truthy_(x.Active)&&String(x.Word||'').trim().toLocaleLowerCase()===norm);
  if(existing){
    const oldMeaning=String(existing.Meaning||'').trim(),oldContext=String(existing.Context||'').trim();
    s.getRange(existing._row,2,1,8).setValues([[word,meaning||oldMeaning,context||oldContext,qid||existing.Origin_Question_ID,module||existing.Origin_Module,source||existing.Source,existing.Created_At||now,now]]);
    return {ok:true,id:existing.Saved_ID,duplicate:true,status:String(existing.Status||'Saved')};
  }
  const id='MW_'+Utilities.formatDate(now,Session.getScriptTimeZone(),'yyyyMMdd_HHmmss')+'_'+Math.random().toString(36).slice(2,6).toUpperCase();
  s.appendRow([id,word,meaning,context,qid,module,source,now,now,'Saved','',true]);
  return {ok:true,id,duplicate:false,status:'Saved'};
}

function updateMyWord(payload){
  payload=payload||{};const id=String(payload.id||'').trim(),s=myWordsSheet_(),row=findRow_(s,1,id);if(row<2)throw new Error('Saved word not found.');
  const word=String(payload.word||'').trim(),meaning=String(payload.meaning||'').trim(),context=String(payload.context||'').trim();if(!word)throw new Error('Word cannot be blank.');
  s.getRange(row,2,1,3).setValues([[word,meaning,context]]);s.getRange(row,9).setValue(new Date());
  return {ok:true,id};
}

function getMyWords(){
  return myWordsRows_().filter(x=>truthy_(x.Active)).sort((a,b)=>new Date(b.Created_At||0)-new Date(a.Created_At||0)).map(x=>({
    id:String(x.Saved_ID||''),word:String(x.Word||''),meaning:String(x.Meaning||''),context:String(x.Context||''),questionId:String(x.Origin_Question_ID||''),module:String(x.Origin_Module||''),source:String(x.Source||''),status:String(x.Status||'Saved'),practiceQuestionId:String(x.Practice_Question_ID||''),created:x.Created_At instanceof Date?Utilities.formatDate(x.Created_At,Session.getScriptTimeZone(),'yyyy-MM-dd'):String(x.Created_At||'')
  }));
}

function getMySavedHub(){
  const status=statusMap_(),all=allQuestions_();
  const starred=all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&isStarredStatus_(status[q.id]||{}));
  const weak=starred.filter(q=>isWeakStatus_(status[q.id]||{})).length,words=getMyWords();
  return {starred:starred.length,starredWeak:weak,words:words.length,wordsAdded:words.filter(x=>x.practiceQuestionId||String(x.status).toLowerCase()==='added').length};
}

function getStarredPracticeBatch(kind,count){
  const status=statusMap_(),mode=String(kind||'all').toLowerCase();
  let pool=allQuestions_().filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&isStarredStatus_(status[q.id]||{}));
  if(mode==='weak')pool=pool.filter(q=>isWeakStatus_(status[q.id]||{}));
  if(mode==='random'||mode==='weak')shuffle_(pool);
  const requested=Math.max(1,Math.min(100,Number(count||10)));
  if(mode==='random')pool=pool.slice(0,requested);
  return pool.map(serveQuestion_);
}

function isStarredStatus_(st){return !!st.marked||String(st.status||'').toLowerCase()==='marked'||Number(st.markedCount||0)>0;}
function isWeakStatus_(st){return ['weak','wrong'].includes(String(st.status||'').toLowerCase())||Number(st.wrong||0)>0;}

function getMySavedWordQuestionIds(){
  return getMyWords().map(x=>x.practiceQuestionId).filter(Boolean);
}

function promoteMyWordToPractice(savedId){
  const id=String(savedId||'').trim(),s=myWordsSheet_(),row=findRow_(s,1,id);if(row<2)throw new Error('Saved word not found.');
  const r=s.getRange(row,1,1,MY_WORDS_HEADERS.length).getValues()[0],word=String(r[1]||'').trim(),meaning=String(r[2]||'').trim(),context=String(r[3]||'').trim();
  if(!word)throw new Error('Word cannot be blank.');if(!meaning)throw new Error('Add a meaning/explanation before adding this word to practice.');
  const existing=allQuestions_().find(q=>isActive_(q)&&canonicalCategory_(q.topic)==='VOC'&&String(q.word||'').trim().toLocaleLowerCase()===word.toLocaleLowerCase());
  if(existing){s.getRange(row,9,1,3).setValues([[new Date(),'Added',existing.id]]);return {ok:true,questionId:existing.id,linked:true};}

  const raw=table_(EP.sheets.questions),distractors=[];
  raw.forEach(q=>{
    if(canonicalCategory_(q.Topic)!=='VOC')return;
    const key=String(q.Correct||'').trim().toUpperCase(),m=String(q['Option_'+key]||'').trim();
    if(m&&m.toLocaleLowerCase()!==meaning.toLocaleLowerCase()&&!distractors.some(x=>x.toLocaleLowerCase()===m.toLocaleLowerCase()))distractors.push(m);
  });
  myWordsRows_().forEach(x=>{const m=String(x.Meaning||'').trim();if(m&&m.toLocaleLowerCase()!==meaning.toLocaleLowerCase()&&!distractors.some(y=>y.toLocaleLowerCase()===m.toLocaleLowerCase()))distractors.push(m);});
  shuffle_(distractors);while(distractors.length<3)distractors.push(['A different unrelated meaning','An opposite or unrelated idea','None of these meanings'][distractors.length]||'Another unrelated meaning');
  const opts=shuffle_([{correct:true,text:meaning},...distractors.slice(0,3).map(x=>({correct:false,text:x}))]),letters=['A','B','C','D'],correct=letters[opts.findIndex(x=>x.correct)];
  const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.MD5,word.toLocaleLowerCase()).slice(0,5).map(x=>(x<0?x+256:x).toString(16).padStart(2,'0')).join('').toUpperCase();
  const qid='MYWORD_'+Utilities.formatDate(new Date(),Session.getScriptTimeZone(),'yyyyMMdd')+'_'+digest;
  const values={Question_ID:qid,Topic:'Vocabulary',Word:word,Question:'Choose the closest meaning of '+word+'.',Option_A:opts[0].text,Option_B:opts[1].text,Option_C:opts[2].text,Option_D:opts[3].text,Correct:correct,Explanation:meaning+(context?' Context: '+context:''),Subtopic:'My Saved Words',Question_Type:'Meaning',Source_File:'My Saved Words',Source_Page:'',Concept_ID:'MYWORD_'+digest,Difficulty:'Medium',Source_ID:'MY_SAVED_WORDS',Learning_Status:'New',Content_Status:'Active',First_Seen_Date:'',Last_Seen_Date:'',Seen_Count:0,Duplicate_Group_ID:'',Exam_Relevance:'User-saved vocabulary',Tip:'Captured during practice for deliberate revision.',Usage_Note:context};
  const qs=sheet_(EP.sheets.questions),headers=qs.getRange(1,1,1,qs.getLastColumn()).getValues()[0].map(String),out=headers.map(h=>Object.prototype.hasOwnProperty.call(values,h)?values[h]:'');
  qs.appendRow(out);SpreadsheetApp.flush();
  try{CacheService.getScriptCache().remove(EP.cache.questionsMeta);}catch(e){}
  s.getRange(row,9,1,3).setValues([[new Date(),'Added',qid]]);
  return {ok:true,questionId:qid,linked:false};
}

const MYWORD_RECONCILE_GATE='EP_MYWORD_RECONCILE_GATE_V2';
const MYWORD_RECONCILE_SECONDS=45;
const MYWORD_RECONCILE_TRIGGER_PROP='EP_MYWORD_RECONCILE_TRIGGER_V1';
const MYWORD_RECONCILE_TRIGGER_FN='reconcileReadyMyWordsTrigger_';

function ensureMyWordReconcileTrigger_(){
  const props=PropertiesService.getScriptProperties();
  if(props.getProperty(MYWORD_RECONCILE_TRIGGER_PROP)==='1')return true;
  try{
    const exists=ScriptApp.getProjectTriggers().some(t=>t.getHandlerFunction()===MYWORD_RECONCILE_TRIGGER_FN);
    if(!exists)ScriptApp.newTrigger(MYWORD_RECONCILE_TRIGGER_FN).timeBased().everyMinutes(1).create();
    props.setProperty(MYWORD_RECONCILE_TRIGGER_PROP,'1');
    return true;
  }catch(e){return false}
}

function hasReadyMyWordsNeedingPromotion_(){
  const s=myWordsSheet_(),last=s.getLastRow();if(last<2)return false;
  const width=s.getLastColumn(),h=s.getRange(1,1,1,width).getValues()[0].map(x=>String(x||'').trim()),iActive=h.indexOf('Active'),iGPT=h.indexOf('GPT_Status'),iMeaning=h.indexOf('Meaning'),iQid=h.indexOf('Practice_Question_ID');
  if([iActive,iGPT,iMeaning,iQid].some(i=>i<0))return false;
  const maxI=Math.max(iActive,iGPT,iMeaning,iQid),vals=s.getRange(2,1,last-1,maxI+1).getValues();
  return vals.some(r=>truthy_(r[iActive])&&String(r[iGPT]||'').trim().toLowerCase()==='ready'&&String(r[iMeaning]||'').trim()&&!String(r[iQid]||'').trim());
}

function reconcileReadyMyWordsTrigger_(){
  try{
    if(!hasReadyMyWordsNeedingPromotion_())return{ok:true,skipped:true,reason:'no-ready-backlog'};
    return reconcileReadyMyWordsFast_(true);
  }catch(e){return{ok:false,error:String(e&&e.message||e)}}
}

function inferMyWordTypeForReconcile_(row,explicit){
  if(explicit)return normalizeMyWordType_(explicit);
  const pos=String(row.Part_of_Speech||'').toLowerCase();
  if(/phrasal\s+verb/.test(pos))return'PV';
  if(/idiom/.test(pos))return'IP';
  if(/one[- ]word\s+substitution|\bows\b/.test(pos))return'OWS';
  if(/spelling|misspell/.test(pos))return'SM';
  return'V';
}

function myWordReconcileQuestionId_(row,type,used){
  const created=row.Created_At instanceof Date?row.Created_At:new Date(row.Created_At||Date.now()),date=isNaN(created)?new Date():created;
  const seed=String(row.Saved_ID||'')+'|'+String(row.Word||'').toLocaleLowerCase()+'|'+String(type||'V');
  const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.MD5,seed).slice(0,5).map(x=>(x<0?x+256:x).toString(16).padStart(2,'0')).join('').toUpperCase();
  const base='MYWORD_'+Utilities.formatDate(date,Session.getScriptTimeZone(),'yyyyMMdd')+'_'+digest;
  let id=base,n=2;while(used.has(id))id=base+'_'+n++;
  used.add(id);return id;
}

function myWordQuestionValues_(row,type,qid){
  const spec=myWordPracticeSpec_(type),word=String(row.Word||'').trim(),meaning=String(row.Meaning||'').trim();
  const opts=['A','B','C','D'].map(k=>String(row['Option_'+k]||'').trim()),correct=String(row.Correct_Option||'').trim().toUpperCase();
  if(!word||!meaning||!['A','B','C','D'].includes(correct)||opts.some(x=>!x))return null;
  const digest=qid.replace(/^MYWORD_\d{8}_/,'').replace(/_\d+$/,'');
  const explanation=String(row.Explanation||'').trim()||[meaning,String(row.Part_of_Speech||'').trim()?('Part of speech: '+row.Part_of_Speech):'',String(row.Synonyms||'').trim()?('Synonyms: '+row.Synonyms):'',String(row.Antonyms||'').trim()?('Antonyms: '+row.Antonyms):'',String(row.Example||'').trim()?('Example: '+row.Example):''].filter(Boolean).join('\n');
  return {Question_ID:qid,Topic:spec.topic,Word:word,Question:String(row.Question||'').trim()||('Choose the closest meaning of '+word+'.'),Option_A:opts[0],Option_B:opts[1],Option_C:opts[2],Option_D:opts[3],Correct:correct,Explanation:explanation,Subtopic:'My Saved Words',Question_Type:spec.questionType,Source_File:'My Saved Words',Source_Page:'',Concept_ID:'MYWORD_'+digest,Difficulty:'Medium',Source_ID:'MY_SAVED_WORDS',Learning_Status:'New',Content_Status:'Active',First_Seen_Date:'',Last_Seen_Date:'',Seen_Count:0,Duplicate_Group_ID:'',Exam_Relevance:'User-saved '+MY_WORD_TYPE_LABELS[type],Tip:String(row.Synonyms||'').trim()?('Recall with: '+row.Synonyms):'Captured during practice for deliberate revision.',Usage_Note:String(row.Example||row.Context||'')};
}

function reconcileReadyMyWordsFast_(force){
  ensureMyWordReconcileTrigger_();
  const cache=CacheService.getScriptCache();
  if(!force&&cache.get(MYWORD_RECONCILE_GATE))return{ok:true,skipped:true};
  const lock=LockService.getScriptLock();if(!lock.tryLock(120))return{ok:true,busy:true};
  try{
    if(!force&&cache.get(MYWORD_RECONCILE_GATE))return{ok:true,skipped:true};
    const s=myWordsSheet_(),last=s.getLastRow();if(last<2){cache.put(MYWORD_RECONCILE_GATE,'1',MYWORD_RECONCILE_SECONDS);return{ok:true,checked:0,promoted:0,relinked:0,remaining:0}}
    const lc=s.getLastColumn(),vals=s.getRange(1,1,last,lc).getValues(),headers=vals[0].map(x=>String(x||'').trim()),rows=vals.slice(1).map((r,i)=>{const o={_row:i+2};headers.forEach((k,j)=>{if(k)o[k]=r[j]});return o});
    const types=typeof getMyWordCaptureTypes==='function'?getMyWordCaptureTypes():{},all=allQuestionsRaw_(),byId=new Map(all.map(q=>[String(q.id),q])),used=new Set(byId.keys()),byCatWord=new Map();
    all.forEach(q=>{if(!isActive_(q))return;const key=canonicalCategory_(q.topic)+'|'+String(q.word||'').trim().toLocaleLowerCase();if(!byCatWord.has(key))byCatWord.set(key,q)});
    const candidates=[];
    rows.forEach(r=>{if(!truthy_(r.Active)||String(r.GPT_Status||'').trim().toLowerCase()!=='ready'||!String(r.Meaning||'').trim())return;const linked=String(r.Practice_Question_ID||'').trim();if(!linked||!byId.has(linked))candidates.push(r)});
    if(!candidates.length){cache.put(MYWORD_RECONCILE_GATE,'1',MYWORD_RECONCILE_SECONDS);return{ok:true,checked:rows.length,promoted:0,relinked:0,remaining:0}}
    const qs=sheet_(EP.sheets.questions),qh=qs.getRange(1,1,1,qs.getLastColumn()).getValues()[0].map(x=>String(x||'').trim()),append=[],updates=[],failures=[];let promoted=0,relinked=0;
    candidates.forEach(r=>{
      const explicit=types[String(r.Saved_ID||'')]||'',type=inferMyWordTypeForReconcile_(r,explicit),spec=myWordPracticeSpec_(type),key=canonicalCategory_(spec.topic)+'|'+String(r.Word||'').trim().toLocaleLowerCase(),existing=byCatWord.get(key);
      if(existing){updates.push({row:r._row,qid:existing.id});relinked++;return}
      const qid=myWordReconcileQuestionId_(r,type,used),obj=myWordQuestionValues_(r,type,qid);if(!obj){failures.push(String(r.Saved_ID||r.Word||r._row));return}
      append.push(qh.map(k=>Object.prototype.hasOwnProperty.call(obj,k)?obj[k]:''));updates.push({row:r._row,qid});const q={id:qid,topic:obj.Topic,word:obj.Word,active:true};byCatWord.set(key,q);byId.set(qid,q);promoted++;
    });
    if(append.length)qs.getRange(qs.getLastRow()+1,1,append.length,qh.length).setValues(append);
    if(updates.length){
      const cUpdated=myWordCol_(s,'Updated_At'),cStatus=myWordCol_(s,'Status'),cQid=myWordCol_(s,'Practice_Question_ID');
      if(cStatus===cUpdated+1&&cQid===cUpdated+2){const block=s.getRange(2,cUpdated,last-1,3),data=block.getValues(),now=new Date();updates.forEach(u=>{const i=u.row-2;data[i][0]=now;data[i][1]='Added';data[i][2]=u.qid});block.setValues(data)}
      else{const now=new Date();updates.forEach(u=>{s.getRange(u.row,cUpdated).setValue(now);s.getRange(u.row,cStatus).setValue('Added');s.getRange(u.row,cQid).setValue(u.qid)})}
    }
    if(append.length){SpreadsheetApp.flush();clearQuestionCache_()}
    cache.put(MYWORD_RECONCILE_GATE,'1',MYWORD_RECONCILE_SECONDS);
    return{ok:true,checked:rows.length,candidates:candidates.length,promoted,relinked,failed:failures.length,failures,remaining:failures.length};
  }finally{lock.releaseLock()}
}

function reconcileReadyMyWords(){return reconcileReadyMyWordsFast_(true)}

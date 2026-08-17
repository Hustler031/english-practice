function computeEncounterProgress_(){
  const all=allQuestions_().filter(q=>isActive_(q));
  const qMap=Object.fromEntries(all.map(q=>[q.id,q]));
  const facts=progressFacts_(qMap);
  const status=statusMap_();
  const names={};
  table_(EP.sheets.categories).forEach(r=>{const id=String(r.Category_ID||'').trim();if(id)names[id]=String(r.Category_Name||id)});

  const grouped={};
  all.forEach(q=>{
    const id=canonicalCategory_(q.topic),name=names[id]||progressCategoryName_(id,q.topic);
    if(!grouped[id])grouped[id]={id,name,ids:[]};
    grouped[id].ids.push(q.id);
  });
  const categories=Object.values(grouped).map(g=>Object.assign({id:g.id,name:g.name},progressMetric_(g.ids,facts))).filter(g=>g.total>0).sort((a,b)=>b.total-a.total||a.name.localeCompare(b.name));
  const overall=progressMetric_(all.map(q=>q.id),facts);

  const safePool=fn=>{try{return typeof fn==='function'?(fn()||[]):[]}catch(e){return[]}};
  const newPool=safePool(()=>newPracticePool_('ALL'));
  const demandPool=safePool(()=>demandQuestionPool_('__ALL__').map(x=>x.q));
  const sourcePool=all.filter(q=>{try{return !!sourceKey_(q)}catch(e){return false}});
  const hinduPool=safePool(()=>{
    const today=todayKey_();
    return table_(EP.sheets.hindu).filter(r=>truthy_(r.Active)&&dateKey_(r.Date)===today).map(r=>qMap[resolveHinduQuestionId_(String(r.Hindu_ID||'').trim())]).filter(Boolean);
  });
  const savedPool=all.filter(q=>facts.marked.has(q.id));

  const modules={
    practice:progressMetric_(all.map(q=>q.id),facts),
    new:progressMetric_(newPool.map(q=>q.id),facts),
    demanded:progressMetric_(demandPool.map(q=>q.id),facts),
    hindu:progressMetric_(hinduPool.map(q=>q.id),facts),
    sources:progressMetric_(sourcePool.map(q=>q.id),facts),
    saved:progressMetric_(savedPool.map(q=>q.id),facts)
  };

  const today=todayKey_();
  const masteredCount=Object.keys(status).filter(id=>status[id]&&status[id].mastered).length;
  const overview={encountered:overall.encountered,total:overall.total,todayNew:facts.todayNew.size,starred:facts.marked.size,mastered:masteredCount};
  return Object.assign({date:today,todayActivity:facts.todaySeen.size,todayNew:facts.todayNew.size,starredCount:facts.marked.size,masteredCount,categories,modules,overview},overall);
}

function progressFacts_(qMap){
  const firstSeen={},attemptState={},seen=new Set(),todaySeen=new Set(),todayNew=new Set(),marked=currentMarkedIds_();
  const perf=sheet_(EP.sheets.performance);
  if(perf.getLastRow()>1){
    const values=perf.getDataRange().getValues(),header=values[0].map(x=>String(x||'').trim().toLowerCase());
    let ti=header.findIndex(x=>x==='timestamp'||x==='time'||x==='attempt_time'||x==='attempt timestamp');
    let qi=header.findIndex(x=>x==='question_id'||x==='question id'||x==='questionid');
    let ci=header.findIndex(x=>x==='is_correct'||x==='correct'||x==='iscorrect');
    if(ti<0)ti=0;if(qi<0)qi=1;if(ci<0)ci=3;
    const today=todayKey_();
    values.slice(1).forEach(r=>{
      const id=String(r[qi]||'').trim();if(!id||!qMap[id])return;
      const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;
      const ok=truthy_(r[ci]);seen.add(id);
      if(!firstSeen[id]||d<firstSeen[id])firstSeen[id]=d;
      if(Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd')===today)todaySeen.add(id);
      if(!attemptState[id])attemptState[id]={firstCorrect:ok,streak:0,lastCorrect:false};
      const a=attemptState[id];a.lastCorrect=ok;a.streak=ok?a.streak+1:0;
    });
  }
  const qualified=new Set(),confident=new Set();
  Object.keys(attemptState).forEach(id=>{
    const a=attemptState[id];
    if(a.lastCorrect&&(a.firstCorrect||a.streak>=3)){
      qualified.add(id);
      if(!marked.has(id))confident.add(id);
    }
  });
  const today=todayKey_();
  Object.keys(firstSeen).forEach(id=>{if(Utilities.formatDate(firstSeen[id],Session.getScriptTimeZone(),'yyyy-MM-dd')===today)todayNew.add(id)});
  return {seen,qualified,confident,marked,todaySeen,todayNew};
}

function currentMarkedIds_(){
  const out=new Set(),s=sheet_(EP.sheets.status);if(s.getLastRow()<2)return out;
  const vals=s.getDataRange().getValues(),h=vals[0].map(x=>String(x||'').trim().toLowerCase());
  let qi=h.findIndex(x=>x==='question_id'||x==='question id'||x==='questionid'),mi=h.findIndex(x=>x==='last_marked'||x==='marked'||x==='is_marked');
  if(qi<0)qi=0;if(mi<0)mi=10;
  vals.slice(1).forEach(r=>{const id=String(r[qi]||'').trim();if(id&&truthy_(r[mi]))out.add(id)});
  return out;
}

function progressMetric_(ids,facts){
  const unique=[...new Set((ids||[]).map(x=>String(x||'').trim()).filter(Boolean))],total=unique.length;
  let encountered=0,correct=0,confident=0;
  unique.forEach(id=>{if(facts.seen.has(id))encountered++;if(facts.qualified.has(id))correct++;if(facts.confident.has(id))confident++});
  const doubt=Math.max(0,correct-confident);
  return {total,encountered,left:Math.max(0,total-encountered),percent:roundPct_(encountered,total),correct,correctPercent:roundPct_(correct,encountered),confident,confidentPercent:roundPct_(confident,encountered),doubt,doubtPercent:roundPct_(doubt,encountered)};
}

function roundPct_(n,d){return d?Math.round(Number(n||0)*1000/Number(d))/10:0;}

function progressCategoryName_(id,topic){
  const names={VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution / Fields of Study',SYN_ANT:'Synonyms & Antonyms',CONFUSED:'Confused Words',SPELLING:'Spelling',GRAMMAR:'Grammar',ERROR:'Error Detection',SENT_IMP:'Sentence Improvement',FILL:'Fill in the Blanks',CLOZE:'Cloze Test',PARA:'Para Jumbles',RC:'Reading Comprehension',MISC:'Other'};
  return names[id]||String(topic||id||'Other');
}

const EP_PROGRESS_SNAPSHOT_KEY='EP_PROGRESS_SNAPSHOT_V1';
const EP_PROGRESS_TRIGGER_READY_KEY='EP_PROGRESS_TRIGGER_READY_V1';
const EP_PROGRESS_SEED_READY_KEY='EP_PROGRESS_SEED_READY_V1';

function getEncounterProgress(){return getProgressSnapshotServer();}

function refreshProgressSnapshot(){
  const lock=LockService.getScriptLock();
  lock.waitLock(20000);
  try{
    const p=computeEncounterProgress_();
    p.snapshotGeneratedAt=new Date().toISOString();
    const props=PropertiesService.getScriptProperties();
    props.setProperty(EP_PROGRESS_SNAPSHOT_KEY,JSON.stringify(p));
    props.deleteProperty(EP_PROGRESS_SEED_READY_KEY);
    return p;
  }finally{
    lock.releaseLock();
  }
}

function getProgressSnapshotServer(){
  ensureProgressSnapshotTrigger_();
  const props=PropertiesService.getScriptProperties();
  const raw=props.getProperty(EP_PROGRESS_SNAPSHOT_KEY);
  if(raw){
    try{return JSON.parse(raw)}catch(e){props.deleteProperty(EP_PROGRESS_SNAPSHOT_KEY)}
  }
  ensureProgressSnapshotSeed_();
  return {pending:true,snapshotGeneratedAt:null};
}

function ensureProgressSnapshotSeed_(){
  const props=PropertiesService.getScriptProperties();
  if(props.getProperty(EP_PROGRESS_SEED_READY_KEY)==='1')return;
  ScriptApp.newTrigger('refreshProgressSnapshot').timeBased().after(1000).create();
  props.setProperty(EP_PROGRESS_SEED_READY_KEY,'1');
}

function ensureProgressSnapshotTrigger_(){
  const props=PropertiesService.getScriptProperties();
  if(props.getProperty(EP_PROGRESS_TRIGGER_READY_KEY)==='1')return;
  const exists=ScriptApp.getProjectTriggers().some(t=>t.getHandlerFunction()==='refreshProgressSnapshot');
  if(!exists)ScriptApp.newTrigger('refreshProgressSnapshot').timeBased().everyHours(1).create();
  props.setProperty(EP_PROGRESS_TRIGGER_READY_KEY,'1');
}

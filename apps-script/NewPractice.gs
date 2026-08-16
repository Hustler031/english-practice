function newPracticeWeak_(st){return ['weak','wrong'].includes(String(st&&st.status||'').toLowerCase())||Number(st&&st.wrong||0)>0;}

function newPracticePool_(wanted){
  const all=allQuestions_(),status=statusMap_(),key=String(wanted||'ALL').trim()||'ALL',days=Number(config_().NEW_CONTENT_DAYS||7),now=new Date(),cutoff=new Date(now);cutoff.setDate(cutoff.getDate()-Math.max(0,days-1));cutoff.setHours(0,0,0,0);
  const hinduIds=new Set(typeof getSavedHinduQuestionIds==='function'?getSavedHinduQuestionIds():[]),myIds=new Set(typeof getMySavedWordQuestionIds==='function'?getMySavedWordQuestionIds():[]),out=[],seen=new Set();
  all.forEach(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;
    const rawCat=canonicalCategory_(q.topic),cat=rawCat==='MISC'?'NOT_SPECIFIED':rawCat,added=recentContentDate_(q),recent=!!added&&added>=cutoff,inHindu=hinduIds.has(q.id),inMine=myIds.has(q.id);
    let include=false;
    if(key==='ALL')include=recent||inHindu||inMine;
    else if(key==='HINDU_WORDS')include=inHindu;
    else if(key==='MY_SAVED_WORDS')include=inMine;
    else include=recent&&cat===key;
    if(include&&!seen.has(q.id)){seen.add(q.id);out.push(q)}
  });
  return out;
}

function getNewPracticeHub(){
  const all=allQuestions_(),status=statusMap_(),days=Number(config_().NEW_CONTENT_DAYS||7),now=new Date(),cutoff=new Date(now);cutoff.setDate(cutoff.getDate()-Math.max(0,days-1));cutoff.setHours(0,0,0,0),grouped={};
  all.forEach(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;
    const added=recentContentDate_(q);if(!added||added<cutoff)return;
    const rawCat=canonicalCategory_(q.topic),id=rawCat==='MISC'?'NOT_SPECIFIED':rawCat,name=newPracticeCategoryName_(id,q.topic);
    if(!grouped[id])grouped[id]={id,name,total:0,weak:0,latest:''};
    const g=grouped[id],st=status[q.id]||{};g.total++;if(newPracticeWeak_(st))g.weak++;
    const dk=Utilities.formatDate(added,Session.getScriptTimeZone(),'yyyy-MM-dd');if(!g.latest||dk>g.latest)g.latest=dk;
  });
  const savedIds=new Set(typeof getSavedHinduQuestionIds==='function'?getSavedHinduQuestionIds():[]),saved=all.filter(q=>savedIds.has(q.id)&&isActive_(q)&&!(status[q.id]&&status[q.id].mastered));
  if(saved.length)grouped.HINDU_WORDS={id:'HINDU_WORDS',name:'Hindu Words',total:saved.length,weak:saved.filter(q=>newPracticeWeak_(status[q.id]||{})).length,latest:'9999-12-31'};
  const mySavedIds=new Set(typeof getMySavedWordQuestionIds==='function'?getMySavedWordQuestionIds():[]),mySaved=all.filter(q=>mySavedIds.has(q.id)&&isActive_(q)&&!(status[q.id]&&status[q.id].mastered));
  if(mySaved.length)grouped.MY_SAVED_WORDS={id:'MY_SAVED_WORDS',name:'My Saved Words',total:mySaved.length,weak:mySaved.filter(q=>newPracticeWeak_(status[q.id]||{})).length,latest:'9999-12-30'};
  const categories=Object.values(grouped).sort((a,b)=>b.latest.localeCompare(a.latest)||a.name.localeCompare(b.name)),allPool=newPracticePool_('ALL');
  return {days,categories,total:allPool.length,weak:allPool.filter(q=>newPracticeWeak_(status[q.id]||{})).length};
}

function getNewPracticeItems(category){
  const status=statusMap_();return newPracticePool_(category||'ALL').map(q=>({id:q.id,word:q.word||'',question:q.question||'',category:canonicalCategory_(q.topic),topic:q.topic||'',subtopic:q.subtopic||'',weak:newPracticeWeak_(status[q.id]||{}),attempts:Number((status[q.id]||{}).attempts||0),source:q.sourceFile||q.sourceId||'',added:(()=>{const d=recentContentDate_(q);return d?Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd'):''})()}));
}

function getNewPracticeBatch(category,kind,count){
  const status=statusMap_(),mode=String(kind||'all').toLowerCase();let pool=newPracticePool_(category||'ALL');
  if(mode==='weak')pool=pool.filter(q=>newPracticeWeak_(status[q.id]||{}));
  const requested=Math.max(1,Math.min(100,Number(count||10)));
  if(mode==='random'){
    const now=Date.now(),buckets=[[],[],[],[],[]];
    pool.forEach(q=>{const st=status[q.id]||{},added=recentContentDate_(q),days=added?(now-added.getTime())/86400000:999;if(newPracticeWeak_(st))buckets[0].push(q);else if(days<=7)buckets[1].push(q);else if(st.marked||String(st.status||'').toLowerCase()==='marked')buckets[2].push(q);else if(Number(st.attempts||0)>0)buckets[3].push(q);else buckets[4].push(q)});buckets.forEach(shuffle_);pool=buckets.flat().slice(0,requested);
  }else if(mode==='weak'){shuffle_(pool);if(Number(count||0)>0)pool=pool.slice(0,requested)}
  else if(Number(count||0)>0)pool=pool.slice(0,Math.min(120,Number(count)));
  return pool.map(serveQuestion_);
}

function recentContentDate_(q){
  const candidates=[q.id,q.sourceId,q.sourceFile];
  for(let i=0;i<candidates.length;i++){
    const s=String(candidates[i]||'');
    let m=s.match(/(?:^|[^0-9])(20\d{2})(\d{2})(\d{2})(?:[^0-9]|$)/);
    if(m){const d=new Date(Number(m[1]),Number(m[2])-1,Number(m[3]));if(!isNaN(d))return d;}
    m=s.match(/(?:^|[^0-9])(20\d{2})[-_](\d{2})[-_](\d{2})(?:[^0-9]|$)/);
    if(m){const d=new Date(Number(m[1]),Number(m[2])-1,Number(m[3]));if(!isNaN(d))return d;}
  }
  return null;
}

function newPracticeCategoryName_(id,topic){
  const names={VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution / Fields of Study',SYN_ANT:'Synonyms & Antonyms',CONFUSED:'Confused Words',SPELLING:'Spelling',GRAMMAR:'Grammar',ERROR:'Error Detection',SENT_IMP:'Sentence Improvement',FILL:'Fill in the Blanks',CLOZE:'Cloze Test',PARA:'Para Jumbles',RC:'Reading Comprehension',HINDU_WORDS:'Hindu Words',MY_SAVED_WORDS:'My Saved Words',NOT_SPECIFIED:'Not Specified / Other'};
  return names[id]||String(topic||'Not Specified / Other');
}

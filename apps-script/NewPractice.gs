function getNewPracticeHub(){
  const all=allQuestions_(), status=statusMap_(), days=Number(config_().NEW_CONTENT_DAYS||7), now=new Date();
  const cutoff=new Date(now); cutoff.setDate(cutoff.getDate()-Math.max(0,days-1)); cutoff.setHours(0,0,0,0);
  const grouped={};
  all.forEach(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;
    const added=recentContentDate_(q); if(!added||added<cutoff)return;
    const rawCat=canonicalCategory_(q.topic), id=rawCat==='MISC'?'NOT_SPECIFIED':rawCat;
    const name=newPracticeCategoryName_(id,q.topic);
    if(!grouped[id])grouped[id]={id,name,total:0,weak:0,latest:''};
    grouped[id].total++;
    const st=status[q.id]||{};
    if(['weak','wrong'].includes(String(st.status||'').toLowerCase())||Number(st.wrong||0)>0)grouped[id].weak++;
    const dk=Utilities.formatDate(added,Session.getScriptTimeZone(),'yyyy-MM-dd');
    if(!grouped[id].latest||dk>grouped[id].latest)grouped[id].latest=dk;
  });
  const categories=Object.values(grouped).sort((a,b)=>b.latest.localeCompare(a.latest)||a.name.localeCompare(b.name));
  return {days,categories,total:categories.reduce((n,x)=>n+x.total,0)};
}

function getNewPracticeBatch(category,kind,count){
  const all=allQuestions_(), status=statusMap_(), days=Number(config_().NEW_CONTENT_DAYS||7), now=new Date();
  const cutoff=new Date(now); cutoff.setDate(cutoff.getDate()-Math.max(0,days-1)); cutoff.setHours(0,0,0,0);
  const wanted=String(category||'').trim(), mode=String(kind||'all').toLowerCase();
  let pool=all.filter(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return false;
    const added=recentContentDate_(q); if(!added||added<cutoff)return false;
    const rawCat=canonicalCategory_(q.topic), id=rawCat==='MISC'?'NOT_SPECIFIED':rawCat;
    if(wanted&&id!==wanted)return false;
    if(mode==='weak'){
      const st=status[q.id]||{};
      return ['weak','wrong'].includes(String(st.status||'').toLowerCase())||Number(st.wrong||0)>0;
    }
    return true;
  });
  if(mode==='random'||mode==='weak')shuffle_(pool);
  const requested=Number(count||0);
  if(mode==='random')pool=pool.slice(0,Math.max(1,Math.min(20,requested||10)));
  else if(requested>0)pool=pool.slice(0,Math.min(120,requested));
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
  const names={VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution / Fields of Study',SYN_ANT:'Synonyms & Antonyms',CONFUSED:'Confused Words',SPELLING:'Spelling',GRAMMAR:'Grammar',ERROR:'Error Detection',SENT_IMP:'Sentence Improvement',FILL:'Fill in the Blanks',CLOZE:'Cloze Test',PARA:'Para Jumbles',RC:'Reading Comprehension',NOT_SPECIFIED:'Not Specified / Other'};
  return names[id]||String(topic||'Not Specified / Other');
}

function getEncounterProgress(){
  const all=allQuestions_().filter(q=>isActive_(q));
  const qMap=Object.fromEntries(all.map(q=>[q.id,q]));
  const status=statusMap_(),firstSeen={},attemptState={},seen=new Set(),todaySeen=new Set();
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
    // First-encounter correct qualifies immediately. If first encounter was wrong,
    // the question qualifies only after a current streak of 3 consecutive correct answers.
    if(a.lastCorrect&&(a.firstCorrect||a.streak>=3)){
      qualified.add(id);
      const st=status[id]||{};
      if(!truthy_(st.marked))confident.add(id);
    }
  });
  const today=todayKey_(),todayNew=new Set();
  Object.keys(firstSeen).forEach(id=>{if(Utilities.formatDate(firstSeen[id],Session.getScriptTimeZone(),'yyyy-MM-dd')===today)todayNew.add(id)});
  const names={};
  table_(EP.sheets.categories).forEach(r=>{const id=String(r.Category_ID||'').trim();if(id)names[id]=String(r.Category_Name||id)});
  const grouped={};
  all.forEach(q=>{
    const id=canonicalCategory_(q.topic),name=names[id]||progressCategoryName_(id,q.topic);
    if(!grouped[id])grouped[id]={id,name,total:0,encountered:0,left:0,percent:0,correct:0,correctPercent:0,confident:0,confidentPercent:0,doubt:0,doubtPercent:0};
    const g=grouped[id];g.total++;
    if(seen.has(q.id)){g.encountered++;if(qualified.has(q.id))g.correct++;if(confident.has(q.id))g.confident++;}
  });
  Object.values(grouped).forEach(g=>{
    g.left=Math.max(0,g.total-g.encountered);g.percent=roundPct_(g.encountered,g.total);
    g.correctPercent=roundPct_(g.correct,g.encountered);g.confidentPercent=roundPct_(g.confident,g.encountered);
    g.doubt=Math.max(0,g.correct-g.confident);g.doubtPercent=roundPct_(g.doubt,g.encountered);
  });
  const categories=Object.values(grouped).filter(g=>g.total>0).sort((a,b)=>b.total-a.total||a.name.localeCompare(b.name));
  const total=all.length,encountered=seen.size,correct=qualified.size,confidentCount=confident.size,doubt=Math.max(0,correct-confidentCount);
  return {date:today,total,encountered,left:Math.max(0,total-encountered),percent:roundPct_(encountered,total),correct,correctPercent:roundPct_(correct,encountered),confident:confidentCount,confidentPercent:roundPct_(confidentCount,encountered),doubt,doubtPercent:roundPct_(doubt,encountered),todayActivity:todaySeen.size,todayNew:todayNew.size,categories};
}

function roundPct_(n,d){return d?Math.round(Number(n||0)*1000/Number(d))/10:0;}

function progressCategoryName_(id,topic){
  const names={VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution / Fields of Study',SYN_ANT:'Synonyms & Antonyms',CONFUSED:'Confused Words',SPELLING:'Spelling',GRAMMAR:'Grammar',ERROR:'Error Detection',SENT_IMP:'Sentence Improvement',FILL:'Fill in the Blanks',CLOZE:'Cloze Test',PARA:'Para Jumbles',RC:'Reading Comprehension',MISC:'Other'};
  return names[id]||String(topic||id||'Other');
}

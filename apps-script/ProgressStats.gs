function getEncounterProgress(){
  const all=allQuestions_().filter(q=>isActive_(q));
  const qMap=Object.fromEntries(all.map(q=>[q.id,q]));
  const firstSeen={},seen=new Set(),todaySeen=new Set();
  const perf=sheet_(EP.sheets.performance);
  if(perf.getLastRow()>1){
    const values=perf.getDataRange().getValues(),header=values[0].map(x=>String(x||'').trim().toLowerCase());
    let ti=header.findIndex(x=>x==='timestamp'||x==='time'||x==='attempt_time'||x==='attempt timestamp');
    let qi=header.findIndex(x=>x==='question_id'||x==='question id'||x==='questionid');
    if(ti<0)ti=0;if(qi<0)qi=1;
    const today=todayKey_();
    values.slice(1).forEach(r=>{
      const id=String(r[qi]||'').trim();if(!id||!qMap[id])return;
      const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;
      seen.add(id);
      if(!firstSeen[id]||d<firstSeen[id])firstSeen[id]=d;
      if(Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd')===today)todaySeen.add(id);
    });
  }
  const today=todayKey_(),todayNew=new Set();
  Object.keys(firstSeen).forEach(id=>{if(Utilities.formatDate(firstSeen[id],Session.getScriptTimeZone(),'yyyy-MM-dd')===today)todayNew.add(id)});
  const names={};
  table_(EP.sheets.categories).forEach(r=>{const id=String(r.Category_ID||'').trim();if(id)names[id]=String(r.Category_Name||id)});
  const grouped={};
  all.forEach(q=>{
    const id=canonicalCategory_(q.topic),name=names[id]||progressCategoryName_(id,q.topic);
    if(!grouped[id])grouped[id]={id,name,total:0,encountered:0,left:0,percent:0};
    grouped[id].total++;
    if(seen.has(q.id))grouped[id].encountered++;
  });
  Object.values(grouped).forEach(g=>{g.left=Math.max(0,g.total-g.encountered);g.percent=g.total?Math.round(g.encountered*1000/g.total)/10:0});
  const categories=Object.values(grouped).filter(g=>g.total>0).sort((a,b)=>b.total-a.total||a.name.localeCompare(b.name));
  const total=all.length,encountered=seen.size;
  return {date:today,total,encountered,left:Math.max(0,total-encountered),percent:total?Math.round(encountered*1000/total)/10:0,todayActivity:todaySeen.size,todayNew:todayNew.size,categories};
}

function progressCategoryName_(id,topic){
  const names={VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution / Fields of Study',SYN_ANT:'Synonyms & Antonyms',CONFUSED:'Confused Words',SPELLING:'Spelling',GRAMMAR:'Grammar',ERROR:'Error Detection',SENT_IMP:'Sentence Improvement',FILL:'Fill in the Blanks',CLOZE:'Cloze Test',PARA:'Para Jumbles',RC:'Reading Comprehension',MISC:'Other'};
  return names[id]||String(topic||id||'Other');
}

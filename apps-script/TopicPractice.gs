function topicStarted_(st){return Number(st&&st.attempts||0)>0;}
function topicWeak_(st){return ['weak','wrong'].includes(String(st&&st.status||'').toLowerCase())||Number(st&&st.wrong||0)>0;}
function topicNew_(st){return !topicStarted_(st);}

function getTopicPracticeHub(){
  const all=allQuestions_(),status=statusMap_(),grouped={};
  all.forEach(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;
    const id=canonicalCategory_(q.topic);if(id==='HINDU_VOCAB')return;
    if(!grouped[id])grouped[id]={id,name:topicPracticeName_(id,q.topic),total:0,weak:0,started:0,newCount:0};
    const g=grouped[id],st=status[q.id]||{};g.total++;if(topicWeak_(st))g.weak++;if(topicStarted_(st))g.started++;else g.newCount++;
  });
  const preferred=['VOC','IDIOM','PHRASAL','OWS','SYN_ANT','CONFUSED','SPELLING','GRAMMAR','ERROR','SENT_IMP','FILL','CLOZE','PARA','RC','MISC'];
  return Object.values(grouped).sort((a,b)=>{const ai=preferred.indexOf(a.id),bi=preferred.indexOf(b.id);return (ai<0?99:ai)-(bi<0?99:bi)||a.name.localeCompare(b.name)});
}

function getTopicPracticeItems(category){
  const wanted=String(category||'').trim(),status=statusMap_();
  return allQuestions_().filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&canonicalCategory_(q.topic)===wanted).map(q=>({id:q.id,word:q.word||'',question:q.question||'',topic:q.topic||'',subtopic:q.subtopic||'',weak:topicWeak_(status[q.id]||{}),started:topicStarted_(status[q.id]||{}),source:q.sourceFile||q.sourceId||''}));
}

function getTopicPracticeBatch(category,mode,count){
  const wanted=String(category||'').trim(),kind=String(mode||'all').toLowerCase(),status=statusMap_(),requested=Math.max(1,Math.min(100,Number(count||10)));
  let pool=allQuestions_().filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&canonicalCategory_(q.topic)===wanted);
  if(kind==='weak')pool=pool.filter(q=>topicWeak_(status[q.id]||{}));
  else if(kind==='started')pool=pool.filter(q=>topicStarted_(status[q.id]||{}));
  else if(kind==='new')pool=pool.filter(q=>topicNew_(status[q.id]||{}));
  if(kind==='random'){
    const now=Date.now(),buckets=[[],[],[],[]];
    pool.forEach(q=>{
      const st=status[q.id]||{},added=typeof recentContentDate_==='function'?recentContentDate_(q):null,days=added?(now-added.getTime())/86400000:999;
      if(topicWeak_(st))buckets[0].push(q);else if(days<=7)buckets[1].push(q);else if(topicStarted_(st))buckets[2].push(q);else buckets[3].push(q);
    });
    buckets.forEach(shuffle_);pool=buckets.flat();
  }else if(kind!=='all')shuffle_(pool);
  if(kind!=='all')pool=pool.slice(0,requested);
  return pool.map(serveQuestion_);
}

function topicPracticeName_(id,topic){
  const names={VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution',SYN_ANT:'Synonyms & Antonyms',CONFUSED:'Confused Words',SPELLING:'Spelling',GRAMMAR:'Grammar',ERROR:'Error Detection',SENT_IMP:'Sentence Improvement',FILL:'Fill in the Blanks',CLOZE:'Cloze Test',PARA:'Para Jumbles',RC:'Reading Comprehension',MISC:'Other'};
  return names[id]||String(topic||id||'Other');
}

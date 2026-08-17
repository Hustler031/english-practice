function newPracticeType_(q){
  const cat=String(canonicalCategory_(q.topic)||'').toUpperCase(),raw=[q.topic,q.subtopic,q.questionType,q.sourceFile,q.sourceId].map(x=>String(x||'').toLowerCase()).join(' ');
  if(/spelling|misspelt|misspelled|correctly spelt|incorrectly spelt/.test(raw))return'SPELL';
  if(cat==='IDIOM'||/idiom|phrase/.test(raw)&&!/phrasal/.test(raw))return'IDIOM';
  if(cat==='PHRASAL'||cat==='PV'||/phrasal verb/.test(raw))return'PHRASAL';
  if(cat==='OWS'||/one word substitution|one-word substitution/.test(raw))return'OWS';
  if(cat==='VOC'||/vocab|vocabulary/.test(raw))return'VOC';
  return cat&&cat!=='MISC'?cat:'OTHER';
}
function newPracticeTypeName_(id){return({VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution',SPELL:'Spelling Mistakes',OTHER:'Other'})[id]||newPracticeCategoryName_(id,id)}
function newPracticeSource_(q,hinduIds,myIds){
  if(myIds&&myIds.has(q.id))return'My Saved Words';if(hinduIds&&hinduIds.has(q.id))return'The Hindu';
  const sub=String(q.subtopic||''),src=String(q.sourceFile||q.sourceId||'');
  if(/english\s*madhyam/i.test(sub)||/english\s*madhyam/i.test(src))return'English Madhyam';
  if(/handwritten/i.test(src)||/handwritten/i.test(sub))return'Handwritten Notes';
  return src||sub||'Other';
}
function newPracticePermanentPool_(){
  const all=allQuestionsRaw_(),status=statusMap_(),hinduIds=new Set(typeof getSavedHinduQuestionIds==='function'?getSavedHinduQuestionIds():[]),myIds=new Set(typeof getMySavedWordQuestionIds==='function'?getMySavedWordQuestionIds():[]),out=[],seen=new Set();
  all.forEach(q=>{if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;const added=recentContentDate_(q),include=!!added||hinduIds.has(q.id)||myIds.has(q.id);if(include&&!seen.has(q.id)){seen.add(q.id);q.__npType=newPracticeType_(q);q.__npSource=newPracticeSource_(q,hinduIds,myIds);out.push(q)}});return out;
}
function newPracticeLivePool_(wanted,source){const key=String(wanted||'ALL').trim()||'ALL',src=String(source||'ALL');return newPracticePermanentPool_().filter(q=>(key==='ALL'||q.__npType===key)&&(src==='ALL'||q.__npSource===src));}
function newPracticeNewWordOrder_(pool,status){const st=status||statusMap_(),b=[[],[],[],[]];pool.forEach(q=>{const s=st[q.id]||{},attempts=Number(s.attempts||0),weak=newPracticeWeak_(s),added=recentContentDate_(q),addedMs=added?added.getTime():0,lastRaw=s.lastAttempt?new Date(s.lastAttempt).getTime():0,item={q,addedMs,last:isNaN(lastRaw)?0:lastRaw};if(attempts<=0&&addedMs)b[0].push(item);else if(attempts<=0)b[1].push(item);else if(weak)b[2].push(item);else b[3].push(item)});b[0].sort((a,z)=>z.addedMs-a.addedMs);b[1].sort((a,z)=>z.addedMs-a.addedMs);b[2].sort((a,z)=>z.last-a.last||z.addedMs-a.addedMs);b[3].sort((a,z)=>z.last-a.last||z.addedMs-a.addedMs);return b.flat().map(x=>x.q)}
function getNewPracticeHubLive(){
  const pool=newPracticePermanentPool_(),status=statusMap_(),fixed=['VOC','IDIOM','PHRASAL','OWS','SPELL'],extra=[];pool.forEach(q=>{if(!fixed.includes(q.__npType)&&!extra.includes(q.__npType))extra.push(q.__npType)});
  const ids=fixed.concat(extra),categories=ids.map(id=>{const rows=pool.filter(q=>q.__npType===id),sources=[...new Set(rows.map(q=>q.__npSource).filter(Boolean))].sort();return{id,name:newPracticeTypeName_(id),total:rows.length,weak:rows.filter(q=>newPracticeWeak_(status[q.id]||{})).length,newCount:rows.filter(q=>Number((status[q.id]||{}).attempts||0)===0).length,starred:rows.filter(q=>isStarredStatus_(status[q.id]||{})).length,sources}});
  return{categories,total:pool.length,weak:pool.filter(q=>newPracticeWeak_(status[q.id]||{})).length,newCount:pool.filter(q=>Number((status[q.id]||{}).attempts||0)===0).length,starred:pool.filter(q=>isStarredStatus_(status[q.id]||{})).length};
}
function getNewPracticeItemsLive(category,source){const status=statusMap_();return newPracticeLivePool_(category||'ALL',source||'ALL').map(q=>({id:q.id,word:q.word||'',question:q.question||'',category:newPracticeType_(q),topic:q.topic||'',subtopic:q.subtopic||'',weak:newPracticeWeak_(status[q.id]||{}),starred:isStarredStatus_(status[q.id]||{}),attempts:Number((status[q.id]||{}).attempts||0),source:q.__npSource||'',added:(()=>{const d=recentContentDate_(q);return d?Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd'):''})()}))}
function getNewPracticeBatchLive(category,kind,count,source){const status=statusMap_(),mode=String(kind||'all').toLowerCase();let pool=newPracticeLivePool_(category||'ALL',source||'ALL'),requested=Math.max(1,Math.min(100,Number(count||10)));if(mode==='new'||mode==='newwords')pool=newPracticeNewWordOrder_(pool,status).slice(0,requested);else if(mode==='starred')pool=newPracticeNewWordOrder_(pool.filter(q=>isStarredStatus_(status[q.id]||{})),status).slice(0,requested);else if(mode==='weak'){pool=pool.filter(q=>newPracticeWeak_(status[q.id]||{}));shuffle_(pool);if(Number(count||0)>0)pool=pool.slice(0,requested)}else if(mode==='random'){shuffle_(pool);pool=pool.slice(0,requested)}else if(Number(count||0)>0)pool=pool.slice(0,Math.min(120,Number(count)));return pool.map(serveQuestion_)}
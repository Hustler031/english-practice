function newPracticeType_(q){
  const cat=String(canonicalCategory_(q.topic)||'').toUpperCase(),meta=[q.topic,q.subtopic,q.questionType,q.sourceFile,q.sourceId].map(x=>String(x||'').toLowerCase()).join(' '),detail=[q.explanation,q.tip].map(x=>String(x||'').toLowerCase()).join(' ');
  if(/spelling|misspelt|misspelled|correctly spelt|incorrectly spelt/.test(meta)||/part of speech:\s*spelling/.test(detail))return'SPELL';
  if(cat==='PHRASAL'||cat==='PV'||/phrasal verb/.test(meta)||/part of speech:\s*phrasal verb/.test(detail))return'PHRASAL';
  if(cat==='IDIOM'||/idiom/.test(meta)||/part of speech:\s*(idiom|phrase)/.test(detail))return'IDIOM';
  if(cat==='OWS'||/one word substitution|one-word substitution/.test(meta)||/part of speech:\s*(ows|one word substitution)/.test(detail))return'OWS';
  if(cat==='VOC'||/vocab|vocabulary/.test(meta))return'VOC';
  return cat&&cat!=='MISC'?cat:'OTHER';
}
function newPracticeTypeName_(id){return({VOC:'Vocabulary',IDIOM:'Idioms & Phrases',PHRASAL:'Phrasal Verbs',OWS:'One Word Substitution',SPELL:'Spelling Mistakes',OTHER:'Other'})[id]||newPracticeCategoryName_(id,id)}
function newPracticeSource_(q,hinduIds,myIds){
  if(myIds&&myIds.has(q.id))return'My Saved Words';
  const sub=String(q.subtopic||''),src=String(q.sourceFile||q.sourceId||''),both=(sub+' '+src).trim();
  if((hinduIds&&hinduIds.has(q.id))||/\bthe\s+hindu\b/i.test(both)||/hindu\s+daily/i.test(both))return'The Hindu';
  if(/english\s*madhyam/i.test(both))return'English Madhyam';
  if(/handwritten/i.test(both))return'Handwritten Notes';
  return src||sub||'Other';
}
function newPracticePermanentPool_(){
  const all=allQuestionsRaw_(),status=statusMap_(),hinduIds=new Set(typeof getSavedHinduQuestionIds==='function'?getSavedHinduQuestionIds():[]),myMeta=typeof getMyWordPracticeMeta_==='function'?getMyWordPracticeMeta_():{ids:typeof getMySavedWordQuestionIds==='function'?getMySavedWordQuestionIds():[],typeMap:{}},myIds=new Set(myMeta.ids||[]),explicitTypes=myMeta.typeMap||{},out=[],seen=new Set();
  all.forEach(q=>{if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;const added=recentContentDate_(q),include=!!added||hinduIds.has(q.id)||myIds.has(q.id);if(include&&!seen.has(q.id)){seen.add(q.id);q.__npType=explicitTypes[q.id]&&typeof myWordTypeToNewPractice_==='function'?myWordTypeToNewPractice_(explicitTypes[q.id]):newPracticeType_(q);q.__npSource=newPracticeSource_(q,hinduIds,myIds);out.push(q)}});return out;
}
function newPracticeLivePool_(wanted,source){const key=String(wanted||'ALL').trim()||'ALL',src=String(source||'ALL');return newPracticePermanentPool_().filter(q=>(key==='ALL'||q.__npType===key)&&(src==='ALL'||q.__npSource===src));}
function newPracticeNewWordOrder_(pool,status){const st=status||statusMap_(),b=[[],[],[],[]];pool.forEach(q=>{const s=st[q.id]||{},attempts=Number(s.attempts||0),weak=newPracticeWeak_(s),added=recentContentDate_(q),addedMs=added?added.getTime():0,lastRaw=s.lastAttempt?new Date(s.lastAttempt).getTime():0,item={q,addedMs,last:isNaN(lastRaw)?0:lastRaw};if(attempts<=0&&addedMs)b[0].push(item);else if(attempts<=0)b[1].push(item);else if(weak)b[2].push(item);else b[3].push(item)});b[0].sort((a,z)=>z.addedMs-a.addedMs);b[1].sort((a,z)=>z.addedMs-a.addedMs);b[2].sort((a,z)=>z.last-a.last||z.addedMs-a.addedMs);b[3].sort((a,z)=>z.last-a.last||z.addedMs-a.addedMs);return b.flat().map(x=>x.q)}
function newPracticeStats_(rows,status){return{total:rows.length,weak:rows.filter(q=>newPracticeWeak_(status[q.id]||{})).length,newCount:rows.filter(q=>Number((status[q.id]||{}).attempts||0)===0).length,starred:rows.filter(q=>isStarredStatus_(status[q.id]||{})).length}}
function getNewPracticeHubLive(){
  const pool=newPracticePermanentPool_(),status=statusMap_(),fixed=['VOC','IDIOM','PHRASAL','OWS','SPELL'],extra=[];pool.forEach(q=>{if(!fixed.includes(q.__npType)&&!extra.includes(q.__npType))extra.push(q.__npType)});
  const ids=fixed.concat(extra),categories=ids.map(id=>{const rows=pool.filter(q=>q.__npType===id),names=[...new Set(rows.map(q=>q.__npSource).filter(Boolean))].sort(),sources=names.map(name=>({name,...newPracticeStats_(rows.filter(q=>q.__npSource===name),status)}));return{id,name:newPracticeTypeName_(id),...newPracticeStats_(rows,status),sources}});
  return{categories,...newPracticeStats_(pool,status)};
}
function getNewPracticeItemsLive(category,source){const status=statusMap_();return newPracticeLivePool_(category||'ALL',source||'ALL').map(q=>({id:q.id,word:q.word||'',question:q.question||'',category:q.__npType||newPracticeType_(q),topic:q.topic||'',subtopic:q.subtopic||'',weak:newPracticeWeak_(status[q.id]||{}),starred:isStarredStatus_(status[q.id]||{}),attempts:Number((status[q.id]||{}).attempts||0),source:q.__npSource||'',added:(()=>{const d=recentContentDate_(q);return d?Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd'):''})()}))}
function getNewPracticeBatchLive(category,kind,count,source){const status=statusMap_(),mode=String(kind||'all').toLowerCase();let pool=newPracticeLivePool_(category||'ALL',source||'ALL'),requested=Math.max(1,Math.min(100,Number(count||10)));if(mode==='new'||mode==='newwords')pool=newPracticeNewWordOrder_(pool,status).slice(0,requested);else if(mode==='starred')pool=newPracticeNewWordOrder_(pool.filter(q=>isStarredStatus_(status[q.id]||{})),status).slice(0,requested);else if(mode==='weak'){pool=pool.filter(q=>newPracticeWeak_(status[q.id]||{}));shuffle_(pool);if(Number(count||0)>0)pool=pool.slice(0,requested)}else if(mode==='random'){shuffle_(pool);pool=pool.slice(0,requested)}else if(Number(count||0)>0)pool=pool.slice(0,Math.min(120,Number(count)));return pool.map(serveQuestion_)}
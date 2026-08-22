const SOURCE_HUB_START = new Date(2026,7,15);

function sourceDescriptor_(q){
  const rawFile=String(q.sourceFile||'').trim(), rawId=String(q.sourceId||'').trim(), raw=(rawFile||rawId).trim();
  if(!raw) return null;
  const s=(rawFile+' '+rawId).toLowerCase();
  if(/\bhindu\b/.test(s)) return {key:'THE_HINDU',name:'The Hindu',kind:'hindu'};
  if(/screen\s*shot|screenshot|image\s*note|photo\s*note/.test(s)) return {key:'SCREENSHOTS',name:'Screenshots',kind:'screenshot'};
  const noteLike=/[=→]|\bmeans\b|\bwithout\b.+\bwith\b|[.;:].{6,}/i.test(rawFile) || rawFile.length>90 || /hand\s*written|handwritten|hand_note|notes?[_ -]?img/.test(s);
  if(noteLike) return {key:'HANDWRITTEN',name:'Handwritten Notes',kind:'handwritten'};
  const name=(rawFile||rawId).replace(/\s+/g,' ').trim();
  return {key:'NAMED::'+name.toLowerCase(),name,kind:/\.pdf\b|\bpdf\b/i.test(s)?'pdf':'named'};
}

function sourceAddedDate_(q){
  const d=typeof recentContentDate_==='function'?recentContentDate_(q):null;
  return d&&d>=SOURCE_HUB_START?d:null;
}
function sourceDateKey_(q){const d=sourceAddedDate_(q);return d?Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd'):'';}
function sourceQuestionMatches_(q,key){
  const wanted=String(key||''),d=sourceDescriptor_(q);if(!d)return false;
  if(wanted.indexOf('THE_HINDU::')===0)return d.key==='THE_HINDU'&&sourceDateKey_(q)===wanted.split('::')[1];
  return d.key===wanted;
}
function sourceWeak_(st){return ['weak','wrong'].includes(String(st&&st.status||'').toLowerCase())||Number(st&&st.wrong||0)>0;}

function getSourceHub(){
  const all=allQuestions_(), status=statusMap_(), grouped={};
  all.forEach(q=>{
    if(!isActive_(q)||(status[q.id]&&status[q.id].mastered))return;
    const added=sourceAddedDate_(q); if(!added)return;
    const d=sourceDescriptor_(q); if(!d)return;
    if(!grouped[d.key])grouped[d.key]={key:d.key,name:d.name,kind:d.kind,count:0,weak:0,recent:0,latest:'',categories:{},dates:{}};
    const g=grouped[d.key],st=status[q.id]||{};g.count++;if(sourceWeak_(st))g.weak++;
    const age=(Date.now()-added.getTime())/86400000;if(age<=7)g.recent++;
    const dk=Utilities.formatDate(added,Session.getScriptTimeZone(),'yyyy-MM-dd');if(!g.latest||dk>g.latest)g.latest=dk;
    if(d.kind==='hindu'){if(!g.dates[dk])g.dates[dk]={key:'THE_HINDU::'+dk,date:dk,count:0,weak:0};g.dates[dk].count++;if(sourceWeak_(st))g.dates[dk].weak++;}
    const cat=canonicalCategory_(q.topic);g.categories[cat]=(g.categories[cat]||0)+1;
  });
  return Object.values(grouped).sort((a,b)=>{
    const order={handwritten:0,hindu:1,screenshot:2,pdf:3,named:4};return (order[a.kind]??9)-(order[b.kind]??9)||b.latest.localeCompare(a.latest)||a.name.localeCompare(b.name);
  }).map(g=>({key:g.key,name:g.name,kind:g.kind,count:g.count,weak:g.weak,recent:g.recent,latest:g.latest,categorySummary:Object.entries(g.categories).map(([k,v])=>k+': '+v).join(' · '),children:Object.values(g.dates).sort((a,b)=>b.date.localeCompare(a.date))}));
}

function getSourceItems(sourceKey){
  const key=String(sourceKey||''),status=statusMap_();
  return allQuestions_().filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&sourceAddedDate_(q)&&sourceQuestionMatches_(q,key)).map(q=>({id:q.id,word:q.word||'',question:q.question||'',topic:q.topic||'',subtopic:q.subtopic||'',weak:sourceWeak_(status[q.id]||{}),attempts:Number((status[q.id]||{}).attempts||0),date:sourceDateKey_(q),source:(sourceDescriptor_(q)||{}).name||''}));
}

function getSourcePracticeBatch(sourceKey,mode,count){
  const key=String(sourceKey||''),kind=String(mode||'all').toLowerCase(),requested=Math.max(1,Math.min(100,Number(count||20)));
  const all=allQuestions_(),status=statusMap_(),stars=currentStarredMapV2_(),diff=centralDifficultMapV2_();
  let pool=all.filter(q=>isActive_(q)&&!(status[q.id]&&status[q.id].mastered)&&sourceAddedDate_(q)&&sourceQuestionMatches_(q,key));
  const descriptor=pool.length?sourceDescriptor_(pool[0]):null;
  if(kind==='weak'){pool=pool.filter(q=>sourceWeak_(status[q.id]||{}));shuffle_(pool);if(Number(count||0)>0)pool=pool.slice(0,requested);}
  else if(kind==='random'){
    const now=Date.now(),buckets=[[],[],[],[],[]];
    pool.forEach(q=>{const st=status[q.id]||{},added=sourceAddedDate_(q),days=added?(now-added.getTime())/86400000:999;if(sourceWeak_(st))buckets[0].push(q);else if(days<=7)buckets[1].push(q);else if(stars[q.id])buckets[2].push(q);else if(Number(st.attempts||0)>0)buckets[3].push(q);else buckets[4].push(q);});
    buckets.forEach(shuffle_);pool=buckets.flat().slice(0,requested);
  }
  const served=serveQuestionsCentralV3_(pool,{stars,diff});served.forEach(x=>{if(descriptor)x.source=descriptor.name;});return served;
}

function bankCoverageCategoryRows_(){
  const names={},orders={};table_(EP.sheets.categories).filter(r=>truthy_(r.Active)).forEach(r=>{const id=String(r.Category_ID||'').trim();names[id]=String(r.Category_Name||'');orders[id]=Number(r.Display_Order||99)});
  const facts=performanceFactsV2_(),mastered=currentMasteredMapV2_(),eligible=learningBankEligibleQuestionsV2_(allQuestions_(),facts,mastered),grouped={},seen=new Set();
  eligible.forEach(q=>{const id=String(q.id||'').trim();if(!id||seen.has(id))return;seen.add(id);const c=learningCategoryKeyV2_(q);if(!grouped[c])grouped[c]=[];grouped[c].push(q)});
  return Object.keys(grouped).map(id=>({id,name:names[id]||learningCategoryNameV2_(id,grouped[id][0]),questions:grouped[id]})).sort((a,b)=>(orders[a.id]??90)-(orders[b.id]??90)||a.name.localeCompare(b.name));
}
function getBankCoverageHub(){
  ensurePerformanceModuleColumn_();const facts=performanceFactsV2_(),mastered=currentMasteredMapV2_(),rows=bankCoverageCategoryRows_(),today=todayKey_(),diff=centralDifficultMapV2_();let total=0,exposed=0;
  const categories=rows.map(g=>{const ids=[...new Set(g.questions.map(q=>q.id))],exp=ids.filter(id=>facts.seen.has(id)).length,unseenIds=ids.filter(id=>!facts.seen.has(id)&&!mastered[id]),unseen=unseenIds.length,catIds=new Set(ids),doneToday=new Set(facts.all.filter(a=>a.module==='bankCoverage'&&dateKey_(a.ts)===today&&catIds.has(a.id)).map(a=>a.id)).size,available=Math.max(0,Math.min(10-doneToday,unseen));total+=ids.length;exposed+=exp;return {id:g.id,name:g.name,total:ids.length,exposed:exp,unseen,available,doneToday,coverage:learningPctV2_(exp,ids.length),difficult:ids.filter(id=>!!diff[id]).length,complete:unseen===0};});
  return {date:today,total,exposed,left:Math.max(0,total-exposed),coverage:learningPctV2_(exposed,total),complete:total>0&&categories.every(c=>c.complete),categories:categories.filter(c=>c.total>0)};
}
function getBankCoverageBatch(category){
  const cat=String(category||'').trim(),hub=getBankCoverageHub(),meta=hub.categories.find(c=>c.id===cat);if(!meta||meta.available<=0)return [];const facts=performanceFactsV2_(),mastered=currentMasteredMapV2_(),diff=centralDifficultMapV2_(),stars=currentStarredMapV2_(),group=bankCoverageCategoryRows_().find(g=>g.id===cat);if(!group)return [];
  const pool=shuffle_(group.questions.filter(q=>!mastered[q.id]&&!facts.seen.has(q.id))).slice(0,meta.available);return pool.map(q=>{const x=serveQuestion_(q);x.difficult=!!diff[q.id];x.marked=!!stars[q.id];return x;});
}

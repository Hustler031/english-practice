function bankCoverageCategoryRowsFromSnapshotV3_(all,facts,mastered){
  const names={},orders={};table_(EP.sheets.categories).filter(r=>truthy_(r.Active)).forEach(r=>{const id=String(r.Category_ID||'').trim();names[id]=String(r.Category_Name||'');orders[id]=Number(r.Display_Order||99)});
  const eligible=learningBankEligibleQuestionsV2_(all,facts,mastered),grouped={},seen=new Set();
  eligible.forEach(q=>{const id=String(q.id||'').trim();if(!id||seen.has(id))return;seen.add(id);const c=learningCategoryKeyV2_(q);if(!grouped[c])grouped[c]=[];grouped[c].push(q)});
  return Object.keys(grouped).map(id=>({id,name:names[id]||learningCategoryNameV2_(id,grouped[id][0]),questions:grouped[id]})).sort((a,b)=>(orders[a.id]??90)-(orders[b.id]??90)||a.name.localeCompare(b.name));
}
function bankCoverageSnapshotV3_(){const all=allQuestions_(),facts=performanceFactsV2_(),mastered=currentMasteredMapV2_();return {all,facts,mastered,rows:bankCoverageCategoryRowsFromSnapshotV3_(all,facts,mastered),today:todayKey_()};}
function bankCoverageCategoryRows_(){const s=bankCoverageSnapshotV3_();return s.rows;}
function bankCoverageMetaV3_(g,s,diff){const ids=[...new Set(g.questions.map(q=>q.id))],exp=ids.filter(id=>s.facts.seen.has(id)).length,unseenIds=ids.filter(id=>!s.facts.seen.has(id)&&!s.mastered[id]),unseen=unseenIds.length,catIds=new Set(ids),doneToday=new Set(s.facts.all.filter(a=>a.module==='bankCoverage'&&dateKey_(a.ts)===s.today&&catIds.has(a.id)).map(a=>a.id)).size,available=Math.max(0,Math.min(10-doneToday,unseen));return {id:g.id,name:g.name,total:ids.length,exposed:exp,unseen,available,doneToday,coverage:learningPctV2_(exp,ids.length),difficult:ids.filter(id=>!!diff[id]).length,complete:unseen===0};}
function getBankCoverageHub(){
  ensurePerformanceModuleColumn_();const s=bankCoverageSnapshotV3_(),diff=centralDifficultMapV2_();let total=0,exposed=0;const categories=s.rows.map(g=>{const m=bankCoverageMetaV3_(g,s,diff);total+=m.total;exposed+=m.exposed;return m;});
  return {date:s.today,total,exposed,left:Math.max(0,total-exposed),coverage:learningPctV2_(exposed,total),complete:total>0&&categories.every(c=>c.complete),categories:categories.filter(c=>c.total>0)};
}
function getBankCoverageBatch(category){
  const cat=String(category||'').trim(),s=bankCoverageSnapshotV3_(),group=s.rows.find(g=>g.id===cat);if(!group)return [];const diff=centralDifficultMapV2_(),stars=currentStarredMapV2_(),meta=bankCoverageMetaV3_(group,s,diff);if(meta.available<=0)return [];
  const pool=shuffle_(group.questions.filter(q=>!s.mastered[q.id]&&!s.facts.seen.has(q.id))).slice(0,meta.available);return pool.map(q=>{const x=serveQuestion_(q);x.difficult=!!diff[q.id];x.marked=!!stars[q.id];return x;});
}

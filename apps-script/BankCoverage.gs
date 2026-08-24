function bankCoverageCategoryRowsFromSnapshotV3_(all,facts,mastered){
  const names={},orders={};table_(EP.sheets.categories).filter(r=>truthy_(r.Active)).forEach(r=>{const id=String(r.Category_ID||'').trim();names[id]=String(r.Category_Name||'');orders[id]=Number(r.Display_Order||99)});
  const eligible=learningBankEligibleQuestionsV2_(all,facts,mastered),grouped={},seen=new Set();
  eligible.forEach(q=>{const id=String(q.id||'').trim();if(!id||seen.has(id))return;seen.add(id);const c=learningCategoryKeyV2_(q);if(!grouped[c])grouped[c]=[];grouped[c].push(q)});
  return Object.keys(grouped).map(id=>({id,name:names[id]||learningCategoryNameV2_(id,grouped[id][0]),questions:grouped[id]})).sort((a,b)=>(orders[a.id]??90)-(orders[b.id]??90)||a.name.localeCompare(b.name));
}
function bankCoverageSnapshotV3_(){
  const all=allQuestions_(),facts=performanceFactsV2_(),mastered=currentMasteredMapV2_(),rows=bankCoverageCategoryRowsFromSnapshotV3_(all,facts,mastered),today=todayKey_(),categoryById={},bankByCategory={},todayBankByCategory={};
  rows.forEach(g=>g.questions.forEach(q=>categoryById[q.id]=g.id));
  facts.all.forEach(a=>{if(a.module!=='bankCoverage')return;const cat=categoryById[a.id];if(!cat)return;(bankByCategory[cat]||(bankByCategory[cat]=[])).push(a);if(dateKey_(a.ts)===today)(todayBankByCategory[cat]||(todayBankByCategory[cat]=[])).push(a)});
  return {all,facts,mastered,rows,today,categoryById,bankByCategory,todayBankByCategory};
}
function bankCoverageCategoryRows_(){const s=bankCoverageSnapshotV3_();return s.rows;}
function bankCoverageLatestByIdV4_(attempts){const out={};(attempts||[]).forEach(a=>{if(!out[a.id]||a.ts>=out[a.id].ts)out[a.id]=a});return out;}
function bankCoverageTodaySummaryV4_(cat,s,diff){
  const attempts=(s.todayBankByCategory[cat]||[]).slice().sort((a,b)=>a.ts-b.ts),latest=bankCoverageLatestByIdV4_(attempts),ids=Object.keys(latest),newToday=ids.filter(id=>{const first=(s.facts.byId[id]||[])[0];return !!(first&&first.module==='bankCoverage'&&dateKey_(first.ts)===s.today)}).length;
  return {newToday,attemptedToday:ids.length,correct:ids.filter(id=>latest[id].correct).length,wrong:ids.filter(id=>!latest[id].correct).length,difficult:ids.filter(id=>!!diff[id]).length,latest};
}
function bankCoverageLastSessionV4_(cat,s){
  const attempts=(s.bankByCategory[cat]||[]).slice().sort((a,b)=>a.ts-b.ts);if(!attempts.length)return null;const end=attempts[attempts.length-1],day=dateKey_(end.ts),session=[end];let next=end;
  for(let i=attempts.length-2;i>=0;i--){const a=attempts[i],gap=next.ts-a.ts;if(dateKey_(a.ts)!==day||gap>30*60*1000)break;session.unshift(a);next=a;}
  const latest=bankCoverageLatestByIdV4_(session),ids=Object.keys(latest),tz=Session.getScriptTimeZone(),start=session[0].ts;
  return {attempted:ids.length,correct:ids.filter(id=>latest[id].correct).length,wrong:ids.filter(id=>!latest[id].correct).length,label:Utilities.formatDate(start,tz,'dd MMM · HH:mm'),date:day};
}
function bankCoverageMetaV3_(g,s,diff){
  const facts=s.facts,ids=[...new Set(g.questions.map(q=>q.id))],exp=ids.filter(id=>facts.seen.has(id)).length,unseenIds=ids.filter(id=>!facts.seen.has(id)&&!s.mastered[id]),unseen=unseenIds.length,today=bankCoverageTodaySummaryV4_(g.id,s,diff),recommended=Math.max(0,Math.min(10,unseen));
  return {id:g.id,name:g.name,total:ids.length,exposed:exp,left:unseen,unseen,available:recommended,recommended,doneToday:today.attemptedToday,newToday:today.newToday,attemptedToday:today.attemptedToday,todayCorrect:today.correct,todayWrong:today.wrong,todayDifficult:today.difficult,coverage:learningPctV2_(exp,ids.length),difficult:ids.filter(id=>!!diff[id]).length,complete:unseen===0,lastSession:bankCoverageLastSessionV4_(g.id,s)};
}
function getBankCoverageHub(){
  ensurePerformanceModuleColumn_();const s=bankCoverageSnapshotV3_(),diff=centralDifficultMapV2_();let total=0,exposed=0;const categories=s.rows.map(g=>{const m=bankCoverageMetaV3_(g,s,diff);total+=m.total;exposed+=m.exposed;return m;});
  return {date:s.today,total,exposed,left:Math.max(0,total-exposed),coverage:learningPctV2_(exposed,total),complete:total>0&&categories.every(c=>c.complete),categories:categories.filter(c=>c.total>0)};
}
function bankCoverageQuestionReviewV4_(q,a,stars,diff,s){
  const history=(s.facts.byId[q.id]||[]),todayAttempts=(s.todayBankByCategory[s.categoryById[q.id]]||[]).filter(x=>x.id===q.id),selected=String(a&&a.selected||'').toUpperCase(),correctKey=String(q.correct||'').toUpperCase();
  return {id:q.id,word:String(q.word||''),question:String(q.question||''),selectedKey:selected,selectedText:String(q.options&&q.options[selected]||''),correctKey,correctText:String(q.options&&q.options[correctKey]||''),correct:!!(a&&a.correct),starred:!!stars[q.id],difficult:!!diff[q.id],attemptsToday:todayAttempts.length,totalAttempts:history.length,explanation:String(q.explanation||'')};
}
function getBankCoverageCategoryDetail(category){
  const cat=String(category||'').trim(),s=bankCoverageSnapshotV3_(),group=s.rows.find(g=>g.id===cat);if(!group)throw new Error('Bank Coverage category not found');const diff=centralDifficultMapV2_(),stars=currentStarredMapV2_(),meta=bankCoverageMetaV3_(group,s,diff),today=bankCoverageTodaySummaryV4_(cat,s,diff),qmap=Object.fromEntries(group.questions.map(q=>[q.id,q]));
  const items=Object.keys(today.latest).map(id=>qmap[id]?bankCoverageQuestionReviewV4_(qmap[id],today.latest[id],stars,diff,s):null).filter(Boolean).sort((a,b)=>{const aa=today.latest[a.id],bb=today.latest[b.id];return aa.ts-bb.ts});
  return Object.assign({},meta,{date:s.today,today:{attempted:today.attemptedToday,correct:today.correct,wrong:today.wrong,difficult:today.difficult,items},lastSession:bankCoverageLastSessionV4_(cat,s)});
}
function getBankCoverageBatch(category,count){
  const cat=String(category||'').trim(),requested=Math.max(1,Math.min(100,Number(count||10))),s=bankCoverageSnapshotV3_(),facts=s.facts,group=s.rows.find(g=>g.id===cat);if(!group)return [];const diff=centralDifficultMapV2_(),stars=currentStarredMapV2_();
  const pool=shuffle_(group.questions.filter(q=>!s.mastered[q.id]&&!facts.seen.has(q.id))).slice(0,requested);return pool.map(q=>{const x=serveQuestion_(q);x.difficult=!!diff[q.id];x.marked=!!stars[q.id];return x;});
}
function getBankCoverageMixedBatch(count,excludedQuestionIds){
  const requested=Math.max(1,Math.min(50,Number(count||10))),s=bankCoverageSnapshotV3_(),facts=s.facts,blocked=new Set((Array.isArray(excludedQuestionIds)?excludedQuestionIds:[]).map(id=>String(id||'').trim()).filter(Boolean)),groups=s.rows.map(g=>({id:g.id,questions:shuffle_(g.questions.filter(q=>!s.mastered[q.id]&&!facts.seen.has(q.id)&&!blocked.has(String(q.id||'').trim())))})).filter(g=>g.questions.length),pool=[],used=new Set();
  shuffle_(groups);while(pool.length<requested){let added=0;shuffle_(groups);for(const g of groups){if(pool.length>=requested)break;while(g.questions.length){const q=g.questions.pop(),id=String(q&&q.id||'').trim();if(!id||used.has(id))continue;used.add(id);pool.push(q);added++;break;}}if(!added)break;}
  const diff=centralDifficultMapV2_(),stars=currentStarredMapV2_();return pool.map(q=>{const x=serveQuestion_(q);x.difficult=!!diff[q.id];x.marked=!!stars[q.id];return x;});
}
function getBankCoverageTodayBatch(category,kind,count){
  const cat=String(category||'').trim(),mode=String(kind||'all').toLowerCase(),requested=Math.max(1,Math.min(100,Number(count||100))),s=bankCoverageSnapshotV3_(),group=s.rows.find(g=>g.id===cat);if(!group)return [];const latest=bankCoverageLatestByIdV4_(s.todayBankByCategory[cat]||[]),diff=centralDifficultMapV2_(),stars=currentStarredMapV2_();let pool=group.questions.filter(q=>latest[q.id]);
  if(mode==='wrong')pool=pool.filter(q=>!latest[q.id].correct);else if(mode==='difficult')pool=pool.filter(q=>!!diff[q.id]);shuffle_(pool);pool=pool.slice(0,requested);return pool.map(q=>{const x=serveQuestion_(q);x.difficult=!!diff[q.id];x.marked=!!stars[q.id];return x;});
}
function getBankCoverageSeenBatch(category,count){
  const cat=String(category||'').trim(),requested=Math.max(1,Math.min(100,Number(count||10))),s=bankCoverageSnapshotV3_(),group=s.rows.find(g=>g.id===cat);if(!group)return [];const diff=centralDifficultMapV2_(),stars=currentStarredMapV2_();const pool=shuffle_(group.questions.filter(q=>!s.mastered[q.id]&&s.facts.seen.has(q.id))).slice(0,requested);return pool.map(q=>{const x=serveQuestion_(q);x.difficult=!!diff[q.id];x.marked=!!stars[q.id];return x;});
}

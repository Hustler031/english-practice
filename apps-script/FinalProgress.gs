function getFinalLearningProgress(){
  const a=getLearningAnalytics(),f=learningFacts_(),all=f.all,marked=currentMarkedIds_();
  const categories=a.categories.map(c=>({id:String(c.topic||''),name:c.topic,total:c.total,encountered:c.exposed,percent:c.coveragePercent,coveragePercent:c.coveragePercent,firstAttemptAccuracy:c.firstAttemptAccuracy,retentionAccuracy:c.retentionAccuracy,weak:c.weak,persistentWeak:c.persistentWeak,fragile:c.fragile,strong:c.strong,mastered:c.mastered,correctPercent:c.firstAttemptAccuracy,confidentPercent:c.retentionAccuracy,doubtPercent:pct1_(c.weak+c.persistentWeak,c.exposed)}));
  const legacyMetric=ids=>{const uniq=[...new Set(ids||[])],enc=uniq.filter(id=>(f.timeline.byId[id]||[]).length).length;return{total:uniq.length,encountered:enc,percent:pct1_(enc,uniq.length),correctPercent:a.firstAttemptAccuracy,confidentPercent:a.retentionAccuracy,doubtPercent:pct1_(a.weak+a.persistentWeak,Math.max(1,a.bankExposed))}};
  const mySavedIds=typeof getMySavedWordQuestionIds==='function'?getMySavedWordQuestionIds():[];
  const modules={practice:legacyMetric(all.map(q=>q.id)),new:legacyMetric(all.filter(q=>(f.timeline.byId[q.id]||[]).length===0).map(q=>q.id)),demanded:legacyMetric([]),hindu:legacyMetric([]),sources:legacyMetric(all.filter(q=>q.sourceFile||q.sourceId).map(q=>q.id)),saved:legacyMetric(mySavedIds)};
  return {date:todayKey_(),snapshotGeneratedAt:new Date().toISOString(),pending:false,
    total:a.bankEligible,encountered:a.bankExposed,left:Math.max(0,a.bankEligible-a.bankExposed),percent:a.bankExposedPercent,
    correctPercent:a.firstAttemptAccuracy,confidentPercent:a.retentionAccuracy,doubtPercent:pct1_(a.weak+a.persistentWeak,Math.max(1,a.bankExposed)),
    firstAttemptAccuracy:a.firstAttemptAccuracy,afterReviewAccuracy:a.afterReviewAccuracy,retentionAccuracy:a.retentionAccuracy,weakConcepts:a.weakConcepts,weak:a.weak,persistentWeak:a.persistentWeak,fragile:a.fragile,strong:a.strong,masteredCount:a.mastered,bankExposedPercent:a.bankExposedPercent,retentionMinHours:a.retentionMinHours,
    starredCount:marked.size,todayNew:0,todayActivity:0,categories,modules,
    overview:{encountered:a.bankExposed,total:a.bankEligible,todayNew:0,starred:marked.size,mastered:a.mastered}}
}

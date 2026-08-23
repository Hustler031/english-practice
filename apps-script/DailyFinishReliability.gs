function dailyFinishAttemptedIdsV4_(ids,batchDate){
  const wanted=new Set((ids||[]).map(x=>String(x||'').trim()).filter(Boolean)),done=new Set();if(!wanted.size)return done;
  const p=String(batchDate||'').split('-').map(Number),start=p.length===3&&p.every(Number.isFinite)?new Date(p[0],p[1]-1,p[2],0,0,0,0):null,facts=performanceFactsV2_();
  wanted.forEach(id=>(facts.byId[id]||[]).forEach(a=>{if(done.has(id)||String(a.module||'').toLowerCase()!=='daily')return;if(!start||a.ts>=start)done.add(id)}));return done;
}

function reconcileDailyCompletionV4(expectedIds,expectedDate){
  const ids=(Array.isArray(expectedIds)?expectedIds:[]).map(x=>String(x||'').trim()).filter(Boolean),batchDate=String(expectedDate||'').trim(),s=sheet_(EP.sheets.daily);
  let rows=table_(EP.sheets.daily).filter(r=>String(r.Question_ID||'').trim()),activeDate=rows.length?dateKey_(rows[0].Quiz_Date):'';
  if(rows.length&&(!batchDate||activeDate===batchDate)){
    rows=syncDailyCompletionsV3_(rows,s);activeDate=rows.length?dateKey_(rows[0].Quiz_Date):activeDate;
    const remainingIds=rows.filter(r=>String(r.Status||'').toLowerCase()!=='completed').map(r=>String(r.Question_ID||'').trim()).filter(Boolean);
    return {ok:true,total:rows.length,completed:rows.length-remainingIds.length,remaining:remainingIds.length,remainingIds,activeDate,batchAdvanced:false};
  }
  const attempted=dailyFinishAttemptedIdsV4_(ids,batchDate),remainingIds=ids.filter(id=>!attempted.has(id));
  return {ok:true,total:ids.length,completed:ids.length-remainingIds.length,remaining:remainingIds.length,remainingIds,activeDate,batchAdvanced:!!(batchDate&&activeDate&&activeDate!==batchDate)};
}

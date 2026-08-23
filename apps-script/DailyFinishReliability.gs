function reconcileDailyCompletionV4(){
  const s=sheet_(EP.sheets.daily);
  let rows=table_(EP.sheets.daily).filter(r=>String(r.Question_ID||'').trim());
  if(!rows.length)return {ok:true,total:0,completed:0,remaining:0,remainingIds:[],activeDate:''};
  rows=syncDailyCompletionsV3_(rows,s);
  const activeDate=rows.length?dateKey_(rows[0].Quiz_Date):'';
  const remainingIds=rows.filter(r=>String(r.Status||'').toLowerCase()!=='completed').map(r=>String(r.Question_ID||'').trim()).filter(Boolean);
  return {ok:true,total:rows.length,completed:rows.length-remainingIds.length,remaining:remainingIds.length,remainingIds,activeDate};
}

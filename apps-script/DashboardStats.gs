function getTodayActivityCount(){
  const s=sheet_(EP.sheets.performance);
  if(s.getLastRow()<2)return {count:0,date:todayKey_()};
  const values=s.getDataRange().getValues();
  if(values.length<2)return {count:0,date:todayKey_()};
  const header=values[0].map(x=>String(x||'').trim().toLowerCase());
  let ti=header.findIndex(x=>x==='timestamp'||x==='time'||x==='attempt_time'||x==='attempt timestamp');
  let qi=header.findIndex(x=>x==='question_id'||x==='question id'||x==='questionid');
  if(ti<0)ti=0;if(qi<0)qi=1;
  const today=todayKey_(),ids=new Set();
  values.slice(1).forEach(r=>{
    const id=String(r[qi]||'').trim();if(!id)return;
    const d=r[ti] instanceof Date?r[ti]:new Date(r[ti]);if(isNaN(d))return;
    if(Utilities.formatDate(d,Session.getScriptTimeZone(),'yyyy-MM-dd')===today)ids.add(id);
  });
  return {count:ids.size,date:today};
}

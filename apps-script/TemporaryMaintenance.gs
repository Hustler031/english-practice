// One-time, narrowly scoped production repair bridge. Remove after reconciliation.
const TEMP_MAINTENANCE_TOKEN_HASH='d61e8eb414f3363a74a3418a2dc828e3cb124d49c2c1fec8e7b8521d318f22af';
const TEMP_MAINTENANCE_USED_KEY='EP_TEMP_MAINTENANCE_USED_V1';
function temporaryMaintenanceV1(token,action){
  const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,String(token||'')).map(b=>(b<0?b+256:b).toString(16).padStart(2,'0')).join('');
  if(digest!==TEMP_MAINTENANCE_TOKEN_HASH)throw new Error('Maintenance authorization denied');
  const props=PropertiesService.getScriptProperties(),used=props.getProperty(TEMP_MAINTENANCE_USED_KEY);
  if(used&&action!=='health')throw new Error('Maintenance bridge already used');
  const before=temporaryMaintenanceHealthV1_();
  if(action==='health')return before;
  if(action!=='repair')throw new Error('Unsupported maintenance action');
  const triggerOk=ensureMyWordReconcileTrigger_();
  const result=reconcileReadyMyWordsFast_(true);
  const derived=repairPendingLearningDerivationsV4(25);
  props.setProperty(TEMP_MAINTENANCE_USED_KEY,new Date().toISOString());
  return {before,triggerOk,result,derived,after:temporaryMaintenanceHealthV1_()};
}
function temporaryMaintenanceHealthV1_(){
  const s=myWordsSheet_(),last=s.getLastRow(),h=s.getRange(1,1,1,s.getLastColumn()).getValues()[0].map(String),ix=n=>h.indexOf(n),rows=last<2?[]:s.getRange(2,1,last-1,s.getLastColumn()).getValues();
  const valid=r=>!!String(r[ix('Meaning')]||'').trim()&&!!String(r[ix('Question')]||'').trim()&&['A','B','C','D'].includes(String(r[ix('Correct_Option')]||'').trim())&&['Option_A','Option_B','Option_C','Option_D'].every(k=>String(r[ix(k)]||'').trim());
  const ready=rows.filter(r=>truthy_(r[ix('Active')])&&String(r[ix('GPT_Status')]||'').trim().toLowerCase()==='ready');
  const unlinked=ready.filter(r=>valid(r)&&!String(r[ix('Practice_Question_ID')]||'').trim());
  const handlers=ScriptApp.getProjectTriggers().filter(t=>t.getHandlerFunction()===MYWORD_RECONCILE_TRIGGER_FN);
  return {ready:ready.length,validUnlinked:unlinked.length,reconcileTrigger:handlers.length>0,handler:MYWORD_RECONCILE_TRIGGER_FN,derivedPending:Object.keys(derivedRepairQueueV3_()).length};
}

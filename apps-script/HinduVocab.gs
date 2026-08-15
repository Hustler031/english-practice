const HINDU_VOCAB_SHEET='Hindu_Vocab_List';

function ensureHinduVocabSheet_(){
  const ss=ss_(); let s=ss.getSheetByName(HINDU_VOCAB_SHEET);
  if(!s){s=ss.insertSheet(HINDU_VOCAB_SHEET);s.getRange(1,1,1,6).setValues([['Hindu_ID','Question_ID','Added_Date','Marked','In_Vocab','Active']]);s.setFrozenRows(1);}
  return s;
}

function hinduRawId_(id){return String(id||'').trim().replace(/^HINDU_/,'');}
function resolveHinduQuestionId_(id){
  const raw=hinduRawId_(id); if(!raw)return'';
  const hs=sheet_(EP.sheets.hindu),row=findRow_(hs,1,raw); if(row<2)return'';
  const word=String(hs.getRange(row,3).getValue()||'').trim().toLowerCase();
  const m=raw.match(/(20\d{6})/),date=m?m[1]:'';
  const all=allQuestions_();
  let q=all.find(x=>date&&String(x.id||'').startsWith('HV'+date)&&String(x.word||'').trim().toLowerCase()===word);
  if(!q)q=all.find(x=>date&&String(x.sourceId||'').includes(date)&&String(x.word||'').trim().toLowerCase()===word);
  return q?q.id:'';
}
function upsertHinduVocab_(id,changes){
  const raw=hinduRawId_(id),qid=resolveHinduQuestionId_(raw),s=ensureHinduVocabSheet_();
  if(!raw)throw new Error('Hindu word ID required');
  let row=findRow_(s,1,raw),vals=row>1?s.getRange(row,1,1,6).getValues()[0]:[raw,qid,'',false,false,true];
  if(qid)vals[1]=qid;
  if(Object.prototype.hasOwnProperty.call(changes,'added')&&changes.added){vals[2]=vals[2]||new Date();vals[4]=true;}
  if(Object.prototype.hasOwnProperty.call(changes,'marked'))vals[3]=!!changes.marked;
  vals[5]=true;
  if(row>1)s.getRange(row,1,1,6).setValues([vals]);else s.appendRow(vals);
  return {ok:true,hinduId:raw,questionId:vals[1],marked:!!vals[3],inVocab:!!vals[4]};
}
function setHinduMarked(id,marked){const r=upsertHinduVocab_(id,{marked:!!marked});if(r.questionId)setMarked(r.questionId,!!marked);return r;}
function addHinduToVocab(id){return upsertHinduVocab_(id,{added:true});}
function getSavedHinduQuestionIds(){
  const s=ensureHinduVocabSheet_(); if(s.getLastRow()<2)return[];
  return s.getRange(2,1,s.getLastRow()-1,6).getValues().filter(r=>truthy_(r[4])&&truthy_(r[5])&&String(r[1]||'').trim()).map(r=>String(r[1]).trim());
}

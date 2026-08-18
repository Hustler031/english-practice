const MY_WORD_TYPES_SHEET='My_Word_Types';
const MY_WORD_TYPE_LABELS={V:'Vocabulary',SM:'Spelling Mistakes',OWS:'One Word Substitution',PV:'Phrasal Verbs',IP:'Idioms & Phrases'};

function normalizeMyWordType_(value){const x=String(value||'V').trim().toUpperCase().replace('/','');return Object.prototype.hasOwnProperty.call(MY_WORD_TYPE_LABELS,x)?x:'V';}
function ensureMyWordTypesSheet_(){const ss=ss_();let s=ss.getSheetByName(MY_WORD_TYPES_SHEET);if(!s){s=ss.insertSheet(MY_WORD_TYPES_SHEET);s.getRange(1,1,1,3).setValues([['Saved_ID','Capture_Type','Updated_At']]);s.setFrozenRows(1);}return s;}
function setMyWordCaptureType_(savedId,type){const id=String(savedId||'').trim();if(!id)return;const t=normalizeMyWordType_(type),s=ensureMyWordTypesSheet_(),row=findRow_(s,1,id),vals=[id,t,new Date()];if(row>1)s.getRange(row,1,1,3).setValues([vals]);else s.appendRow(vals);}
function captureMyWordTyped(payload){payload=payload||{};const result=captureMyWord(payload);if(result&&result.id)setMyWordCaptureType_(result.id,payload.captureType||payload.type||'V');return Object.assign({},result,{captureType:normalizeMyWordType_(payload.captureType||payload.type||'V')});}
function getMyWordCaptureTypes(){const s=ensureMyWordTypesSheet_();if(s.getLastRow()<2)return{};const out={};s.getRange(2,1,s.getLastRow()-1,3).getValues().forEach(r=>{const id=String(r[0]||'').trim();if(id)out[id]=normalizeMyWordType_(r[1])});return out;}
function getMyWordPracticeMeta_(){const bySaved=getMyWordCaptureTypes(),ids=[],typeMap={};getMyWords().forEach(w=>{const qid=String(w.practiceQuestionId||'').trim();if(!qid)return;ids.push(qid);typeMap[qid]=normalizeMyWordType_(bySaved[String(w.id||'')]||'V')});return{ids,typeMap};}
function getMyWordPracticeTypeMap_(){return getMyWordPracticeMeta_().typeMap;}
function myWordTypeToNewPractice_(type){return({V:'VOC',SM:'SPELL',OWS:'OWS',PV:'PHRASAL',IP:'IDIOM'})[normalizeMyWordType_(type)]||'VOC';}
function getMyWordCaptureTypeInfo(){const types=getMyWordCaptureTypes();return getMyWords().map(w=>({id:w.id,type:normalizeMyWordType_(types[String(w.id||'')]||'V'),label:MY_WORD_TYPE_LABELS[normalizeMyWordType_(types[String(w.id||'')]||'V')]}));}

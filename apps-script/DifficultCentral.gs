function setQuestionDifficult(questionId,difficult){
  const id=String(questionId||'').trim();if(!id)return {ok:false};
  const q=findQuestion_(id);if(!q||!isActive_(q))return {ok:false,reason:'question-not-active'};
  const st=statusMap_()[id]||{};if(st.mastered)return {ok:false,reason:'mastered'};
  const s=starredRevisionDifficultSheet_(),row=findRow_(s,1,id),now=new Date(),value=!!difficult;
  if(row>1)s.getRange(row,2,1,2).setValues([[value,now]]);else s.appendRow([id,value,now]);
  return {ok:true,questionId:id,difficult:value};
}
function getCentralDifficultMap(){return starredRevisionDifficultMap_();}
function isQuestionDifficult_(questionId,map){map=map||starredRevisionDifficultMap_();return !!map[String(questionId||'').trim()];}

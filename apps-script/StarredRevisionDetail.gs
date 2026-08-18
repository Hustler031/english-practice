function getStarredRevisionQuestionDetail(questionId){
  const id=String(questionId||'').trim();if(!id)throw new Error('Question ID required');
  const allowed=starredRevisionIndex_().some(x=>x.id===id);if(!allowed)throw new Error('Starred question not found.');
  const q=(typeof allQuestionsRaw_==='function'?allQuestionsRaw_():allQuestions_()).find(x=>String(x.id||'')===id);if(!q)throw new Error('Question not found.');
  const served=serveQuestion_(q);return Object.assign({},served,{readOnly:true});
}

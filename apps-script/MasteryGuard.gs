function markMasteredV2(questionId){
  const id=String(questionId||'').trim();if(!id)throw new Error('Question ID required');
  const f=learningFacts_(),x=f.byQuestion[id],attempts=f.timeline.byId[id]||[];
  if(!x||!attempts.length)throw new Error('Mastery needs real practice first.');
  if(x.state!=='STRONG')throw new Error('Mastery needs 2 correct spaced recalls with no current weakness.');
  return markMastered(id);
}

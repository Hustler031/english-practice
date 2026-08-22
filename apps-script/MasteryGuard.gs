function markMasteredV2(questionId){
  const id=String(questionId||'').trim();if(!id)throw new Error('Question ID required');
  const f=learningFacts_(),x=f.byQuestion[id],attempts=f.timeline.byId[id]||[];
  if(!x||!attempts.length)throw new Error('Mastery needs real practice first.');
  if(Number(x.retentionCorrect||0)<2)throw new Error('Mastery needs 2 correct spaced recalls first.');
  return markMastered(id);
}

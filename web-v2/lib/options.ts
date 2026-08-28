export type CanonicalOption={key:string;text:string};
export type DisplayOption={key:string;text:string;canonicalKey:string};

const DISPLAY_KEYS=["A","B","C","D"];

export function shuffleSafe(questionType:string|undefined,options:CanonicalOption[]){
  const type=String(questionType||"").toLowerCase();
  if(/order|sequence|match|arrange|para/.test(type))return false;
  return !options.some(o=>/all of the above|none of the above|both [a-d]|either [a-d]/i.test(String(o.text||"")));
}

export function makeDisplayOptions(questionType:string|undefined,canonical:CanonicalOption[],forceShuffle=false):DisplayOption[]{
  const items=canonical.map(o=>({canonicalKey:String(o.key||"").toUpperCase(),text:String(o.text||"")}));
  if(forceShuffle||shuffleSafe(questionType,canonical)){
    for(let i=items.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[items[i],items[j]]=[items[j],items[i]];}
  }
  return items.map((o,i)=>({key:DISPLAY_KEYS[i]||String(i+1),text:o.text,canonicalKey:o.canonicalKey}));
}

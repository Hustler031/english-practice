export type CanonicalOption={key:string;text:string};
export type DisplayOption={key:string;text:string;canonicalKey:string};

const DISPLAY_KEYS=["A","B","C","D"];
const UNSAFE_OPTION=/\ball of the above\b|\bnone of the above\b|\bboth\s+[a-d](?:\s+and\s+[a-d])?\b|\beither\s+[a-d](?:\s+or\s+[a-d])?\b|\b[a-d]\s+and\s+[a-d]\s+only\b/i;
const UNSAFE_STEM=/\b(correct|incorrect)\s+(?:order|sequence|arrangement)\b|\bchronological\s+order\b|\barrange\b|\bmatch\s+(?:the\s+)?following\b|\bsequence\b/i;

export function shuffleSafe(questionType:string|undefined,options:CanonicalOption[],questionText=""){
  const type=String(questionType||"").toLowerCase();
  const stem=String(questionText||"");
  if(/order|sequence|match|arrange|para/.test(type)||UNSAFE_STEM.test(stem))return false;
  return !options.some(o=>UNSAFE_OPTION.test(String(o.text||"")));
}

export function makeDisplayOptions(questionType:string|undefined,canonical:CanonicalOption[],forceShuffle=false,questionText=""):DisplayOption[]{
  const items=canonical.map(o=>({canonicalKey:String(o.key||"").toUpperCase(),text:String(o.text||"")}));
  if(forceShuffle||shuffleSafe(questionType,canonical,questionText)){
    for(let i=items.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[items[i],items[j]]=[items[j],items[i]];}
  }
  return items.map((o,i)=>({key:DISPLAY_KEYS[i]||String(i+1),text:o.text,canonicalKey:o.canonicalKey}));
}

export function restoreDisplayOptions(canonical:CanonicalOption[],order:string[]):DisplayOption[]{
  const byKey=new Map(canonical.map(o=>[String(o.key).toUpperCase(),String(o.text||"")]));
  const valid=(order||[]).map(x=>String(x).toUpperCase()).filter(x=>byKey.has(x));
  const keys=valid.length===canonical.length?valid:canonical.map(o=>String(o.key).toUpperCase());
  return keys.map((canonicalKey,i)=>({key:DISPLAY_KEYS[i]||String(i+1),canonicalKey,text:byKey.get(canonicalKey)||""}));
}

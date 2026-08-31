import styles from "./gk.module.css";

type QuestionSegment={marker?:string;text:string};

function normalMarker(marker:string){const lower=marker.toLowerCase();if(lower.startsWith("assertion"))return "Assertion (A)";if(lower.startsWith("reason"))return "Reason (R)";return marker;}
function markerParts(line:string):QuestionSegment{
 const ar=line.match(/^(Assertion\s*\(?A\)?|Reason\s*\(?R\)?)\s*[:.)-]?\s+(.*)$/i);
 if(ar)return {marker:normalMarker(ar[1]),text:ar[2]};
 const hit=line.match(/^(\d+[.)]|\(\d+\)|Statement\s+\d+[:.)]?)(?:\s+)(.*)$/i);
 return hit?{marker:hit[1],text:hit[2]}:{text:line};
}
function assertionReason(text:string):QuestionSegment[]|null{
 const a=/\bAssertion\s*\(?A\)?\s*[:.)-]?\s*/i.exec(text),r=/\bReason\s*\(?R\)?\s*[:.)-]?\s*/i.exec(text);
 if(!a||!r||a.index>r.index)return null;
 const out:QuestionSegment[]=[];
 const intro=text.slice(0,a.index).trim();if(intro)out.push({text:intro});
 const assertion=text.slice(a.index+a[0].length,r.index).trim();
 let reason=text.slice(r.index+r[0].length).trim(),prompt="";
 const tail=reason.match(/\s+((?:Which|Choose|Select)\b[\s\S]{0,220}\?)\s*$/i);
 if(tail&&tail.index!==undefined){prompt=tail[1].trim();reason=reason.slice(0,tail.index).trim();}
 if(assertion)out.push({marker:"Assertion (A)",text:assertion});
 if(reason)out.push({marker:"Reason (R)",text:reason});
 if(prompt)out.push({text:prompt});
 return out.length>=2?out:null;
}
export function splitGkQuestion(text:string):QuestionSegment[]{
 const raw=String(text||""),t=raw.trim();if(!t)return[{text:""}];
 const ar=assertionReason(t);if(ar)return ar;
 const physical=raw.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(physical.length>1)return physical.map(markerParts);
 const re=/(^|\s)(\d+[.)]|\(\d+\)|Statement\s+\d+[:.)]?)(?=\s)/gi;
 const hits=[...t.matchAll(re)].map(m=>({start:Number(m.index||0)+(m[1]?.length||0),marker:m[2],n:Number((m[2].match(/\d+/)||["0"])[0])}));
 const sequential=hits.length>=2&&hits[0].n===1&&hits.every((h,i)=>i===0||h.n===hits[i-1].n+1);if(!sequential)return[{text:t}];
 const out:QuestionSegment[]=[],intro=t.slice(0,hits[0].start).trim();if(intro)out.push({text:intro});
 hits.forEach((h,i)=>{const end=i+1<hits.length?hits[i+1].start:t.length,body=t.slice(h.start+h.marker.length,end).trim();out.push({marker:h.marker,text:body});});
 return out;
}
export default function QuestionText({text}:{text:string}){
 const rendered=splitGkQuestion(text),structured=rendered.some(x=>x.marker);
 return <>{rendered.map((line,i)=>line.marker?<span className={styles.statement} key={i}><strong>{line.marker}</strong><span>{line.text}</span></span>:<span className={structured||rendered.length>1?styles.statement:undefined} key={i}>{line.text}</span>)}</>;
}

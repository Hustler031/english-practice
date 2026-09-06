// Server-only English writer/critic pipeline for My Saved + Phrasal.
// Hindu intentionally remains on its separate content-ingest path.
export const ANTIGRAVITY_AGENT = Deno.env.get("ANTIGRAVITY_AGENT") || "antigravity-preview-05-2026";
export const ANTIGRAVITY_MODEL = Deno.env.get("ANTIGRAVITY_MODEL") || "gemini-3.6-flash";
export const LUNA_MODEL = Deno.env.get("LUNA_MODEL") || "gpt-5.6-luna";
export const GEMINI_RARE_RESCUE_MODEL = Deno.env.get("GEMINI_RARE_RESCUE_MODEL") || "gemini-3.8-flash";
const ANTIGRAVITY_MAX_TOTAL_TOKENS = Math.max(4_000, Math.min(40_000, Number(Deno.env.get("ANTIGRAVITY_MAX_TOTAL_TOKENS")) || 18_000));
const TRANSIENT = new Set([429, 500, 502, 503, 504]);

export type HardGates = {
  exactlyOneCorrect:boolean; correctKeyMatches:boolean; linguisticallyValid:boolean;
  conceptPreserved:boolean; sensePreserved:boolean; learnerRequestPreserved:boolean;
  noFactualError:boolean; noLexicalGrammarError:boolean; requiredOptionsValid:boolean;
  explanationMatchesQuestion:boolean; explanationMatchesAnswer:boolean; noStaleExplanation:boolean;
  noAmbiguity:boolean; noSecondCorrectOption:boolean; intentSpecificTaskValid:boolean;
  questionFamilyValid:boolean; plausibleDistractors:boolean; distractorsNotObvious:boolean;
};
export type LunaQuality = {
  score:number;
  decision:"PASS"|"REPAIR"|"REJECT";
  hardGates:HardGates;
  issues:string[];
  repairInstruction:string;
};

const gateProperties:Record<keyof HardGates,unknown>={
  exactlyOneCorrect:{type:"boolean"},correctKeyMatches:{type:"boolean"},linguisticallyValid:{type:"boolean"},
  conceptPreserved:{type:"boolean"},sensePreserved:{type:"boolean"},learnerRequestPreserved:{type:"boolean"},
  noFactualError:{type:"boolean"},noLexicalGrammarError:{type:"boolean"},requiredOptionsValid:{type:"boolean"},
  explanationMatchesQuestion:{type:"boolean"},explanationMatchesAnswer:{type:"boolean"},noStaleExplanation:{type:"boolean"},
  noAmbiguity:{type:"boolean"},noSecondCorrectOption:{type:"boolean"},intentSpecificTaskValid:{type:"boolean"},
  questionFamilyValid:{type:"boolean"},plausibleDistractors:{type:"boolean"},distractorsNotObvious:{type:"boolean"},
};
const gateKeys=Object.keys(gateProperties);
export const lunaQualitySchema={
  type:"object",additionalProperties:false,
  required:["score","decision","hardGates","issues","repairInstruction"],
  properties:{
    score:{type:"number",minimum:0,maximum:100},
    decision:{type:"string",enum:["PASS","REPAIR","REJECT"]},
    hardGates:{type:"object",additionalProperties:false,properties:gateProperties,required:gateKeys},
    issues:{type:"array",items:{type:"string"},maxItems:12},
    repairInstruction:{type:"string",maxLength:1200},
  },
};

const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown AI pipeline error");
const sleep=(ms:number)=>new Promise(resolve=>setTimeout(resolve,ms));
function withTimeout(ms:number){const c=new AbortController();const timer=setTimeout(()=>c.abort(),ms);return {c,timer}}
function parseJsonText(text:string,label:string){
  let raw=String(text||"").trim();
  raw=raw.replace(/^```(?:json)?\s*/i,"").replace(/\s*```$/i,"").trim();
  try{return JSON.parse(raw)}catch{}
  const start=raw.indexOf("{"),end=raw.lastIndexOf("}");
  if(start>=0&&end>start){try{return JSON.parse(raw.slice(start,end+1))}catch{}}
  throw new Error(`${label}_MALFORMED_JSON`);
}
function googleInteractionText(payload:any){
  if(typeof payload?.output_text==="string"&&payload.output_text.trim())return payload.output_text.trim();
  const chunks:string[]=[];
  for(const step of payload?.steps||[]){
    if(step?.type!=="model_output")continue;
    for(const part of step?.content||[])if(part?.type==="text"&&typeof part?.text==="string")chunks.push(part.text);
  }
  return chunks.join("").trim();
}
function openaiOutputText(payload:any){
  if(typeof payload?.output_text==="string"&&payload.output_text.trim())return payload.output_text.trim();
  const chunks:string[]=[];
  for(const item of payload?.output||[])for(const part of item?.content||[])if(part?.type==="output_text"&&typeof part?.text==="string")chunks.push(part.text);
  return chunks.join("").trim();
}

export async function antigravityJson<T>(instructions:string,input:unknown,opts:{maxAttempts?:number}={}):Promise<{data:T;provider:"antigravity";model:string}> {
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const maxAttempts=Math.max(1,Math.min(2,Number(opts.maxAttempts)||2));
  for(let attempt=0;attempt<maxAttempts;attempt++){
    const {c,timer}=withTimeout(95_000);
    try{
      const res=await fetch("https://generativelanguage.googleapis.com/v1beta/interactions",{
        method:"POST",signal:c.signal,
        headers:{"x-goog-api-key":key,"Content-Type":"application/json","Api-Revision":"2026-05-20"},
        body:JSON.stringify({
          agent:ANTIGRAVITY_AGENT,
          input:JSON.stringify(input),
          system_instruction:`${instructions}\n\nWork carefully with high reasoning effort. Use only the supplied assignment as the learning source; do not browse for unrelated facts. Return ONLY one complete valid JSON object and no markdown or commentary.`,
          environment:"remote",
          store:true,
          background:false,
          agent_config:{type:"antigravity",model:ANTIGRAVITY_MODEL,max_total_tokens:String(ANTIGRAVITY_MAX_TOTAL_TOKENS)},
        }),
      });
      const payload=await res.json().catch(()=>null);
      if(res.ok){
        if(payload?.status&&payload.status!=="completed")throw new Error(`ANTIGRAVITY_${String(payload.status).toUpperCase()}`);
        const text=googleInteractionText(payload);
        if(!text)throw new Error("ANTIGRAVITY_MALFORMED_OUTPUT: no JSON text returned");
        return {data:parseJsonText(text,"ANTIGRAVITY") as T,provider:"antigravity",model:String(payload?.model||ANTIGRAVITY_MODEL)};
      }
      if(!TRANSIENT.has(res.status)||attempt===maxAttempts-1)throw new Error(`ANTIGRAVITY_${res.status}: ${payload?.error?.message||"request failed"}`);
    }catch(e:any){
      if(e?.name==="AbortError"){
        if(attempt===maxAttempts-1)throw new Error("ANTIGRAVITY_TIMEOUT");
      }else if(!/^ANTIGRAVITY_(429|500|502|503|504):/.test(errorText(e))){
        throw e;
      }else if(attempt===maxAttempts-1)throw e;
    }finally{clearTimeout(timer)}
    await sleep(800*(attempt+1));
  }
  throw new Error("ANTIGRAVITY_RETRY_EXHAUSTED");
}

export async function lunaJson<T>(instructions:string,input:unknown,schema:unknown):Promise<{data:T;provider:"openai";model:string}> {
  const key=Deno.env.get("OPENAI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: OPENAI_API_KEY is not configured");
  for(let attempt=0;attempt<3;attempt++){
    const {c,timer}=withTimeout(32_000);
    try{
      const res=await fetch("https://api.openai.com/v1/responses",{
        method:"POST",signal:c.signal,
        headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},
        body:JSON.stringify({
          model:LUNA_MODEL,
          reasoning:{effort:"low"},
          max_output_tokens:1800,
          instructions,
          input:JSON.stringify(input),
          text:{format:{type:"json_schema",name:"english_luna_quality",strict:true,schema}},
        }),
      });
      const payload=await res.json().catch(()=>null);
      if(res.ok){
        const text=openaiOutputText(payload);
        if(!text)throw new Error("LUNA_MALFORMED_OUTPUT: no JSON text returned");
        return {data:parseJsonText(text,"LUNA") as T,provider:"openai",model:String(payload?.model||LUNA_MODEL)};
      }
      if(!TRANSIENT.has(res.status)||attempt===2)throw new Error(`LUNA_${res.status}: ${payload?.error?.message||"request failed"}`);
    }catch(e:any){
      if(e?.name==="AbortError"){
        if(attempt===2)throw new Error("LUNA_TIMEOUT");
      }else if(!/^LUNA_(429|500|502|503|504):/.test(errorText(e))){
        throw e;
      }else if(attempt===2)throw e;
    }finally{clearTimeout(timer)}
    await sleep(700*(attempt+1));
  }
  throw new Error("LUNA_RETRY_EXHAUSTED");
}

export async function geminiRareRescueJson<T>(instructions:string,input:unknown,schema:unknown):Promise<{data:T;provider:"gemini";model:string}> {
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const {c,timer}=withTimeout(45_000);
  try{
    const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_RARE_RESCUE_MODEL)}:generateContent`,{
      method:"POST",signal:c.signal,
      headers:{"x-goog-api-key":key,"Content-Type":"application/json"},
      body:JSON.stringify({
        systemInstruction:{parts:[{text:`${instructions}\nYou are the rare specialist rescue model. Fix only the remaining critic defects while preserving the assigned concept, sense, family and learner intent. Return the complete corrected item.`}]},
        contents:[{role:"user",parts:[{text:JSON.stringify(input)}]}],
        generationConfig:{responseMimeType:"application/json",responseJsonSchema:schema,thinkingConfig:{thinkingLevel:"high"}},
      }),
    });
    const payload=await res.json().catch(()=>null);
    if(!res.ok)throw new Error(`GEMINI_RESCUE_${res.status}: ${payload?.error?.message||"request failed"}`);
    const text=(payload?.candidates?.[0]?.content?.parts||[]).map((p:any)=>typeof p?.text==="string"&&!p?.thought?p.text:"").join("").trim();
    if(!text)throw new Error("GEMINI_RESCUE_MALFORMED_OUTPUT");
    return {data:parseJsonText(text,"GEMINI_RESCUE") as T,provider:"gemini",model:GEMINI_RARE_RESCUE_MODEL};
  }finally{clearTimeout(timer)}
}

const criticInstructions=`You are Luna, the independent QUALITY CRITIC for one SSC CGL English learning item. Another model wrote the item. Judge only; do not rewrite it. Use low reasoning efficiently but inspect every supplied field. PASS is allowed only when score >=85 and every hard gate is true. REPAIR means the item is fundamentally usable but has specific repairable defects. REJECT means the item is unsafe, concept-drifted, factually/lexically unreliable, structurally incompatible, or fundamentally ambiguous. Verify exactly one defensible answer, correct key, natural English/collocation, learner intent, concept and sense preservation, plausible non-obvious distractors, and explanation consistency. For Phrasal context-fill, verify the intended sense and natural sentence context. For Reverse Recall, the target must remain hidden on the front and the legacy self-assessment contract must be preserved. Return concise issues and one precise repairInstruction; never expose chain-of-thought.`;

export async function lunaCritic(item:unknown,context:unknown):Promise<{quality:LunaQuality;provider:"openai";model:string}> {
  const out=await lunaJson<LunaQuality>(criticInstructions,{item,context},lunaQualitySchema);
  return {quality:out.data,provider:out.provider,model:out.model};
}
export function lunaPass(q:LunaQuality){
  return q.score>=85&&q.decision==="PASS"&&Object.values(q.hardGates||{}).every(Boolean);
}

export function fourOptionCodeGate(item:any,keyField="correctKey"):string[]{
  const issues:string[]=[];
  const options=["A","B","C","D"].map(k=>String(item?.[`option${k}`]||"").trim());
  if(options.some(x=>!x))issues.push("all four options must be nonblank");
  if(new Set(options.map(x=>x.toLowerCase())).size!==4)issues.push("all four options must be distinct");
  const key=String(item?.[keyField]||"").toUpperCase();
  if(!["A","B","C","D"].includes(key))issues.push(`${keyField} must be A/B/C/D`);
  if(!String(item?.question||"").trim())issues.push("question is blank");
  if(!String(item?.explanation||"").trim())issues.push("explanation is blank");
  return issues;
}

export async function runAntigravityLunaPipeline<T>(args:{
  instructions:string;
  input:unknown;
  schema:unknown;
  criticContext:unknown;
  structuralGate:(item:T)=>string[];
  repairInput?:(original:unknown,current:T,quality:LunaQuality|{decision:"CODE";issues:string[];repairInstruction:string})=>unknown;
}):Promise<{
  item:T;quality:LunaQuality;repairCount:number;codeRepairCount:number;
  generatorProvider:string;generatorModel:string;criticProvider:string;criticModel:string;
  rareRescue:boolean;writerRequests:number;criticRequests:number;
}> {
  const mkRepair=(current:T,quality:any)=>args.repairInput
    ?args.repairInput(args.input,current,quality)
    :{originalAssignment:args.input,currentItem:current,critic:quality};

  let first=await antigravityJson<T>(args.instructions,args.input);
  let current=first.data;
  let finalProvider=first.provider as string,finalModel=first.model;
  let writerRequests=1,criticRequests=0,codeRepairCount=0;
  let codeIssues=args.structuralGate(current);
  if(codeIssues.length){
    codeRepairCount=1;writerRequests++;
    const repaired=await antigravityJson<T>(
      `${args.instructions}\nA deterministic code gate rejected the current item. Fix only these structural defects and return the complete corrected JSON item: ${codeIssues.join("; ")}`,
      mkRepair(current,{decision:"CODE",issues:codeIssues,repairInstruction:codeIssues.join("; ")}),
      {maxAttempts:1},
    );
    current=repaired.data;finalProvider=repaired.provider;finalModel=repaired.model;
    codeIssues=args.structuralGate(current);
    if(codeIssues.length)throw new Error(`CODE_GATE_REJECTED: ${codeIssues.join("; ")}`);
  }

  criticRequests++;
  let review=await lunaCritic(current,args.criticContext);
  if(lunaPass(review.quality))return {item:current,quality:review.quality,repairCount:0,codeRepairCount,generatorProvider:finalProvider,generatorModel:finalModel,criticProvider:review.provider,criticModel:review.model,rareRescue:false,writerRequests,criticRequests};
  if(review.quality.decision==="REJECT")throw new Error(`QUALITY_REJECTED: REJECT ${review.quality.score} ${review.quality.issues.join(" | ")}`);

  // First semantic repair stays with Antigravity.
  writerRequests++;
  const repaired=await antigravityJson<T>(
    `${args.instructions}\nThe independent Luna critic found repairable defects. Make the minimum targeted repair only; preserve everything not implicated by the critic. Return the complete corrected JSON item.`,
    mkRepair(current,review.quality),
    {maxAttempts:1},
  );
  current=repaired.data;finalProvider=repaired.provider;finalModel=repaired.model;
  codeIssues=args.structuralGate(current);
  if(codeIssues.length)throw new Error(`CODE_GATE_REJECTED_AFTER_REPAIR: ${codeIssues.join("; ")}`);
  criticRequests++;
  review=await lunaCritic(current,args.criticContext);
  if(lunaPass(review.quality))return {item:current,quality:review.quality,repairCount:1,codeRepairCount,generatorProvider:finalProvider,generatorModel:finalModel,criticProvider:review.provider,criticModel:review.model,rareRescue:false,writerRequests,criticRequests};
  if(review.quality.decision==="REJECT")throw new Error(`QUALITY_REJECTED: REJECT ${review.quality.score} ${review.quality.issues.join(" | ")}`);

  // Only a second Luna REPAIR reaches the rare Gemini 3.8 Flash HIGH rescue path.
  writerRequests++;
  const rescue=await geminiRareRescueJson<T>(args.instructions,mkRepair(current,review.quality),args.schema);
  current=rescue.data;finalProvider=rescue.provider;finalModel=rescue.model;
  codeIssues=args.structuralGate(current);
  if(codeIssues.length)throw new Error(`CODE_GATE_REJECTED_AFTER_RESCUE: ${codeIssues.join("; ")}`);
  criticRequests++;
  review=await lunaCritic(current,args.criticContext);
  if(!lunaPass(review.quality))throw new Error(`QUALITY_REJECTED_AFTER_RESCUE: ${review.quality.decision} ${review.quality.score} ${review.quality.issues.join(" | ")}`);
  return {item:current,quality:review.quality,repairCount:2,codeRepairCount,generatorProvider:finalProvider,generatorModel:finalModel,criticProvider:review.provider,criticModel:review.model,rareRescue:true,writerRequests,criticRequests};
}
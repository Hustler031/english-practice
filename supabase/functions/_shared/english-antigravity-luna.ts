// Server-only English writer/critic pipeline for My Saved + Phrasal.
// Hindu intentionally remains on its separate content-ingest path.
export const ANTIGRAVITY_AGENT = Deno.env.get("ANTIGRAVITY_AGENT") || "antigravity-preview-05-2026";
export const ANTIGRAVITY_MODEL = Deno.env.get("ANTIGRAVITY_MODEL") || "gemini-3.6-flash";
export const LUNA_MODEL = Deno.env.get("LUNA_MODEL") || "gpt-5.6-luna";
export const GEMINI_RARE_RESCUE_MODEL = Deno.env.get("GEMINI_RARE_RESCUE_MODEL") || "gemini-3.8-flash";
const ANTIGRAVITY_MAX_TOTAL_TOKENS = Math.max(8_000, Math.min(60_000, Number(Deno.env.get("ANTIGRAVITY_MAX_TOTAL_TOKENS")) || 40_000));
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
function providerRetryMs(res:Response,payload:any,fallback:number){
  let ms=Math.max(0,fallback);
  const header=String(res.headers.get("retry-after")||"").trim();
  if(/^\d+(?:\.\d+)?$/.test(header))ms=Math.max(ms,Number(header)*1000+250);
  const message=String(payload?.error?.message||"");
  const match=message.match(/retry in\s+([0-9.]+)\s*s/i);
  if(match)ms=Math.max(ms,Number(match[1])*1000+500);
  return Math.max(fallback,Math.min(65_000,Math.ceil(ms)));
}
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

async function serviceRpc(name:string,body:Record<string,unknown>={}){
  const url=String(Deno.env.get("SUPABASE_URL")||"").replace(/\/$/,"");
  const key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!key)throw new Error("AUTH_CONFIG: Supabase service configuration missing for AI budget guard");
  const {c,timer}=withTimeout(8_000);
  try{
    const res=await fetch(`${url}/rest/v1/rpc/${name}`,{
      method:"POST",signal:c.signal,
      headers:{apikey:key,Authorization:`Bearer ${key}`,"Content-Type":"application/json"},
      body:JSON.stringify(body),
    });
    const payload=await res.json().catch(()=>null);
    if(!res.ok)throw new Error(`AI_BUDGET_RPC_${res.status}: ${payload?.message||payload?.error||name}`);
    return payload;
  }finally{clearTimeout(timer)}
}
async function claimAntigravityBudget(){
  try{return await serviceRpc("english_claim_antigravity_request_budget")}
  catch(e){return {allowed:false,route:"gemini",reason:`BUDGET_GUARD_FAIL_CLOSED: ${errorText(e)}`}}
}
async function markAntigravityQuotaExhausted(reason:string){
  try{await serviceRpc("english_mark_antigravity_quota_exhausted",{p_reason:reason.slice(0,800)})}catch{/* fallback still proceeds */}
}

export async function antigravityJson<T>(instructions:string,input:unknown,opts:{maxAttempts?:number;schema?:unknown}={}):Promise<{data:T;provider:"antigravity";model:string}> {
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const maxAttempts=Math.max(1,Math.min(2,Number(opts.maxAttempts)||1));
  for(let attempt=0;attempt<maxAttempts;attempt++){
    const {c,timer}=withTimeout(95_000);
    let retryMs=800*(attempt+1);
    try{
      const res=await fetch("https://generativelanguage.googleapis.com/v1beta/interactions",{
        method:"POST",signal:c.signal,
        headers:{"x-goog-api-key":key,"Content-Type":"application/json","Api-Revision":"2026-05-20"},
        body:JSON.stringify({
          agent:ANTIGRAVITY_AGENT,
          input:JSON.stringify(input),
          system_instruction:`${instructions}\n\nWork carefully with high reasoning effort. This is a self-contained writing task: do not call browser, web, shell, code-execution, or filesystem tools. Use only the supplied assignment as the learning source. Return ONLY one complete valid JSON object and no markdown or commentary.`,
          response_format:opts.schema?{type:"text",mime_type:"application/json",schema:opts.schema}:undefined,
          environment:"remote",store:true,background:false,
          agent_config:{type:"antigravity",model:ANTIGRAVITY_MODEL,max_total_tokens:String(ANTIGRAVITY_MAX_TOTAL_TOKENS)},
        }),
      });
      const payload=await res.json().catch(()=>null);
      if(!res.ok&&TRANSIENT.has(res.status)&&attempt<maxAttempts-1)retryMs=providerRetryMs(res,payload,retryMs);
      if(res.ok){
        if(payload?.status&&payload.status!=="completed"){
          const u=payload?.usage||{};
          throw new Error(`ANTIGRAVITY_${String(payload.status).toUpperCase()}: total_tokens=${String(u.total_tokens??"unknown")} output_tokens=${String(u.total_output_tokens??"unknown")} thought_tokens=${String(u.total_thought_tokens??"unknown")}`);
        }
        const text=googleInteractionText(payload);
        if(!text)throw new Error("ANTIGRAVITY_MALFORMED_OUTPUT: no JSON text returned");
        return {data:parseJsonText(text,"ANTIGRAVITY") as T,provider:"antigravity",model:String(payload?.model||ANTIGRAVITY_MODEL)};
      }
      if(!TRANSIENT.has(res.status)||attempt===maxAttempts-1)throw new Error(`ANTIGRAVITY_${res.status}: ${payload?.error?.message||"request failed"}`);
    }catch(e:any){
      if(e?.name==="AbortError"){
        if(attempt===maxAttempts-1)throw new Error("ANTIGRAVITY_TIMEOUT");
      }else if(!/^ANTIGRAVITY_(429|500|502|503|504):/.test(errorText(e))){throw e}
      else if(attempt===maxAttempts-1)throw e;
    }finally{clearTimeout(timer)}
    await sleep(retryMs);
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
        body:JSON.stringify({model:LUNA_MODEL,reasoning:{effort:"low"},max_output_tokens:1800,instructions,input:JSON.stringify(input),text:{format:{type:"json_schema",name:"english_luna_quality",strict:true,schema}}}),
      });
      const payload=await res.json().catch(()=>null);
      if(res.ok){const text=openaiOutputText(payload);if(!text)throw new Error("LUNA_MALFORMED_OUTPUT: no JSON text returned");return {data:parseJsonText(text,"LUNA") as T,provider:"openai",model:String(payload?.model||LUNA_MODEL)}}
      if(!TRANSIENT.has(res.status)||attempt===2)throw new Error(`LUNA_${res.status}: ${payload?.error?.message||"request failed"}`);
    }catch(e:any){
      if(e?.name==="AbortError"){if(attempt===2)throw new Error("LUNA_TIMEOUT")}
      else if(!/^LUNA_(429|500|502|503|504):/.test(errorText(e))){throw e}
      else if(attempt===2)throw e;
    }finally{clearTimeout(timer)}
    await sleep(700*(attempt+1));
  }
  throw new Error("LUNA_RETRY_EXHAUSTED");
}

async function geminiJson<T>(instructions:string,input:unknown,schema:unknown,role:"writer"|"rescue"):Promise<{data:T;provider:"gemini";model:string}> {
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const maxAttempts=2;
  for(let attempt=0;attempt<maxAttempts;attempt++){
    const {c,timer}=withTimeout(55_000);
    let retryMs=1200*(attempt+1);
    try{
      const roleInstruction=role==="rescue"
        ?"You are the rare specialist rescue model. Fix only the remaining critic defects while preserving the assigned concept, sense, family and learner intent."
        :"You are the fallback writer because the primary Antigravity route is unavailable or budget-protected. Perform the same fixed assignment faithfully; do not broaden scope.";
      const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_RARE_RESCUE_MODEL)}:generateContent`,{
        method:"POST",signal:c.signal,
        headers:{"x-goog-api-key":key,"Content-Type":"application/json"},
        body:JSON.stringify({
          systemInstruction:{parts:[{text:`${instructions}\n${roleInstruction} Return the complete corrected JSON item only.`}]},
          contents:[{role:"user",parts:[{text:JSON.stringify(input)}]}],
          generationConfig:{responseMimeType:"application/json",responseJsonSchema:schema,thinkingConfig:{thinkingLevel:"high"}},
        }),
      });
      const payload=await res.json().catch(()=>null);
      if(!res.ok&&TRANSIENT.has(res.status)&&attempt<maxAttempts-1)retryMs=providerRetryMs(res,payload,retryMs);
      if(res.ok){
        const text=(payload?.candidates?.[0]?.content?.parts||[]).map((p:any)=>typeof p?.text==="string"&&!p?.thought?p.text:"").join("").trim();
        if(!text)throw new Error(`GEMINI_${role.toUpperCase()}_MALFORMED_OUTPUT`);
        return {data:parseJsonText(text,`GEMINI_${role.toUpperCase()}`) as T,provider:"gemini",model:GEMINI_RARE_RESCUE_MODEL};
      }
      if(!TRANSIENT.has(res.status)||attempt===maxAttempts-1)throw new Error(`GEMINI_${role.toUpperCase()}_${res.status}: ${payload?.error?.message||"request failed"}`);
    }catch(e:any){
      if(e?.name==="AbortError"){if(attempt===maxAttempts-1)throw new Error(`GEMINI_${role.toUpperCase()}_TIMEOUT`)}
      else if(!new RegExp(`^GEMINI_${role.toUpperCase()}_(429|500|502|503|504):`).test(errorText(e))){throw e}
      else if(attempt===maxAttempts-1)throw e;
    }finally{clearTimeout(timer)}
    await sleep(retryMs);
  }
  throw new Error(`GEMINI_${role.toUpperCase()}_RETRY_EXHAUSTED`);
}
export async function geminiRareRescueJson<T>(instructions:string,input:unknown,schema:unknown){return geminiJson<T>(instructions,input,schema,"rescue")}
export async function geminiFallbackWriterJson<T>(instructions:string,input:unknown,schema:unknown){return geminiJson<T>(instructions,input,schema,"writer")}

type SmartWriterResult<T>={data:T;provider:string;model:string;antigravityRequests:number;geminiRequests:number;fallback:boolean;fallbackReason:string};
async function smartWriterJson<T>(instructions:string,input:unknown,schema:unknown):Promise<SmartWriterResult<T>>{
  const budget=await claimAntigravityBudget();
  if(budget?.allowed!==true){
    const g=await geminiFallbackWriterJson<T>(instructions,input,schema);
    return {...g,antigravityRequests:0,geminiRequests:1,fallback:true,fallbackReason:String(budget?.reason||"ANTIGRAVITY_BUDGET_PROTECTED")};
  }
  try{
    const a=await antigravityJson<T>(instructions,input,{maxAttempts:1,schema});
    return {...a,antigravityRequests:1,geminiRequests:0,fallback:false,fallbackReason:""};
  }catch(e){
    const reason=errorText(e);
    const eligible=/^ANTIGRAVITY_(429|500|502|503|504):|^ANTIGRAVITY_TIMEOUT$|^ANTIGRAVITY_RETRY_EXHAUSTED$/.test(reason);
    if(!eligible)throw e;
    if(/^ANTIGRAVITY_429:/.test(reason))await markAntigravityQuotaExhausted(reason);
    const g=await geminiFallbackWriterJson<T>(instructions,input,schema);
    return {...g,antigravityRequests:1,geminiRequests:1,fallback:true,fallbackReason:reason};
  }
}

const criticInstructions=`You are Luna, the independent QUALITY CRITIC for one SSC CGL English learning item. Another model wrote the item. Judge only; do not rewrite it. Use low reasoning efficiently but inspect every supplied field. PASS is allowed only when score >=85 and every hard gate is true. REPAIR means the item is fundamentally usable but has specific repairable defects. REJECT means the item has serious defects, but the bounded pipeline may still send your precise issues to a repair writer before giving up. Verify exactly one defensible answer, correct key, natural English/collocation, learner intent, concept and sense preservation, plausible non-obvious distractors, and explanation consistency. For Phrasal context-fill, verify the intended sense and natural sentence context. For Reverse Recall, the target must remain hidden on the front and the legacy self-assessment contract must be preserved. Return concise issues and one precise repairInstruction; never expose chain-of-thought.`;

export async function lunaCritic(item:unknown,context:unknown):Promise<{quality:LunaQuality;provider:"openai";model:string}> {
  const out=await lunaJson<LunaQuality>(criticInstructions,{item,context},lunaQualitySchema);
  return {quality:out.data,provider:out.provider,model:out.model};
}
export function lunaPass(q:LunaQuality){return q.score>=85&&q.decision==="PASS"&&Object.values(q.hardGates||{}).every(Boolean)}

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
  instructions:string; input:unknown; schema:unknown; criticContext:unknown;
  structuralGate:(item:T)=>string[];
  initialItem?:T; initialGeneratorProvider?:string; initialGeneratorModel?:string;
  repairInput?:(original:unknown,current:T,quality:LunaQuality|{decision:"CODE";issues:string[];repairInstruction:string})=>unknown;
}):Promise<{
  item:T;quality:LunaQuality;repairCount:number;codeRepairCount:number;
  generatorProvider:string;generatorModel:string;criticProvider:string;criticModel:string;
  rareRescue:boolean;writerRequests:number;criticRequests:number;
  antigravityRequests:number;geminiWriterRequests:number;antigravityFallback:boolean;antigravityFallbackReason:string;
}> {
  const mkRepair=(current:T,quality:any)=>args.repairInput?args.repairInput(args.input,current,quality):{originalAssignment:args.input,currentItem:current,critic:quality};
  let current:T;
  let finalProvider:string,finalModel:string;
  let writerRequests=0,criticRequests=0,codeRepairCount=0,antigravityRequests=0,geminiWriterRequests=0;
  let antigravityFallback=false,antigravityFallbackReason="";

  const write=async(instructions:string,input:unknown)=>{
    const w=await smartWriterJson<T>(instructions,input,args.schema);
    writerRequests++;antigravityRequests+=w.antigravityRequests;geminiWriterRequests+=w.geminiRequests;
    if(w.fallback){antigravityFallback=true;antigravityFallbackReason=antigravityFallbackReason||w.fallbackReason}
    current=w.data;finalProvider=w.provider;finalModel=w.model;
  };
  const result=(quality:LunaQuality,review:any,repairCount:number,rareRescue:boolean)=>({
    item:current,quality,repairCount,codeRepairCount,generatorProvider:finalProvider,generatorModel:finalModel,
    criticProvider:review.provider,criticModel:review.model,rareRescue,writerRequests,criticRequests,
    antigravityRequests,geminiWriterRequests,antigravityFallback,antigravityFallbackReason,
  });
  const rescue=async(quality:any)=>{
    const r=await geminiRareRescueJson<T>(args.instructions,mkRepair(current,quality),args.schema);
    writerRequests++;geminiWriterRequests++;current=r.data;finalProvider=r.provider;finalModel=r.model;
  };

  if(args.initialItem!==undefined){
    current=args.initialItem;finalProvider=args.initialGeneratorProvider||"deterministic";finalModel=args.initialGeneratorModel||"canonical_transform";
  }else await write(args.instructions,args.input);

  let codeIssues=args.structuralGate(current);
  if(codeIssues.length){
    codeRepairCount=1;
    await write(`${args.instructions}\nA deterministic code gate rejected the current item. Fix only these structural defects and return the complete corrected JSON item: ${codeIssues.join("; ")}`,mkRepair(current,{decision:"CODE",issues:codeIssues,repairInstruction:codeIssues.join("; ")}));
    codeIssues=args.structuralGate(current);
    if(codeIssues.length){
      await rescue({decision:"CODE",issues:codeIssues,repairInstruction:codeIssues.join("; ")});
      codeIssues=args.structuralGate(current);
      if(codeIssues.length)throw new Error(`CODE_GATE_REJECTED_AFTER_RESCUE: ${codeIssues.join("; ")}`);
      criticRequests++;
      const rescuedReview=await lunaCritic(current,args.criticContext);
      if(!lunaPass(rescuedReview.quality))throw new Error(`QUALITY_REJECTED_AFTER_RESCUE: ${rescuedReview.quality.decision} ${rescuedReview.quality.score} ${rescuedReview.quality.issues.join(" | ")}`);
      return result(rescuedReview.quality,rescuedReview,2,true);
    }
  }

  criticRequests++;
  let review=await lunaCritic(current,args.criticContext);
  if(lunaPass(review.quality))return result(review.quality,review,0,false);

  // First Luna non-PASS (REPAIR or REJECT) returns to the primary writer route.
  await write(`${args.instructions}\nThe independent Luna critic found defects. Make the minimum targeted repair only; preserve the fixed concept, sense, family and learner intent. Return the complete corrected JSON item.`,mkRepair(current,review.quality));
  codeIssues=args.structuralGate(current);
  if(codeIssues.length){
    await rescue({decision:"CODE",issues:codeIssues,repairInstruction:codeIssues.join("; ")});
    codeIssues=args.structuralGate(current);
    if(codeIssues.length)throw new Error(`CODE_GATE_REJECTED_AFTER_RESCUE: ${codeIssues.join("; ")}`);
    criticRequests++;
    const rescuedReview=await lunaCritic(current,args.criticContext);
    if(!lunaPass(rescuedReview.quality))throw new Error(`QUALITY_REJECTED_AFTER_RESCUE: ${rescuedReview.quality.decision} ${rescuedReview.quality.score} ${rescuedReview.quality.issues.join(" | ")}`);
    return result(rescuedReview.quality,rescuedReview,2,true);
  }

  criticRequests++;
  review=await lunaCritic(current,args.criticContext);
  if(lunaPass(review.quality))return result(review.quality,review,1,false);

  // A second Luna non-PASS reaches Gemini 3.8 high-reasoning rescue exactly once.
  await rescue(review.quality);
  codeIssues=args.structuralGate(current);
  if(codeIssues.length)throw new Error(`CODE_GATE_REJECTED_AFTER_RESCUE: ${codeIssues.join("; ")}`);
  criticRequests++;
  review=await lunaCritic(current,args.criticContext);
  if(!lunaPass(review.quality))throw new Error(`QUALITY_REJECTED_AFTER_RESCUE: ${review.quality.decision} ${review.quality.score} ${review.quality.issues.join(" | ")}`);
  return result(review.quality,review,2,true);
}

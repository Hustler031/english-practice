// Server-only English content generation helper. Never import from browser code.
export const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") || "gemini-3.6-flash";
export const GROQ_MODEL = Deno.env.get("GROQ_MODEL") || "openai/gpt-oss-120b";
const AI_TIMEOUT_MS = 28_000;

export type HardGates = {
  exactlyOneCorrect:boolean; correctKeyMatches:boolean; linguisticallyValid:boolean;
  conceptPreserved:boolean; sensePreserved:boolean; learnerRequestPreserved:boolean;
  noFactualError:boolean; noLexicalGrammarError:boolean; fourNonblankOptions:boolean;
  explanationMatchesQuestion:boolean; explanationMatchesAnswer:boolean; noStaleExplanation:boolean;
  noAmbiguity:boolean; noSecondCorrectOption:boolean; intentSpecificTaskValid:boolean;
  questionFamilyValid:boolean; plausibleDistractors:boolean; distractorsNotObvious:boolean;
};
export type Quality = {score:number;decision:"PASS"|"PASS_WITH_MINOR_ISSUES"|"REVISE"|"REJECT";hardGates:HardGates;issues:string[];repairInstruction:string};

const gateProperties:Record<keyof HardGates,unknown>={
  exactlyOneCorrect:{type:"boolean"},correctKeyMatches:{type:"boolean"},linguisticallyValid:{type:"boolean"},
  conceptPreserved:{type:"boolean"},sensePreserved:{type:"boolean"},learnerRequestPreserved:{type:"boolean"},
  noFactualError:{type:"boolean"},noLexicalGrammarError:{type:"boolean"},fourNonblankOptions:{type:"boolean"},
  explanationMatchesQuestion:{type:"boolean"},explanationMatchesAnswer:{type:"boolean"},noStaleExplanation:{type:"boolean"},
  noAmbiguity:{type:"boolean"},noSecondCorrectOption:{type:"boolean"},intentSpecificTaskValid:{type:"boolean"},
  questionFamilyValid:{type:"boolean"},plausibleDistractors:{type:"boolean"},distractorsNotObvious:{type:"boolean"},
};
const gateKeys=Object.keys(gateProperties);
export const qualitySchema={
  type:"object",additionalProperties:false,
  required:["score","decision","hardGates","issues","repairInstruction"],
  properties:{
    score:{type:"number",minimum:0,maximum:100},
    decision:{type:"string",enum:["PASS","PASS_WITH_MINOR_ISSUES","REVISE","REJECT"]},
    hardGates:{type:"object",additionalProperties:false,properties:gateProperties,required:gateKeys},
    issues:{type:"array",items:{type:"string"},maxItems:12},
    repairInstruction:{type:"string"},
  },
};

function errorText(e:unknown){return e instanceof Error?e.message:String(e||"Unknown AI error")}
function withTimeout(){const c=new AbortController();const timer=setTimeout(()=>c.abort(),AI_TIMEOUT_MS);return {c,timer}}
function parseJsonText(text:string,label:string){try{return JSON.parse(text)}catch(e){throw new Error(`${label}_MALFORMED_JSON: ${errorText(e)}`)}}

export async function geminiJson<T>(instructions:string,input:unknown,schema:unknown,opts:{googleSearch?:boolean}={}):Promise<{data:T;model:string;grounding?:unknown}> {
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const {c,timer}=withTimeout();
  try{
    const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_MODEL)}:generateContent`,{
      method:"POST",signal:c.signal,
      headers:{"x-goog-api-key":key,"Content-Type":"application/json"},
      body:JSON.stringify({
        systemInstruction:{parts:[{text:instructions}]},
        contents:[{role:"user",parts:[{text:JSON.stringify(input)}]}],
        ...(opts.googleSearch?{tools:[{googleSearch:{}}]}:{}),
        generationConfig:{
          responseFormat:{text:{mimeType:"application/json",schema}},
        },
      }),
    });
    const payload=await res.json().catch(()=>null);
    if(!res.ok)throw new Error(`GEMINI_${res.status}: ${payload?.error?.message||"request failed"}`);
    const parts=payload?.candidates?.[0]?.content?.parts||[];
    const text=parts.map((p:any)=>typeof p?.text==="string"?p.text:"").join("").trim();
    if(!text)throw new Error("GEMINI_MALFORMED_OUTPUT: no JSON text returned");
    return {data:parseJsonText(text,"GEMINI") as T,model:GEMINI_MODEL,grounding:payload?.candidates?.[0]?.groundingMetadata};
  }catch(e:any){if(e?.name==="AbortError")throw new Error("GEMINI_TIMEOUT");throw e}finally{clearTimeout(timer)}
}

function groqOutputText(payload:any){
  if(typeof payload?.output_text==="string")return payload.output_text;
  for(const item of payload?.output||[])for(const c of item?.content||[])if(c?.type==="output_text"&&typeof c.text==="string")return c.text;
  return "";
}

export async function groqJson<T>(instructions:string,input:unknown,schema:unknown):Promise<{data:T;model:string}> {
  const key=Deno.env.get("GROQ_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GROQ_API_KEY is not configured");
  const {c,timer}=withTimeout();
  try{
    const res=await fetch("https://api.groq.com/openai/v1/responses",{
      method:"POST",signal:c.signal,
      headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},
      body:JSON.stringify({
        model:GROQ_MODEL,reasoning:{effort:"medium"},max_output_tokens:2200,
        instructions,input:JSON.stringify(input),
        text:{format:{type:"json_schema",name:"english_quality_decision",strict:true,schema}},
      }),
    });
    const payload=await res.json().catch(()=>null);
    if(!res.ok)throw new Error(`GROQ_${res.status}: ${payload?.error?.message||"request failed"}`);
    const text=groqOutputText(payload).trim();
    if(!text)throw new Error("GROQ_MALFORMED_OUTPUT: no JSON text returned");
    return {data:parseJsonText(text,"GROQ") as T,model:String(payload?.model||GROQ_MODEL)};
  }catch(e:any){if(e?.name==="AbortError")throw new Error("GROQ_TIMEOUT");throw e}finally{clearTimeout(timer)}
}

export function hardGatesPass(q:Quality){
  return q.score>=85 && (q.decision==="PASS"||q.decision==="PASS_WITH_MINOR_ISSUES")
    && Object.values(q.hardGates||{}).every(Boolean);
}

const criticInstructions=`You are an independent SSC CGL English content critic. The content was written by another model. Do not defer to its claims. Verify the actual stem, four options, answer and explanation. Score honestly; average material is not automatically 95. PASS or PASS_WITH_MINOR_ISSUES is allowed only at score >=85 and only if every hard gate is true. REVISE for repairable defects; REJECT for unsafe, incoherent, factually unreliable, wrong-family or fundamentally ambiguous content. Distractors must be close enough that an SSC learner must know the concept, but exactly one answer must remain defensible. For explicit spelling intent verify it is really a spelling task. For a multi-word request verify the requested cluster is actually tested. For context-fill Phrasal items verify the intended sense and natural sentence context. Never expose chain-of-thought; issues and repairInstruction must be concise verdicts.`;

export async function critic(item:unknown,context:unknown):Promise<{quality:Quality;model:string}> {
  const out=await groqJson<Quality>(criticInstructions,{item,context},qualitySchema);
  return {quality:out.data,model:out.model};
}

export async function generateCriticRepair<T>(args:{
  instructions:string; input:unknown; schema:unknown; criticContext:unknown;
  googleSearch?:boolean; repairInput?:(original:unknown,current:T,quality:Quality)=>unknown;
}):Promise<{item:T;quality:Quality;repairCount:number;generatorModel:string;criticModel:string;grounding?:unknown}> {
  let generated=await geminiJson<T>(args.instructions,args.input,args.schema,{googleSearch:args.googleSearch});
  let current=generated.data;
  let review=await critic(current,args.criticContext);
  let repairs=0;
  while(!hardGatesPass(review.quality)&&review.quality.decision==="REVISE"&&repairs<2){
    repairs++;
    generated=await geminiJson<T>(
      args.instructions+"\nRepair only the critic-identified defects. Preserve the assigned concept, sense, family and learner intent. Return the complete corrected item.",
      args.repairInput?args.repairInput(args.input,current,review.quality):{originalAssignment:args.input,currentItem:current,critic:review.quality},
      args.schema,{googleSearch:false}
    );
    current=generated.data;
    review=await critic(current,args.criticContext);
  }
  if(!hardGatesPass(review.quality))throw new Error(`QUALITY_REJECTED: ${review.quality.decision} ${review.quality.score}`);
  return {item:current,quality:review.quality,repairCount:repairs,generatorModel:generated.model,criticModel:review.model,grounding:generated.grounding};
}

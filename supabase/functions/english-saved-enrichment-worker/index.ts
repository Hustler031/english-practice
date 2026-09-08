import { createClient } from "npm:@supabase/supabase-js@2";
import {
  ANTIGRAVITY_AGENT, LUNA_MODEL,
  fourOptionCodeGate, lunaCritic, lunaPass,
} from "../_shared/english-antigravity-luna.ts";

// Saved-only writer cascade. Phrasal remains untouched.
const SAVED_ANTIGRAVITY_MODEL = Deno.env.get("SAVED_ANTIGRAVITY_MODEL") || "gemini-3.8-flash";
const SAVED_GEMINI_36_MODEL = Deno.env.get("SAVED_GEMINI_36_MODEL") || "gemini-3.6-flash";
const SAVED_GEMINI_35_MODEL = Deno.env.get("SAVED_GEMINI_35_MODEL") || "gemini-3.5-flash";
const SAVED_GEMINI_35_LITE_MODEL = Deno.env.get("SAVED_GEMINI_35_LITE_MODEL") || "gemini-3.5-flash-lite";
const SAVED_ANTIGRAVITY_MAX_TOTAL_TOKENS = Math.max(
  8_000,
  Math.min(24_000, Number(Deno.env.get("SAVED_ANTIGRAVITY_MAX_TOTAL_TOKENS")) || 16_000),
);

const WRITER_CHAIN = [
  { provider: "antigravity", model: SAVED_ANTIGRAVITY_MODEL },
  { provider: "gemini", model: SAVED_GEMINI_36_MODEL },
  { provider: "gemini", model: SAVED_GEMINI_35_MODEL },
  { provider: "gemini", model: SAVED_GEMINI_35_LITE_MODEL },
] as const;
const DIRECT_MODELS = new Set([SAVED_GEMINI_36_MODEL, SAVED_GEMINI_35_MODEL, SAVED_GEMINI_35_LITE_MODEL]);

const cors={"Access-Control-Allow-Headers":"content-type, x-english-context-token","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown saved enrichment worker error");
const sleep=(ms:number)=>new Promise(resolve=>setTimeout(resolve,ms));
const SAVED_TYPES=["AUTO","V","SM","OWS","PV","IP","CU"] as const;
const RESOLVED_TYPES=["V","SM","OWS","PV","IP","CU"] as const;
const LEARNING_INTENTS=["AUTO","MEANING","USAGE","CONFUSION"] as const;
const REQUIRED_INTENTS=["MEANING","USAGE","CONFUSION"] as const;

const classifyError=(e:unknown)=>{
  const text=errorText(e);
  if(/(?:ANTIGRAVITY|LUNA|GEMINI|AI)_TIMEOUT|AbortError|timed?\s*out/i.test(text))return `AI_TIMEOUT: ${text}`;
  return text;
};
function withTimeout(ms:number){const c=new AbortController();const timer=setTimeout(()=>c.abort(),ms);return {c,timer}}
function parseJsonText(text:string,label:string){
  let raw=String(text||"").trim();
  raw=raw.replace(/^```(?:json)?\s*/i,"").replace(/\s*```$/i,"").trim();
  try{return JSON.parse(raw)}catch{}
  const start=raw.indexOf("{"),end=raw.lastIndexOf("}");
  if(start>=0&&end>start){try{return JSON.parse(raw.slice(start,end+1))}catch{}}
  throw new Error(`${label}_MALFORMED_JSON`);
}
function interactionText(payload:any){
  if(typeof payload?.output_text==="string"&&payload.output_text.trim())return payload.output_text.trim();
  const chunks:string[]=[];
  for(const step of payload?.steps||[]){
    if(step?.type!=="model_output")continue;
    for(const part of step?.content||[])if(part?.type==="text"&&typeof part?.text==="string")chunks.push(part.text);
  }
  return chunks.join("").trim();
}
function generateContentText(payload:any){
  return (payload?.candidates?.[0]?.content?.parts||[])
    .map((p:any)=>typeof p?.text==="string"&&!p?.thought?p.text:"")
    .join("")
    .trim();
}

async function featureEnabled(db:any,flag:string){
  let lastError="";
  for(let attempt=0;attempt<3;attempt++){
    const {data,error}=await db.rpc("english_ai_content_feature_enabled",{p_flag:flag});
    if(!error)return data===true;
    lastError=String(error.message||error);
    const transient=/(schema cache|retrying|temporar|timeout|connection|502|503|504)/i.test(lastError);
    if(!transient||attempt===2)throw new Error(`FEATURE_READ_FAILED: ${lastError}`);
    await sleep(250*(attempt+1));
  }
  throw new Error(`FEATURE_READ_FAILED: ${lastError||"unknown error"}`);
}
async function claimSaved(db:any,token:string,limit:number){
  let data:any=null,error:any=null;
  for(let attempt=0;attempt<3;attempt++){
    const out=await db.rpc("english_saved_enrichment_worker_claim",{p_token:token,p_limit:limit});
    data=out.data;error=out.error;
    if(!error)return {data,error:null};
    if(!/statement timeout/i.test(String(error.message||error))||attempt===2)return {data,error};
    await sleep(300*(attempt+1));
  }
  return {data,error};
}

// Use only JSON-Schema features supported by Gemini structured output.
// Semantic nonblank/distinct requirements stay in the deterministic gate and prompt.
const enrichmentSchema:any={
  type:"object",additionalProperties:false,
  required:["meaning","partOfSpeech","synonyms","antonyms","example","explanation","question","optionA","optionB","optionC","optionD","correctOption","captureType","gptStatus","needsReviewReason"],
  properties:{
    meaning:{type:"string",description:"Precise meaning or rule; never blank."},
    partOfSpeech:{type:"string",description:"Part of speech or grammar label; never blank."},
    synonyms:{type:"string",description:"Useful close synonyms; write 'None useful' only if genuinely unavailable."},
    antonyms:{type:"string",description:"Useful antonyms; write 'None useful' only if genuinely unavailable."},
    example:{type:"string",description:"One natural memorable example sentence; never blank."},
    explanation:{type:"string",description:"Explain A, B, C and D explicitly; never blank."},
    question:{type:"string",description:"One SSC-style MCQ stem; never blank."},
    optionA:{type:"string",description:"Nonblank plausible option A."},
    optionB:{type:"string",description:"Nonblank plausible option B."},
    optionC:{type:"string",description:"Nonblank plausible option C."},
    optionD:{type:"string",description:"Nonblank plausible option D."},
    correctOption:{type:"string",enum:["A","B","C","D"]},
    captureType:{type:"string",enum:["AUTO","V","SM","OWS","PV","IP","CU"]},
    gptStatus:{type:"string",enum:["Ready"]},
    needsReviewReason:{type:"string"},
  },
};

const SIMPLE_VOCAB_INSTRUCTIONS=`You write exactly ONE concise, authentic SSC CGL My Saved vocabulary item from the supplied assignment.

For a simple vocabulary target:
- Give the precise meaning, part of speech, useful close synonyms and useful antonyms.
- Give one natural memorable example sentence.
- Make ONE SSC-style MCQ that directly tests meaning, synonym or antonym. Do not overcomplicate it.
- A, B, C and D must all be nonblank, distinct and plausible lexical competitors. Exactly one answer must be defensible.
- Explanation must explicitly label A, B, C and D and state what each option means or why it fits/fails.
- Preserve captureType exactly and return gptStatus="Ready".
- No citations, tools, markdown or commentary. Return only the complete JSON object.`;

const GENERAL_INSTRUCTIONS=`You write exactly ONE SSC CGL My Saved English item from the supplied assignment.
Keep the learner's request intact and obey requiredQuestionFamily and requiredLearningIntent exactly.
- MEANING: test the actual lexical meaning/recall.
- USAGE: test natural usage, collocation, grammar or contextual fit.
- CONFUSION: keep all supplied confusable targets together in the same diagnostic MCQ.
- SM stays a spelling task; OWS stays one-word-substitution; PV stays phrasal verb; IP stays idiom/phrase; CU stays grammar/usage/confusable-rule.
Use four nonblank, distinct, plausible SSC-level options with exactly one defensible answer.
Explanation must explicitly label A, B, C and D and explain every option.
Preserve captureType exactly and return gptStatus="Ready".
No citations, tools, markdown or commentary. Return only the complete JSON object.`;

function normalizedCapture(item:any){
  const value=String(item?.captureType||"AUTO").toUpperCase();
  return (SAVED_TYPES as readonly string[]).includes(value)?value:"AUTO";
}
function requiredFamily(item:any){
  const capture=normalizedCapture(item);
  if(capture!=="AUTO")return capture;
  const resolved=String(item?.resolvedType||"V").toUpperCase();
  return (RESOLVED_TYPES as readonly string[]).includes(resolved)?resolved:"V";
}
function normalizedLearningIntent(item:any){
  const value=String(item?.learningIntent||"AUTO").toUpperCase();
  return (LEARNING_INTENTS as readonly string[]).includes(value)?value:"AUTO";
}
function requiredLearningIntent(item:any){
  const resolved=String(item?.requiredLearningIntent||"MEANING").toUpperCase();
  return (REQUIRED_INTENTS as readonly string[]).includes(resolved)?resolved:"MEANING";
}
function assignment(item:any){
  const capture=normalizedCapture(item),family=requiredFamily(item),learningIntent=normalizedLearningIntent(item),requiredIntent=requiredLearningIntent(item);
  return {
    savedId:String(item?.savedId||""),rawSavedRequest:item?.word,context:item?.context,
    originQuestionId:item?.originQuestionId,originTopic:item?.originTopic,originModule:item?.originModule,sourceContext:item?.source,
    captureType:capture,resolvedType:item?.resolvedType,requiredQuestionFamily:family,
    learningIntent,learningIntentOrigin:item?.learningIntentOrigin,requiredLearningIntent:requiredIntent,
    priorMeaning:item?.meaning,priorQuestion:item?.question,priorExplanation:item?.explanation
  };
}
function preserveCapture(item:any,data:any){const original=normalizedCapture(item);data.captureType=original;return original}
function explicitOptionCoverage(explanation:string){
  return ["A","B","C","D"].every(k=>new RegExp(`(?:option\\s+${k}\\b|(?:^|\\n)\\s*[-*]?\\s*${k}[).:])`,"i").test(explanation));
}
function simpleBareVocab(item:any){
  if(requiredFamily(item)!=="V"||requiredLearningIntent(item)!=="MEANING")return false;
  const raw=String(item?.word||"").trim();
  if(!raw||raw.length>70)return false;
  if(/[,/;]|\b(?:and|vs|versus|confus|difference|sentence|usage|use\s+kro|use\s+karo)\b/i.test(raw))return false;
  return raw.split(/\s+/).length<=3;
}
function familyIssues(item:any,data:any){
  const issues:string[]=[];
  const family=requiredFamily(item),intent=requiredLearningIntent(item);
  const question=String(data?.question||"").trim();
  const explanation=String(data?.explanation||"").trim();
  const spellingStem=/(spell|spelt|spelled|misspell|correctly\s+written|incorrectly\s+written)/i.test(question);

  if(family==="SM"){
    if(!spellingStem)issues.push("SM requires a spelling-family MCQ");
    const options=["A","B","C","D"].map(k=>String(data?.[`option${k}`]||"").trim()).filter(Boolean);
    if(intent!=="CONFUSION"&&options.length===4&&options.some(x=>x.split(/\s+/).length>3))issues.push("single-target SM options must be spelling candidates");
  }
  if(family==="V"&&spellingStem)issues.push("V requires semantic vocabulary practice, not spelling practice");
  if(family==="CU"){
    const signal=`${question} ${explanation}`;
    if(!/(grammar|usage|noun|verb|subject|agreement|singular|plural|article|determiner|pronoun|preposition|tense|voice|narration|reported|conditional|modifier|parallel|countable|uncountable|correct\s+usage|error|distinction|confus)/i.test(signal))issues.push("CU must explicitly test grammar/usage or a distinction");
  }
  if(simpleBareVocab(item)&&/(fill\s+in\s+the\s+blank|complete\s+the\s+sentence|given\s+sentence|underlined\s+word\s+in)/i.test(question))issues.push("simple V+MEANING must directly test lexical meaning/recall");
  if(intent==="CONFUSION"&&/(most\s+appropriate\s+(synonym|antonym)\s+of\s+the\s+given\s+word|synonym\s+of\s+the\s+given\s+word)/i.test(question))issues.push("CONFUSION must test supplied targets together");
  if(explanation&&!explicitOptionCoverage(explanation))issues.push("explanation must explicitly explain A, B, C and D");
  return issues;
}
function savedCodeGate(item:any,data:any){
  const issues=fourOptionCodeGate(data,"correctOption");
  if(!String(data?.meaning||"").trim())issues.push("meaning/rule is blank");
  if(!String(data?.partOfSpeech||"").trim())issues.push("partOfSpeech is blank");
  if(!String(data?.example||"").trim())issues.push("example is blank");
  if(data?.gptStatus!=="Ready")issues.push("gptStatus must be Ready");
  const capture=String(data?.captureType||"").toUpperCase(),original=normalizedCapture(item);
  if(!(SAVED_TYPES as readonly string[]).includes(capture))issues.push("captureType is invalid");
  if(capture!==original)issues.push(`captureType ${original} must be preserved exactly`);
  issues.push(...familyIssues(item,data));
  return issues;
}
function validateReady(item:any,data:any){return data?.gptStatus==="Ready"&&savedCodeGate(item,data).length===0}

type TierTrace={
  provider:string;model:string;status:string;
  error?:string;gateIssues?:string[];lunaScore?:number;lunaDecision?:string;
};
type WriterResult={data:any;provider:string;model:string;antigravityRequests:number;geminiWriterRequests:number};

async function antigravity38Json(instructions:string,input:any):Promise<WriterResult>{
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const {c,timer}=withTimeout(55_000);
  try{
    const res=await fetch("https://generativelanguage.googleapis.com/v1beta/interactions",{
      method:"POST",signal:c.signal,
      headers:{"x-goog-api-key":key,"Content-Type":"application/json","Api-Revision":"2026-05-20"},
      body:JSON.stringify({
        agent:ANTIGRAVITY_AGENT,
        input:JSON.stringify(input),
        system_instruction:`${instructions}\nUse efficient reasoning. This is a short English-learning writing task; do not call tools. Return only one complete JSON object.`,
        response_format:{type:"text",mime_type:"application/json",schema:enrichmentSchema},
        environment:"remote",store:true,background:false,
        agent_config:{type:"antigravity",model:SAVED_ANTIGRAVITY_MODEL,max_total_tokens:String(SAVED_ANTIGRAVITY_MAX_TOTAL_TOKENS)},
      }),
    });
    const payload=await res.json().catch(()=>null);
    if(!res.ok)throw new Error(`ANTIGRAVITY_${res.status}: ${payload?.error?.message||"request failed"}`);
    if(payload?.status&&payload.status!=="completed"){
      const u=payload?.usage||{};
      throw new Error(`ANTIGRAVITY_${String(payload.status).toUpperCase()}: total_tokens=${String(u.total_tokens??"unknown")} output_tokens=${String(u.total_output_tokens??"unknown")} thought_tokens=${String(u.total_thought_tokens??"unknown")}`);
    }
    const text=interactionText(payload);
    if(!text)throw new Error("ANTIGRAVITY_MALFORMED_OUTPUT");
    return {data:parseJsonText(text,"ANTIGRAVITY"),provider:"antigravity",model:String(payload?.model||SAVED_ANTIGRAVITY_MODEL),antigravityRequests:1,geminiWriterRequests:0};
  }catch(e:any){
    if(e?.name==="AbortError")throw new Error("ANTIGRAVITY_TIMEOUT");
    throw e;
  }finally{clearTimeout(timer)}
}

async function directGeminiJson(model:string,instructions:string,input:any):Promise<WriterResult>{
  const key=Deno.env.get("GEMINI_API_KEY");
  if(!key)throw new Error("AUTH_CONFIG: GEMINI_API_KEY is not configured");
  const {c,timer}=withTimeout(45_000);
  try{
    const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,{
      method:"POST",signal:c.signal,
      headers:{"x-goog-api-key":key,"Content-Type":"application/json"},
      body:JSON.stringify({
        systemInstruction:{parts:[{text:`${instructions}\nReturn only the complete JSON item.`}]},
        contents:[{role:"user",parts:[{text:JSON.stringify(input)}]}],
        generationConfig:{responseMimeType:"application/json",responseJsonSchema:enrichmentSchema},
      }),
    });
    const payload=await res.json().catch(()=>null);
    if(!res.ok)throw new Error(`GEMINI_${model}_${res.status}: ${payload?.error?.message||"request failed"}`);
    const text=generateContentText(payload);
    if(!text)throw new Error(`GEMINI_${model}_MALFORMED_OUTPUT`);
    return {data:parseJsonText(text,`GEMINI_${model}`),provider:"gemini",model,antigravityRequests:0,geminiWriterRequests:1};
  }catch(e:any){
    if(e?.name==="AbortError")throw new Error(`GEMINI_${model}_TIMEOUT`);
    throw e;
  }finally{clearTimeout(timer)}
}

async function runWriterTier(db:any,tier:{provider:string;model:string},instructions:string,input:any):Promise<WriterResult>{
  if(tier.provider==="antigravity"){
    const {data:budget,error}=await db.rpc("english_claim_antigravity_request_budget");
    if(error)throw new Error(`ANTIGRAVITY_BUDGET_SKIPPED: ${String(error.message||error)}`);
    if(budget?.allowed!==true)throw new Error(`ANTIGRAVITY_BUDGET_SKIPPED: ${String(budget?.reason||"budget protected")}`);
    try{return await antigravity38Json(instructions,input)}
    catch(e){
      const reason=errorText(e);
      if(/^ANTIGRAVITY_429:/.test(reason)){
        try{await db.rpc("english_mark_antigravity_quota_exhausted",{p_reason:reason.slice(0,800)})}catch{}
      }
      throw e;
    }
  }
  return await directGeminiJson(tier.model,instructions,input);
}

function readyOutput(item:any,data:any,reviewed:any){
  const capture=normalizedCapture(item),family=requiredFamily(item),requiredIntent=requiredLearningIntent(item);
  return {
    savedId:String(item?.savedId||""),meaning:String(data.meaning||""),partOfSpeech:String(data.partOfSpeech||""),synonyms:String(data.synonyms||""),antonyms:String(data.antonyms||""),example:String(data.example||""),
    explanation:String(data.explanation||""),question:String(data.question||""),optionA:String(data.optionA||""),optionB:String(data.optionB||""),optionC:String(data.optionC||""),optionD:String(data.optionD||""),correctOption:String(data.correctOption||"").toUpperCase(),
    source:`Supabase English AI My Saved enrichment · ${reviewed.generatorProvider}/${reviewed.generatorModel} · ${reviewed.criticModel}`,
    gptStatus:"Ready",captureType:capture,requiredQuestionFamily:family,requiredLearningIntent:requiredIntent,
    generatorProvider:reviewed.generatorProvider,generatorModel:reviewed.generatorModel,criticProvider:reviewed.criticProvider,criticModel:reviewed.criticModel,
    repairCount:reviewed.repairCount,quality:reviewed.quality,rareRescue:false,writerRequests:reviewed.writerRequests,criticRequests:reviewed.criticRequests,codeRepairCount:reviewed.codeRepairCount,
    antigravityRequests:reviewed.antigravityRequests,geminiWriterRequests:reviewed.geminiWriterRequests,antigravityFallback:reviewed.antigravityFallback,antigravityFallbackReason:reviewed.antigravityFallbackReason,
    writerTierTrace:reviewed.writerTierTrace,
  };
}

async function enrichOne(db:any,item:any,forceModel:string|null=null){
  const input=assignment(item),originalCapture=normalizedCapture(item),family=requiredFamily(item),requiredIntent=requiredLearningIntent(item);
  const criticContext={lane:"saved",rawLearnerRequest:input.rawSavedRequest,captureType:originalCapture,resolvedType:input.resolvedType,requiredQuestionFamily:family,requiredLearningIntent:requiredIntent,hardDistractors:true,explainAllOptions:true,clusterMustStayCombined:requiredIntent==="CONFUSION"};
  const baseInstructions=simpleBareVocab(item)?SIMPLE_VOCAB_INSTRUCTIONS:GENERAL_INSTRUCTIONS;
  const tiers=forceModel&&DIRECT_MODELS.has(forceModel)
    ? [{provider:"gemini",model:forceModel}]
    : WRITER_CHAIN.map(x=>({provider:x.provider,model:x.model}));

  let current:any=null,previousFeedback:any=null,finalProvider="",finalModel="",review:any=null;
  let writerRequests=0,criticRequests=0,codeRepairCount=0,antigravityRequests=0,geminiWriterRequests=0;
  const trace:TierTrace[]=[];

  for(let i=0;i<tiers.length;i++){
    const tier=tiers[i];
    const tierInput=i===0&&!previousFeedback
      ? input
      : {originalAssignment:input,previousCandidate:current,feedback:previousFeedback};
    const tierInstructions=previousFeedback
      ? `${baseInstructions}\nA previous writer did not pass validation. Fix only the listed feedback while keeping all valid content.`
      : baseInstructions;

    let written:WriterResult;
    try{
      written=await runWriterTier(db,tier,tierInstructions,tierInput);
      writerRequests++;antigravityRequests+=written.antigravityRequests;geminiWriterRequests+=written.geminiWriterRequests;
      current=written.data;finalProvider=written.provider;finalModel=written.model;preserveCapture(item,current);
    }catch(e){
      const err=classifyError(e);
      trace.push({provider:tier.provider,model:tier.model,status:"provider_error",error:err.slice(0,500)});
      previousFeedback={providerError:err};
      continue;
    }

    const codeIssues=savedCodeGate(item,current);
    if(codeIssues.length){
      codeRepairCount++;
      trace.push({provider:written.provider,model:written.model,status:"code_reject",gateIssues:codeIssues});
      previousFeedback={decision:"CODE",issues:codeIssues,repairInstruction:codeIssues.join("; ")};
      continue;
    }

    criticRequests++;
    try{review=await lunaCritic(current,criticContext)}
    catch(e){
      // Do not burn more writer tiers when the shared critic itself is unavailable.
      throw new Error(classifyError(e));
    }
    const score=Number(review?.quality?.score||0),decision=String(review?.quality?.decision||"");
    trace.push({provider:written.provider,model:written.model,status:lunaPass(review.quality)?"pass":"critic_reject",lunaScore:score,lunaDecision:decision});
    if(lunaPass(review.quality)&&validateReady(item,current)){
      const firstFallback=trace.find(x=>x.status==="provider_error"||x.status==="code_reject"||x.status==="critic_reject");
      return readyOutput(item,current,{
        generatorProvider:finalProvider,generatorModel:finalModel,criticProvider:review.provider,criticModel:review.model,
        repairCount:Math.max(0,writerRequests-1),quality:review.quality,writerRequests,criticRequests,codeRepairCount,
        antigravityRequests,geminiWriterRequests,antigravityFallback:finalProvider!=="antigravity",
        antigravityFallbackReason:firstFallback?`${firstFallback.model}:${firstFallback.status}`:"",
        writerTierTrace:trace,
      });
    }
    previousFeedback={decision:review.quality.decision,issues:review.quality.issues,repairInstruction:review.quality.repairInstruction};
  }

  const summary=trace.map(x=>`${x.model}:${x.status}${x.lunaScore!==undefined?`:${x.lunaScore}`:""}`).join(" | ");
  throw new Error(`SAVED_CASCADE_EXHAUSTED: temporarily unavailable: ${summary.slice(0,1000)}`);
}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return reply({error:"Method not allowed"},405);
  const token=String(req.headers.get("x-english-context-token")||"").trim();if(!token)return reply({error:"Unauthorized"},401);
  const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");if(!url||!serviceKey)return reply({error:"Supabase service configuration missing"},503);
  const db=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  try{
    if(!await featureEnabled(db,"antigravity_writer_v1")||!await featureEnabled(db,"luna_critic_v1"))return reply({error:"AI_PIPELINE_DISABLED: Saved writer/Luna flags are not enabled"},503);
  }catch(e){return reply({error:errorText(e)},500)}

  let body:any={};try{body=await req.json()}catch{body={}}
  const limit=Math.max(1,Math.min(10,Number(body?.limit)||1)),started=Date.now();
  const forceModel=typeof body?.forceModel==="string"&&DIRECT_MODELS.has(body.forceModel)?body.forceModel:null;
  const {data:claim,error:claimError}=await claimSaved(db,token,limit);
  if(claimError)return reply({error:claimError.message},/unauthorized/i.test(claimError.message)?401:500);
  if(claim?.busy)return reply({ok:true,busy:true,claimed:0,processed:0,failed:0,elapsedMs:Date.now()-started});
  const leaseId=String(claim?.leaseId||""),items=Array.isArray(claim?.items)?claim.items:[];
  if(!items.length)return reply({ok:true,claimed:0,processed:0,failed:0,elapsedMs:Date.now()-started});
  if(!leaseId)return reply({error:"Saved enrichment worker claim returned items without a lease"},500);

  const settled=await Promise.allSettled(items.map((item:any)=>enrichOne(db,item,forceModel)));
  const completed:any[]=[],failures:string[]=[];
  settled.forEach((r,i)=>r.status==="fulfilled"?completed.push(r.value):failures.push(`${String(items[i]?.savedId||"unknown")}: ${classifyError(r.reason)}`));

  try{
    if(completed.length){
      const {error}=await db.rpc("english_saved_enrichment_worker_apply",{p_token:token,p_lease_id:leaseId,p_items:completed});
      if(error)throw new Error(`APPLY_FAILED: ${error.message}`);
      const auditPayload=completed.map(x=>({
        lane:"saved",entityKey:x.savedId,generatorProvider:String(x.generatorProvider||"unknown"),generatorModel:String(x.generatorModel||"unknown"),criticProvider:String(x.criticProvider||"openai"),criticModel:String(x.criticModel||LUNA_MODEL),qualityScore:Number(x?.quality?.score||0),criticDecision:String(x?.quality?.decision||""),repairCount:Number(x?.repairCount||0),questionFamily:String(x.requiredQuestionFamily||""),publicationResult:"applied",
        metadata:{
          requestMode:"saved_four_tier_simple_cascade",writer:String(x.generatorProvider||"unknown"),writerChain:WRITER_CHAIN.map(t=>t.model),
          critic:"luna",criticReasoning:"low",lunaModel:LUNA_MODEL,writerRequests:Number(x.writerRequests||1),criticRequests:Number(x.criticRequests||1),
          codeRepairCount:Number(x.codeRepairCount||0),antigravityRequests:Number(x.antigravityRequests||0),geminiWriterRequests:Number(x.geminiWriterRequests||0),
          antigravityFallback:x.antigravityFallback===true,antigravityFallbackReason:String(x.antigravityFallbackReason||""),
          requiredLearningIntent:String(x.requiredLearningIntent||""),hardDistractors:true,explainAllOptions:true,writerTierTrace:x.writerTierTrace||[],
        }
      }));
      const {error:auditError}=await db.rpc("english_record_content_generation_audits",{p_items:auditPayload});
      if(auditError)throw new Error(`AUDIT_FAILED: ${auditError.message}`);
    }

    const ids=completed.map(x=>x.savedId);
    const {data:verified,error:finishError}=await db.rpc("english_saved_enrichment_worker_finish",{p_token:token,p_lease_id:leaseId,p_saved_ids:ids,p_error:failures.length?failures.slice(0,4).join(" | ").slice(0,1200):null});
    if(finishError)throw new Error(`VERIFY_FAILED: ${finishError.message}`);
    const verifyItems=Array.isArray(verified?.items)?verified.items:[];
    for(const row of verifyItems)if(String(row?.gptStatus||"").toLowerCase()==="ready"&&row?.questionReady!==true)throw new Error(`VERIFY_FAILED: Ready item ${String(row?.savedId||"unknown")} is not question-ready`);
    return reply({
      ok:true,generator:"saved-four-tier-cascade",
      writerChain:WRITER_CHAIN.map(t=>`${t.provider}:${t.model}`),forceModel,
      critic:"luna",criticModel:LUNA_MODEL,criticReasoning:"low",
      singleFlight:true,maxOneCallPerWriterTier:true,
      claimed:items.length,processed:completed.length,failed:failures.length,verified:verifyItems.length,elapsedMs:Date.now()-started
    });
  }catch(e){
    const classified=classifyError(e);
    try{await db.rpc("english_saved_enrichment_worker_finish",{p_token:token,p_lease_id:leaseId,p_saved_ids:[],p_error:classified.slice(0,1200)})}catch{}
    return reply({error:classified,claimed:items.length,processed:0,failed:items.length},500);
  }
});

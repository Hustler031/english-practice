import { createClient } from "npm:@supabase/supabase-js@2";
import { LUNA_MODEL } from "../_shared/english-antigravity-luna.ts";

const cors={"Access-Control-Allow-Headers":"content-type, x-english-context-token","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown Sprint critic worker error");

const checkNames=[
  "exactly25","exactlyOneDefensibleAnswer","sscCglLevel","difficultyCalibration","distractorQuality",
  "noHistoricalRepeat","noWithinSetSemanticDuplicate","factualAccuracy","naturalEnglish",
] as const;

const itemVerdict={
  type:"object",additionalProperties:false,
  required:["position","verdict","pass","sscLevelFit","difficultyFit","singleAnswer","distractorsStrong","factual","fresh","semanticDistinct","note"],
  properties:{
    position:{type:"integer",minimum:1,maximum:25},
    verdict:{type:"string",enum:["PASS","REPAIR"]},
    pass:{type:"boolean"},sscLevelFit:{type:"boolean"},difficultyFit:{type:"boolean"},singleAnswer:{type:"boolean"},
    distractorsStrong:{type:"boolean"},factual:{type:"boolean"},fresh:{type:"boolean"},semanticDistinct:{type:"boolean"},
    note:{type:"string",maxLength:360},
  },
};
const issue={
  type:"object",additionalProperties:false,
  required:["position","severity","code","message"],
  properties:{
    position:{type:"integer",minimum:0,maximum:25},
    severity:{type:"string",enum:["critical","major","minor"]},
    code:{type:"string",enum:["ANSWER","AMBIGUITY","FACT","GRAMMAR","DISTRACTOR","DIFFICULTY","SSC_LEVEL","HISTORICAL_REPEAT","SEMANTIC_DUPLICATE","NATURALNESS","STRUCTURE","OTHER"]},
    message:{type:"string",maxLength:420},
  },
};
const reportSchema={
  type:"object",additionalProperties:false,
  required:["decision","score","summary","setChecks","itemVerdicts","repairPositions","issues"],
  properties:{
    decision:{type:"string",enum:["PASS","REPAIR","REJECT_GLOBAL"]},
    score:{type:"number",minimum:0,maximum:100},
    summary:{type:"string",maxLength:900},
    setChecks:{type:"object",additionalProperties:false,required:[...checkNames],properties:Object.fromEntries(checkNames.map(k=>[k,{type:"boolean"}]))},
    itemVerdicts:{type:"array",minItems:25,maxItems:25,items:itemVerdict},
    repairPositions:{type:"array",maxItems:25,uniqueItems:true,items:{type:"integer",minimum:1,maximum:25}},
    issues:{type:"array",maxItems:35,items:issue},
  },
};

const instructions=`You are Luna, the independent FINAL PRE-SERVE CRITIC for one 25-question SSC CGL English Sprint. ChatGPT generated and self-critiqued the draft before you; do not trust that self-review blindly. Audit the complete 25-question set together in ONE pass so you can detect cross-question repetition, semantic overlap, difficulty balance and answer-pattern problems.

IMPORTANT WORKFLOW: judge EACH QUESTION independently. Do not reject the entire set because one or several isolated questions are defective. Mark an isolated bad question REPAIR and put its position in repairPositions. ChatGPT will replace ONLY those positions; all PASS positions are frozen. The repaired full set will then return to you for another complete 25-question audit.

Use REJECT_GLOBAL only for a genuinely non-isolatable structural failure, such as not actually having 25 usable items or a set-wide corruption that cannot be fixed by replacing identified positions. If a problem can be localized to one or more positions, decision must be REPAIR, not REJECT_GLOBAL.

The learner is strong and is using this as a 15-minute SSC CGL exam simulation. Final PASS requires the complete set to be safe, exam-realistic and worth serving.

Checks:
1. Exactly 25 questions and exactly one defensible correct answer per question.
2. Factual, lexical and grammatical accuracy; explanation must match stem, options and answer.
3. Real SSC CGL level. Easy may be direct, Moderate must require genuine discrimination, Hard must not be a basic rule with an inflated label. Do not reward artificial obscurity or GRE/CAT vocabulary.
4. Distractors: for Moderate/Hard, normally at least 2-3 options must be plausible enough to require processing. Obvious unrelated distractors are a defect.
5. No Reading Comprehension, cloze passage or passage-dependent question.
6. Historical freshness: historicalItems are questions already served in earlier completed Standard sets. Mark verbatim repeats and trivial/light rephrasings REPAIR. A concept may reappear only as genuinely different transfer when pedagogically justified.
7. Within-set semantic diversity: detect duplicate concepts even when conceptKey names differ. Example: testing PRECLUDE once and then PRECLUDE-vs-PROVOKE again in the same set is semantic overlap unless materially different. Mark the later/weaker redundant item REPAIR where possible rather than wasting both.
8. Natural standard English and SSC-style wording.
9. Be especially alert to over-specific or misleading OWS/idiom definitions, modifier attachment, fixed prepositions, voice/narration tense equivalence, and multiple-answer vocabulary items.

For every item return exactly one verdict: PASS or REPAIR. A PASS item must have every item boolean true. A REPAIR item must have pass=false and at least one relevant boolean false. repairPositions must exactly identify the positions that need replacement.

Do not rewrite questions yourself. You are the critic; ChatGPT performs the targeted repair. Return concise defect notes, not hidden reasoning.`;

function outputText(payload:any){
  if(typeof payload?.output_text==="string")return payload.output_text;
  const chunks:string[]=[];
  for(const item of payload?.output||[])for(const part of item?.content||[])if(part?.type==="output_text"&&typeof part?.text==="string")chunks.push(part.text);
  return chunks.join("");
}

async function runLuna(input:unknown){
  const key=Deno.env.get("OPENAI_API_KEY");
  if(!key)throw new Error("OPENAI_API_KEY is not configured for Sprint Luna critic");
  const ctrl=new AbortController();const timer=setTimeout(()=>ctrl.abort(),75_000);
  try{
    const res=await fetch("https://api.openai.com/v1/responses",{
      method:"POST",signal:ctrl.signal,
      headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},
      body:JSON.stringify({
        model:LUNA_MODEL,reasoning:{effort:"medium"},max_output_tokens:7000,
        instructions,input:JSON.stringify(input),
        text:{format:{type:"json_schema",name:"english_sprint_luna_questionwise_critic",strict:true,schema:reportSchema}},
      }),
    });
    const payload=await res.json();
    if(!res.ok)throw new Error(payload?.error?.message||`Luna Sprint critic failed (${res.status})`);
    const text=outputText(payload);if(!text)throw new Error("Luna Sprint critic returned no structured output");
    return {report:JSON.parse(text),model:String(payload?.model||LUNA_MODEL),usage:payload?.usage||{}};
  }catch(e:any){if(e?.name==="AbortError")throw new Error("Luna Sprint critic timed out");throw e}
  finally{clearTimeout(timer)}
}

function itemPass(x:any){
  return String(x?.verdict||"").toUpperCase()==="PASS"&&x?.pass===true&&x?.sscLevelFit===true&&x?.difficultyFit===true&&x?.singleAnswer===true&&x?.distractorsStrong===true&&x?.factual===true&&x?.fresh===true&&x?.semanticDistinct===true;
}

function deterministicNormalize(report:any){
  const verdicts=Array.isArray(report?.itemVerdicts)?report.itemVerdicts:[];
  const positions=new Set(verdicts.map((x:any)=>Number(x?.position)).filter((n:number)=>Number.isInteger(n)&&n>=1&&n<=25));
  const malformed=verdicts.length!==25||positions.size!==25;
  const checks=report?.setChecks||{};
  const score=Number(report?.score)||0;
  const repairSet=new Set<number>();
  if(!malformed){
    for(const x of verdicts)if(!itemPass(x))repairSet.add(Number(x.position));
  }
  for(const raw of Array.isArray(report?.repairPositions)?report.repairPositions:[]){
    const n=Number(raw);if(Number.isInteger(n)&&n>=1&&n<=25)repairSet.add(n);
  }
  const repairs=[...repairSet].sort((a,b)=>a-b);
  const everyCheck=checkNames.every(k=>checks?.[k]===true);
  const allItems=!malformed&&repairs.length===0&&verdicts.every(itemPass);
  const exactly25=checks?.exactly25===true&&!malformed;

  let decision:"PASS"|"REPAIR"|"REJECT_GLOBAL";
  if(exactly25&&allItems&&everyCheck&&score>=90)decision="PASS";
  else if(exactly25&&repairs.length>0)decision="REPAIR";
  else decision="REJECT_GLOBAL";

  return {...report,decision,score,repairPositions:repairs};
}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return reply({error:"Method not allowed"},405);
  const token=String(req.headers.get("x-english-context-token")||"").trim();
  if(!token)return reply({error:"Unauthorized"},401);
  const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!serviceKey)return reply({error:"Supabase service configuration missing"},503);
  const db=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  let body:any={};try{body=await req.json()}catch{body={}}
  const sessionId=String(body?.sessionId||"").trim();
  if(!sessionId)return reply({error:"sessionId is required"},400);

  const {data:claim,error:claimError}=await db.rpc("english_sprint_critic_worker_claim",{p_token:token,p_session_id:sessionId});
  if(claimError)return reply({error:claimError.message},/unauthorized/i.test(claimError.message)?401:500);
  if(claim?.claimed!==true)return reply({ok:true,claimed:false,reason:claim?.reason||"not_pending"});

  try{
    const luna=await runLuna({
      assignment:"Independent question-wise pre-serve audit of one ChatGPT-prepared SSC Standard set",
      workflow:"Full 25 context; PASS good positions; REPAIR only defective positions; global reject only if non-isolatable",
      blueprint:claim?.blueprint||{},selfCritic:claim?.selfCritic||{},repairRound:Number(claim?.repairRound)||0,
      items:claim?.items||[],historicalItems:claim?.historicalItems||[],
    });
    const report=deterministicNormalize(luna.report);
    report.criticModel=luna.model;
    report.criticProvider="openai";
    report.fullSet=true;
    report.questionWise=true;
    report.usage={inputTokens:Number(luna.usage?.input_tokens)||0,outputTokens:Number(luna.usage?.output_tokens)||0,totalTokens:Number(luna.usage?.total_tokens)||0};
    const {data:applied,error:applyError}=await db.rpc("english_sprint_critic_worker_apply",{p_token:token,p_session_id:sessionId,p_report:report});
    if(applyError)throw new Error(`Sprint critic apply failed: ${applyError.message}`);
    return reply({ok:true,claimed:true,decision:report.decision,score:report.score,repairPositions:report.repairPositions,setNo:applied?.setNo??null,status:applied?.status||null,criticStatus:applied?.criticStatus||null,repairRound:applied?.repairRound??claim?.repairRound??0,criticModel:luna.model});
  }catch(e){
    const message=errorText(e);
    try{await db.rpc("english_sprint_critic_worker_error",{p_token:token,p_session_id:sessionId,p_error:message})}catch{}
    return reply({error:message},500);
  }
});

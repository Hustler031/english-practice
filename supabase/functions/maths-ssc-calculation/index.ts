import { createClient } from "npm:@supabase/supabase-js@2";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
};
const model="gpt-5.6-luna";
const TIMEOUT=52000;
const SKILLS=["FractionsPercentages","SquaresRoots","CubesRoots","TablesMultiplication","DivisionCancellation","ApproxSimplify","NumberSpeed","RatioProportion","SSCMixed"] as const;
const reply=(body:any,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});

function outputText(p:any){if(typeof p?.output_text==="string")return p.output_text;for(const i of p?.output||[])for(const c of i?.content||[])if(c?.type==="output_text")return c.text||"";return "";}
function usage(p:any){const u=p?.usage||{};return {input:+u.input_tokens||0,output:+u.output_tokens||0,reasoning:+u.output_tokens_details?.reasoning_tokens||0,total:+u.total_tokens||0};}
async function ai(name:string,schema:any,instructions:string,input:any,effort:"low"|"medium"="low"){
  const key=Deno.env.get("OPENAI_API_KEY");if(!key)throw new Error("OPENAI_API_KEY is not configured for maths-ssc-calculation");
  const ctrl=new AbortController();const timer=setTimeout(()=>ctrl.abort(),TIMEOUT);
  try{
    const r=await fetch("https://api.openai.com/v1/responses",{method:"POST",signal:ctrl.signal,headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},body:JSON.stringify({
      model,reasoning:{effort},max_output_tokens:14000,instructions,input:JSON.stringify(input),text:{format:{type:"json_schema",name,strict:true,schema}},
    })});
    const p=await r.json();if(!r.ok)throw new Error(p?.error?.message||`OpenAI request failed (${r.status})`);
    const t=outputText(p);if(!t)throw new Error("OpenAI returned no structured output");
    return {data:JSON.parse(t),usage:usage(p),responseId:String(p?.id||""),model:String(p?.model||model)};
  }catch(e:any){if(e?.name==="AbortError")throw new Error("Calculation quality pass timed out safely. Please retry.");throw e;}finally{clearTimeout(timer)}
}
async function log(s:any,g:string,type:string,r:any,sid:string|null=null,meta:any={}){try{await s.rpc("maths_log_calculation_ai_usage",{
  p_request_group:g,p_request_type:type,p_model:r.model,p_input_tokens:r.usage.input,p_output_tokens:r.usage.output,
  p_reasoning_tokens:r.usage.reasoning,p_total_tokens:r.usage.total,p_response_id:r.responseId||null,p_session_id:sid,p_metadata:meta,
});}catch{}}

const option={type:"object",additionalProperties:false,required:["key","text"],properties:{key:{type:"string",enum:["A","B","C","D"]},text:{type:"string",minLength:1}}};
const item={type:"object",additionalProperties:false,required:["itemKey","skill","patternKey","question","options","correctKey","answerText","explanation","expectedSec","difficulty","trapTested","verification","qualityScore","ambiguous","sourceType"],properties:{
  itemKey:{type:"string",minLength:1},skill:{type:"string",enum:SKILLS},patternKey:{type:"string",minLength:2},question:{type:"string",minLength:2},
  options:{type:"array",minItems:4,maxItems:4,items:option},correctKey:{type:"string",enum:["A","B","C","D"]},answerText:{type:"string",minLength:1},
  explanation:{type:"string",minLength:4},expectedSec:{type:"integer",minimum:5,maximum:40},difficulty:{type:"string",enum:["Moderate","Hard"]},
  trapTested:{type:"string",minLength:2},verification:{type:"string",minLength:3},qualityScore:{type:"number",minimum:.9,maximum:1},ambiguous:{type:"boolean",enum:[false]},
  sourceType:{type:"string",enum:["AI Generated SSC Calculation","AI Variant of Calculation Pattern"]},
}};
const schema=(n:number)=>({type:"object",additionalProperties:false,required:["items"],properties:{items:{type:"array",minItems:n,maxItems:n,items:item}}});

function shuffle<T>(a:T[]){a=[...a];for(let i=a.length-1;i>0;i--){const b=new Uint32Array(1);crypto.getRandomValues(b);const j=b[0]%(i+1);[a[i],a[j]]=[a[j],a[i]];}return a;}
function slots(n:number){
  const base=n>=24
    ? ["FractionsPercentages","FractionsPercentages","FractionsPercentages","SquaresRoots","SquaresRoots","CubesRoots","TablesMultiplication","TablesMultiplication","TablesMultiplication","DivisionCancellation","DivisionCancellation","DivisionCancellation","ApproxSimplify","ApproxSimplify","ApproxSimplify","NumberSpeed","NumberSpeed","RatioProportion","RatioProportion","SSCMixed","SSCMixed","SSCMixed","SSCMixed","SSCMixed"]
    : ["FractionsPercentages","SquaresRoots","CubesRoots","TablesMultiplication","DivisionCancellation","ApproxSimplify","NumberSpeed","RatioProportion","SSCMixed","FractionsPercentages","TablesMultiplication","DivisionCancellation","ApproxSimplify","SSCMixed","SSCMixed","NumberSpeed"];
  const chosen=shuffle(base).slice(0,n);while(chosen.length<n)chosen.push(SKILLS[chosen.length%SKILLS.length]);
  return chosen.map((skill,i)=>({position:i+1,skill,difficulty:i<n*.62?"Hard":"Moderate"}));
}
const norm=(x:any)=>String(x||"").trim().toLowerCase().replace(/\s+/g," ");
function validate(items:any[],plan:any[],ctx:any){
  const errors:string[]=[];const qs=new Set<string>(),patterns=new Set<string>();const recent=new Set((ctx?.recentGenerated||[]).map((x:any)=>norm(x?.prompt)));
  items.forEach((x,i)=>{
    const q=norm(x?.question),p=norm(x?.patternKey),opts=x?.options||[],keys=opts.map((o:any)=>String(o?.key||"").toUpperCase()),texts=opts.map((o:any)=>norm(o?.text));
    const correct=opts.find((o:any)=>String(o?.key||"").toUpperCase()===String(x?.correctKey||"").toUpperCase());
    if(!q||qs.has(q)||recent.has(q))errors.push(`Q${i+1}: duplicate/recent question`);qs.add(q);
    if(!p||patterns.has(p))errors.push(`Q${i+1}: duplicate pattern`);patterns.add(p);
    if(opts.length!==4||new Set(keys).size!==4||new Set(texts).size!==4)errors.push(`Q${i+1}: invalid options`);
    if(!correct||norm(correct.text)!==norm(x?.answerText))errors.push(`Q${i+1}: answer/option mismatch`);
    if(x?.skill!==plan[i]?.skill||x?.difficulty!==plan[i]?.difficulty)errors.push(`Q${i+1}: slot mismatch`);
    if(x?.ambiguous!==false||+x?.qualityScore<.9||+x?.expectedSec<5||+x?.expectedSec>40)errors.push(`Q${i+1}: quality contract`);
    if(/pyq|previous year|asked in ssc/i.test(String(x?.question||"")+String(x?.explanation||"")))errors.push(`Q${i+1}: false PYQ claim`);
  });
  return errors;
}

const generator=`You are the Maths Exam Preparation SSC CALCULATION-SPEED generator for a strong SSC learner. Generate calculation-only micro-drills representative of arithmetic operations repeatedly needed inside SSC CGL/CHSL/CPO Maths solving. These are NOT chapter/concept questions and must never require a word-problem approach, theorem selection, mensuration formula recall, geometry reasoning, algebraic concept teaching, or long derivation. Follow slotPlan exactly. Use skills: FractionsPercentages (fraction↔percentage and awkward percentage arithmetic), SquaresRoots, CubesRoots, TablesMultiplication (hard mental products), DivisionCancellation (factor cancellation and exact division), ApproxSimplify, NumberSpeed (unit digit/remainder/divisibility-style arithmetic only), RatioProportion (numeric ratio reduction/equivalent ratios), SSCMixed (multi-operation arithmetic micro-step that resembles the working inside an SSC problem). Moderate/Hard means computational discrimination, close options and smart cancellation—not huge numbers for their own sake. Target roughly 5–40 seconds per item for a strong candidate. Exactly four distinct A/B/C/D options and exactly one defensible answer. answerText MUST exactly equal the correct option text. verification must independently show the arithmetic/check needed to prove the answer. explanation should teach the fastest SSC calculation route in 1–3 concise sentences. Use seedPatterns only as pattern inspiration, never copy exact questions. Avoid recentGenerated. Never claim an item is a PYQ or an actual previous-year question. ambiguous=false and qualityScore>=0.90. Self-check every answer before returning.`;
const critic=`You are an INDEPENDENT arithmetic verifier and selective-repair editor for SSC calculation-speed drills. Recompute EVERY draft item from scratch. Return a COMPLETE FINAL SET with the same positions and slotPlan. Repair any arithmetic error, ambiguous wording, weak distractor, duplicate pattern, unrealistic difficulty, too-long calculation, academic/chapter concept leakage, or answerText/correct-option mismatch. Keep the task calculation-only and representative of arithmetic used while solving SSC Maths; never claim PYQ. Four distinct A/B/C/D options, one exact answer, answerText exactly equals the correct option text, expectedSec 5–40, ambiguous=false, qualityScore>=0.90. verification must contain a fresh independent arithmetic check; explanation must give the fastest practical calculation route. Preserve slotPlan skill and difficulty exactly. Return only the final set.`;

async function build(s:any,count:number,sessionId:string|null){
  const cx=await s.rpc("maths_get_calculation_generation_context",{p_session_id:sessionId});if(cx.error)throw cx.error;
  const plan=slots(count),group=crypto.randomUUID();
  const draft=await ai("maths_ssc_calculation_draft",schema(count),generator,{...cx.data,slotPlan:plan},"low");
  await log(s,group,"generation",draft,sessionId,{count,pass:1});
  const di=draft.data?.items||[];if(di.length!==count)throw new Error("Calculation generator returned the wrong item count");
  const checked=await ai("maths_ssc_calculation_critic",schema(count),critic,{slotPlan:plan,draftItems:di,recentGenerated:cx.data?.recentGenerated||[],seedPatterns:cx.data?.seedPatterns||[]},"low");
  await log(s,group,"critic_verify",checked,sessionId,{count,pass:2,independentArithmeticCheck:true});
  const items=checked.data?.items||[];if(items.length!==count)throw new Error("Calculation critic returned the wrong item count");
  const bad=validate(items,plan,cx.data);if(bad.length)throw new Error(`Calculation quality gate failed: ${bad.slice(0,6).join(" | ")}`);
  return {items,group};
}

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return reply({ok:false,error:"POST required"},405);
  try{
    const auth=req.headers.get("Authorization")||"";if(!auth.startsWith("Bearer "))return reply({ok:false,error:"Authentication required"},401);
    const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY");if(!url||!anon)throw new Error("Supabase function environment is incomplete");
    const s=createClient(url,anon,{global:{headers:{Authorization:auth}}});const u=await s.auth.getUser();if(u.error||!u.data.user)return reply({ok:false,error:"Authentication required"},401);
    const b=await req.json().catch(()=>({}));const action=String(b?.action||"create").toLowerCase();

    if(action==="create"){
      const active=await s.rpc("maths_get_active_exam_session");if(active.error)throw active.error;
      if(active.data?.active){
        if(active.data?.track==="calculation"&&active.data?.sessionId){const existing=await s.rpc("maths_get_session",{p_session_id:active.data.sessionId});if(existing.error)throw existing.error;return reply(existing.data);}
        return reply({ok:false,error:"An Academic Sprint is active. Resume or end it before Calculation Sprint."},409);
      }
      const built=await build(s,24,null);
      const made=await s.rpc("maths_create_ai_calculation_session",{p_items:built.items,p_generation_id:built.group});if(made.error)throw made.error;
      const sid=String(made.data?.sessionId||"");if(!sid)throw new Error("AI Calculation session was not persisted");
      return reply(made.data);
    }

    if(action==="refill"){
      const sid=String(b?.sessionId||"");if(!sid)return reply({ok:false,error:"sessionId required"},400);
      const built=await build(s,16,sid);
      const appended=await s.rpc("maths_append_ai_calculation_items",{p_session_id:sid,p_items:built.items,p_generation_id:built.group});if(appended.error)throw appended.error;
      return reply(appended.data);
    }

    return reply({ok:false,error:"Unknown action"},400);
  }catch(e:any){console.error("maths-ssc-calculation",e);return reply({ok:false,error:e instanceof Error?e.message:String(e)},500);}
});

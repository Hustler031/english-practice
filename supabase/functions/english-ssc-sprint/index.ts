import { createClient } from "npm:@supabase/supabase-js@2";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
};
const model="gpt-5.6-luna";
const TIMEOUT=55000;
const counts:any={standard:25,weakness:15,trap:15,mistakes:10};
const diagnoses=["Knowledge Gap","Confusion","Rule Gap","Careless","Time Pressure","Misread","Distractor Trap"];
const actions=["Targeted Mastery","Weakness Drill","Trap Practice","Execution Review","No Route Change"];

const reply=(body:any,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
function errorText(e:any){
  if(e instanceof Error)return e.message;
  if(typeof e==="string")return e;
  for(const k of ["message","details","hint","error_description","error"]){
    const v=e?.[k];
    if(typeof v==="string"&&v.trim())return v;
  }
  try{const v=JSON.stringify(e);return v&&v!=="{}"?v:"Unknown Sprint generation error"}catch{return "Unknown Sprint generation error"}
}

function text(p:any){
  if(typeof p?.output_text==="string")return p.output_text;
  for(const i of p?.output||[])for(const c of i?.content||[])if(c?.type==="output_text")return c.text||"";
  return "";
}
function usage(p:any){
  const u=p?.usage||{};
  return {input:+u.input_tokens||0,output:+u.output_tokens||0,reasoning:+u.output_tokens_details?.reasoning_tokens||0,total:+u.total_tokens||0};
}
async function ai(name:string,schema:any,instructions:string,input:any,effort:"low"|"medium"="medium"){
  const key=Deno.env.get("OPENAI_API_KEY");
  if(!key)throw new Error("OPENAI_API_KEY is not configured for english-ssc-sprint");
  const ctrl=new AbortController();
  const timer=setTimeout(()=>ctrl.abort(),TIMEOUT);
  try{
    const r=await fetch("https://api.openai.com/v1/responses",{
      method:"POST",
      signal:ctrl.signal,
      headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},
      body:JSON.stringify({
        model,
        reasoning:{effort},
        max_output_tokens:12000,
        instructions,
        input:JSON.stringify(input),
        text:{format:{type:"json_schema",name,strict:true,schema}},
      }),
    });
    const p=await r.json();
    if(!r.ok)throw new Error(p?.error?.message||`OpenAI request failed (${r.status})`);
    const t=text(p);
    if(!t)throw new Error("OpenAI returned no structured output");
    return {data:JSON.parse(t),usage:usage(p),responseId:String(p?.id||""),model:String(p?.model||model)};
  }catch(e:any){
    if(e?.name==="AbortError")throw new Error("Sprint AI pass timed out safely before the server compute limit. Please retry.");
    throw e;
  }finally{clearTimeout(timer)}
}
async function log(s:any,g:string,type:string,mode:string,r:any,sid:string|null=null,meta:any={}){
  try{
    await s.rpc("english_log_sprint_ai_usage",{
      p_request_group:g,p_request_type:type,p_mode:mode,p_model:r.model,
      p_input_tokens:r.usage.input,p_output_tokens:r.usage.output,p_reasoning_tokens:r.usage.reasoning,p_total_tokens:r.usage.total,
      p_response_id:r.responseId||null,p_session_id:sid,p_metadata:meta,
    });
  }catch{}
}

const option={type:"object",additionalProperties:false,required:["key","text"],properties:{key:{type:"string",enum:["A","B","C","D"]},text:{type:"string",minLength:1}}};
const item={
  type:"object",additionalProperties:false,
  required:["itemKey","category","questionType","question","options","correctKey","explanation","sourceType","canonicalQuestionId","ambiguous","qualityScore","metadata"],
  properties:{
    itemKey:{type:"string",minLength:1},category:{type:"string",minLength:1},questionType:{type:"string",minLength:1},question:{type:"string",minLength:1},
    options:{type:"array",minItems:4,maxItems:4,items:option},correctKey:{type:"string",enum:["A","B","C","D"]},explanation:{type:"string",minLength:1},
    sourceType:{type:"string",enum:["GPT Generated","GPT Variant of Known Concept"]},canonicalQuestionId:{type:["string","null"]},ambiguous:{type:"boolean",enum:[false]},qualityScore:{type:"number",minimum:0.8,maximum:1},
    metadata:{type:"object",additionalProperties:false,required:["conceptKey","trapTested","difficultyTier","discriminationScore","trapStrength","generationReason","domain"],properties:{
      conceptKey:{type:"string",minLength:1},trapTested:{type:"string",minLength:1},difficultyTier:{type:"string",enum:["Easy","Moderate","Hard"]},
      discriminationScore:{type:"number",minimum:0,maximum:1},trapStrength:{type:"number",minimum:0,maximum:1},generationReason:{type:"string",minLength:1},domain:{type:"string",enum:["GrammarTransformation","LexicalUsage"]},
    }},
  },
};
const sprintSchema=(n:number)=>({type:"object",additionalProperties:false,required:["items"],properties:{items:{type:"array",minItems:n,maxItems:n,items:item}}});
const repairItem={
  ...item,
  required:["position",...(item.required as string[])],
  properties:{position:{type:"integer",minimum:1,maximum:25},...item.properties},
};
const repairSchema=(positions:number[])=>({
  type:"object",additionalProperties:false,required:["items"],properties:{items:{type:"array",minItems:positions.length,maxItems:positions.length,items:{...repairItem,properties:{...repairItem.properties,position:{type:"integer",enum:positions}}}}},
});
const analysisSchema=(n:number)=>({type:"object",additionalProperties:false,required:["items"],properties:{items:{type:"array",minItems:n,maxItems:n,items:{
  type:"object",additionalProperties:false,required:["position","diagnosis","action","confusedWith","rationale"],properties:{
    position:{type:"integer",minimum:1,maximum:25},diagnosis:{type:"string",enum:diagnoses},action:{type:"string",enum:actions},confusedWith:{type:"string"},rationale:{type:"string",minLength:1},
  },
}}}});

function shuffle(a:any[]){
  a=[...a];
  for(let i=a.length-1;i>0;i--){const b=new Uint32Array(1);crypto.getRandomValues(b);const j=b[0]%(i+1);[a[i],a[j]]=[a[j],a[i]]}
  return a;
}
function slots(mode:string,c:any){
  const n=counts[mode],d=c?.blueprint?.difficulty||{},e=+d.easy||(mode==="standard"?5:2),m=+d.moderate||Math.max(0,n-e-5),h=+d.hard||Math.max(0,n-e-m);
  const t=shuffle([...Array(e).fill("Easy"),...Array(m).fill("Moderate"),...Array(h).fill("Hard")]).slice(0,n);
  while(t.length<n)t.push("Moderate");
  if(mode!=="standard")return t.map((difficultyTier,i)=>({position:i+1,difficultyTier}));
  const g=+c?.blueprint?.questionMix?.grammarTransformation||11;
  const dom=shuffle([...Array(g).fill("GrammarTransformation"),...Array(n-g).fill("LexicalUsage")]);
  return t.map((difficultyTier,i)=>({position:i+1,difficultyTier,domain:dom[i]}));
}
const norm=(x:any)=>String(x||"").trim().toLowerCase().replace(/\s+/g," ");
type ValidationIssue={position:number;reasons:string[]};
function validationIssues(items:any[],sp:any[],ctx:any):ValidationIssue[]{
  const q=new Set<string>(),c=new Set<string>(),cool=new Set<string>((ctx?.cooldownConcepts||[]).map(norm)),sameDay=new Set<string>((ctx?.sameDayQuestions||[]).map(norm));
  const issues:ValidationIssue[]=[];
  items.forEach((x,i)=>{
    const reasons:string[]=[];
    const o=x?.options||[],ot=o.map((z:any)=>norm(z.text)),ok=o.map((z:any)=>String(z.key||"").toUpperCase()),qq=norm(x?.question),cc=norm(x?.metadata?.conceptKey),type=norm(x?.questionType);
    if(!qq)reasons.push("missing question");
    else{
      if(q.has(qq))reasons.push("duplicate question");
      if(sameDay.has(qq))reasons.push("same-day question");
    }
    if(!cc)reasons.push("missing conceptKey");
    else{
      if(c.has(cc))reasons.push("duplicate conceptKey");
      if(cool.has(cc))reasons.push("cooldown conceptKey");
    }
    if(o.length!==4||new Set(ot).size!==4||new Set(ok).size!==4)reasons.push("invalid options");
    if(/reading|comprehension|passage|cloze/.test(type))reasons.push("RC/passage not allowed");
    if(x?.metadata?.difficultyTier!==sp[i]?.difficultyTier||(sp[i]?.domain&&x?.metadata?.domain!==sp[i].domain))reasons.push("slot mismatch");
    if(x?.ambiguous!==false||+x?.qualityScore<.8)reasons.push("quality/ambiguity");
    if(reasons.length)issues.push({position:i+1,reasons});
    if(qq)q.add(qq);
    if(cc)c.add(cc);
  });
  return issues;
}
function validationSummary(issues:ValidationIssue[]){return issues.map(x=>`Q${x.position}: ${x.reasons.join(", ")}`)}
function mergeRepairs(items:any[],repairs:any[],positions:number[]){
  const wanted=new Set(positions),byPos=new Map<number,any>();
  for(const r of repairs||[]){const p=Number(r?.position);if(wanted.has(p)&&!byPos.has(p))byPos.set(p,r)}
  if(byPos.size!==positions.length)throw new Error("Selective Sprint repair did not return every requested position");
  return items.map((x,i)=>{const r=byPos.get(i+1);if(!r)return x;const {position:_,...clean}=r;return clean});
}

const gen=`You are the English V2 SSC CGL Sprint generator for a strong learner. Build fair, high-discrimination SSC objective-English questions and follow slotPlan exactly. Standard Sprint is exam simulation, not a weakness drill. Never generate Reading Comprehension, cloze passages, passage-dependent items or multi-question passages. Difficulty must come from close distractors, subtle SSC rules, realistic context, transformation complexity and confusable usage, never obscure GRE/CAT vocabulary. Every item needs exactly one defensible answer and four plausible distinct A/B/C/D options; at least 2–3 distractors should be close. Moderate/Hard Error Detection should use realistic multi-clause sentences, not toy errors. Sentence Improvement, Voice and Narration should require full processing and subtle alternatives. Vocabulary must be moderate-to-hard SSC-oriented with semantic neighbours. Phrasal Verbs, Idioms, OWS, Spelling and fixed usage should use confusable alternatives. Use previousMistakes as fresh transfer seeds and slowCorrectSeeds as hesitation evidence without turning Standard into remediation. cooldownConcepts are HARD FORBIDDEN for this Sprint after a fast correct answer today; do not test the same semantic concept and do not rename it to evade the block unless later genuine wrong evidence explicitly requires it. sameDayQuestions are exact questions already completed today and are HARD FORBIDDEN: never repeat or lightly rephrase them. sourceType is only GPT Generated or GPT Variant of Known Concept; never claim SSC PYQ. metadata difficultyTier/domain must match slotPlan; ambiguous=false; qualityScore minimum: 0.8. explanation is post-Sprint only. Self-check before returning; a separate independent critic audits the draft.`;
const critic=`You are the INDEPENDENT pre-serve critic and selective-repair editor for an SSC CGL English Sprint; you did not generate the draft. Return a COMPLETE FINAL SET with the same number of positions. Audit every draft item for SSC realism, requested Easy/Moderate/Hard fit, distractor strength, ambiguity, grammatical validity, exactly one defensible answer, intended concept, duplicate concepts and excessive familiarity. Preserve passing items; repair every failing position yourself in this same pass. Preserve slotPlan difficultyTier/domain exactly. cooldownConcepts are HARD FORBIDDEN semantic concepts for this Sprint: do not retain them and do not merely rename the same conceptKey. sameDayQuestions are HARD FORBIDDEN exact questions already completed today: replace any matching or trivially reworded item. No Reading Comprehension, cloze, passage-dependent content, obscure GRE/CAT vocabulary, toy Moderate/Hard grammar, or elementary Moderate/Hard Voice/Narration. Keep four unique A/B/C/D options and close distractors. Avoid duplicate question/concept and cooldownConcepts. sourceType remains truthful: GPT Generated or GPT Variant of Known Concept. Every final item must have ambiguous=false and qualityScore>=0.80. This bounded independent pass replaces critic→repair→critic loops. Return only the final set.`;
const repairPrompt=`You are the FINAL SELECTIVE REPAIR editor for an SSC CGL English Sprint. The deterministic validator has rejected ONLY the listed positions. Return replacements ONLY for requestedPositions, exactly one replacement per position. Do not alter or return accepted positions. Each replacement must preserve that position's slotPlan difficultyTier and domain, remain SSC-realistic, have exactly one defensible answer, four unique A/B/C/D options and qualityScore>=0.80. forbiddenConceptKeys are absolute semantic blocks: do not reuse them and do not rename the same tested concept to evade the list. forbiddenQuestions include both accepted current questions and questions already completed today; do not repeat or lightly rephrase any of them. Also avoid every conceptKey already used by acceptedItems. No Reading Comprehension, cloze or passage-dependent content. Return position plus the complete replacement item.`;
const analyst=`Diagnose each genuinely WRONG English Sprint answer from completed evidence. Unanswered items are not wrong. Distinguish Knowledge Gap, Confusion, Rule Gap and Distractor Trap from Careless, Time Pressure and Misread. Use Targeted Mastery only for genuine durable learning gaps; execution errors should normally use Execution Review/No Route Change. Return one diagnosis for every supplied wrong position.`;

async function selectiveRepair(s:any,g:string,mode:string,jobId:string,items:any[],sp:any[],ctx:any){
  let current=items;
  let rounds=0;
  for(let attempt=1;attempt<=2;attempt++){
    const issues=validationIssues(current,sp,ctx);
    if(!issues.length)return {items:current,rounds};
    const requestedPositions=issues.map(x=>x.position);
    const badSet=new Set(requestedPositions);
    const acceptedItems=current.map((x,i)=>({position:i+1,...x})).filter(x=>!badSet.has(x.position));
    const forbiddenConceptKeys=[...new Set([...(ctx?.cooldownConcepts||[]).map((x:any)=>String(x)),...acceptedItems.map((x:any)=>String(x?.metadata?.conceptKey||"")).filter(Boolean)])];
    const forbiddenQuestions=[...new Set([...(ctx?.sameDayQuestions||[]).map((x:any)=>String(x)),...acceptedItems.map((x:any)=>String(x?.question||"")).filter(Boolean)])];
    const repair=await ai(`english_ssc_sprint_selective_repair_${attempt}`,repairSchema(requestedPositions),repairPrompt,{
      mode,
      requestedPositions,
      validationIssues:issues,
      slotPlan:sp.filter((x:any)=>badSet.has(Number(x.position))),
      forbiddenConceptKeys,
      forbiddenQuestions,
      acceptedItems:acceptedItems.map((x:any)=>({position:x.position,category:x.category,questionType:x.questionType,question:x.question,conceptKey:x?.metadata?.conceptKey})),
      weakCategories:ctx?.weakCategories||[],
      trapProfile:ctx?.trapProfile||[],
      previousMistakes:ctx?.previousMistakes||[],
    },"low");
    await log(s,g,"validation_repair",mode,repair,null,{backgroundJob:jobId,repairAttempt:attempt,repairedPositions:requestedPositions});
    current=mergeRepairs(current,repair.data?.items||[],requestedPositions);
    rounds=attempt;
  }
  return {items:current,rounds};
}

async function generateJob(s:any,jobId:string,mode:string){
  try{
    const begun=await s.rpc("english_begin_sprint_generation",{p_job_id:jobId});
    if(begun.error)throw new Error(errorText(begun.error));
    if(begun.data?.shouldGenerate!==true)return;

    const n=counts[mode];
    const cx=await s.rpc("english_get_sprint_generation_context",{p_mode:mode});
    if(cx.error)throw new Error(errorText(cx.error));
    const sameDay=await s.rpc("english_get_sprint_same_day_questions");
    if(sameDay.error)throw new Error(errorText(sameDay.error));
    const ctx={...(cx.data||{}),sameDayQuestions:Array.isArray(sameDay.data)?sameDay.data:[]};
    const sp=slots(mode,ctx);
    const g=crypto.randomUUID();

    const draft=await ai("english_ssc_sprint",sprintSchema(n),gen,{...ctx,slotPlan:sp},"medium");
    await log(s,g,"generation",mode,draft,null,{itemCount:n,boundedPass:1,backgroundJob:jobId});
    const di=draft.data?.items||[];
    if(di.length!==n)throw new Error("Sprint generation returned the wrong item count");

    const polished=await ai("english_ssc_sprint_independent_critic_polish",sprintSchema(n),critic,{
      mode,blueprint:ctx?.blueprint||{},recentStandardPerformance:ctx?.recentStandardPerformance||{},cooldownConcepts:ctx?.cooldownConcepts||[],sameDayQuestions:ctx?.sameDayQuestions||[],slotPlan:sp,draftItems:di,
    },"low");
    await log(s,g,"critic_polish",mode,polished,null,{itemCount:n,boundedPass:2,selectiveRepair:true,backgroundJob:jobId});
    let items=polished.data?.items||[];
    if(items.length!==n)throw new Error("Independent Sprint critic returned the wrong item count");

    const repaired=await selectiveRepair(s,g,mode,jobId,items,sp,ctx);
    items=repaired.items;
    const finalIssues=validationIssues(items,sp,ctx);
    if(finalIssues.length)throw new Error(`Sprint validation still failed after selective repair: ${validationSummary(finalIssues).slice(0,8).join(" | ")}`);
    items=items.map((x:any)=>({...x,metadata:{...(x.metadata||{}),criticPassed:true,criticScore:1,criticReasons:[],criticMode:repaired.rounds?"independent-polish-plus-selective-repair":"independent-bounded-polish"}}));

    const blueprint={
      ...(ctx?.blueprint||{}),
      startImmediately:false,
      slotPlan:sp,
      critic:{enabled:true,independent:true,selectiveRepair:true,rounds:1,repairRounds:repaired.rounds,boundedPasses:2+repaired.rounds,computeBounded:true},
      generatedAt:new Date().toISOString(),
    };
    const made=await s.rpc("english_create_sprint_session",{p_mode:mode,p_items:items,p_blueprint:blueprint});
    if(made.error)throw new Error(errorText(made.error));
    const sid=String(made.data?.sessionId||"");
    if(!sid)throw new Error("Generated Sprint session was not persisted");
    try{await s.rpc("english_attach_sprint_ai_usage",{p_request_group:g,p_session_id:sid})}catch{}
    const completed=await s.rpc("english_complete_sprint_generation",{p_job_id:jobId,p_session_id:sid,p_request_group:g});
    if(completed.error)throw new Error(errorText(completed.error));
  }catch(e:any){
    console.error("english-ssc-sprint background generation",e);
    try{await s.rpc("english_fail_sprint_generation",{p_job_id:jobId,p_error:errorText(e)})}catch{}
  }
}

function keepAlive(task:Promise<void>){
  const runtime=(globalThis as any).EdgeRuntime;
  if(runtime&&typeof runtime.waitUntil==="function"){
    runtime.waitUntil(task);
    return true;
  }
  return false;
}

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return reply({ok:false,error:"POST required"},405);
  try{
    const auth=req.headers.get("Authorization")||"";
    if(!auth.startsWith("Bearer "))return reply({ok:false,error:"Authentication required"},401);
    const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY");
    if(!url||!anon)throw new Error("Supabase function environment is incomplete");
    const s=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const u=await s.auth.getUser();
    if(u.error||!u.data.user)return reply({ok:false,error:"Authentication required"},401);
    const b=await req.json().catch(()=>({}));
    const action=String(b?.action||"create").toLowerCase();

    if(action==="create"){
      const mode=String(b?.mode||"standard").toLowerCase();
      if(!counts[mode])return reply({ok:false,error:"Unknown Sprint mode"},400);
      const started=await s.rpc("english_start_sprint_generation",{p_mode:mode});
      if(started.error)throw new Error(errorText(started.error));
      const state=started.data||{};
      if(state.activeSprint&&state.sessionId){
        const existing=await s.rpc("english_get_sprint_session",{p_session_id:state.sessionId});
        if(existing.error)throw new Error(errorText(existing.error));
        return reply(existing.data);
      }
      const jobId=String(state.jobId||"");
      if(!jobId)throw new Error("Sprint generation job was not created");
      if(state.shouldStart===true){
        const task=generateJob(s,jobId,String(state.mode||mode));
        if(!keepAlive(task))await task;
      }
      return reply({ok:true,generationPending:true,jobId,mode:String(state.mode||mode),status:String(state.status||"queued")},202);
    }

    if(action==="analyze"){
      const sid=String(b?.sessionId||"");
      if(!sid)return reply({ok:false,error:"sessionId required"},400);
      const cx=await s.rpc("english_get_sprint_analysis_context",{p_session_id:sid});
      if(cx.error)throw new Error(errorText(cx.error));
      const wrong=cx.data?.wrongItems||[];
      if(!wrong.length){
        const saved=await s.rpc("english_save_sprint_analysis",{p_session_id:sid,p_analysis:[]});
        if(saved.error)throw new Error(errorText(saved.error));
        return reply({ok:true,analysis:[],targetedAdded:0});
      }
      const g=crypto.randomUUID();
      const r=await ai("english_ssc_sprint_analysis",analysisSchema(wrong.length),analyst,cx.data,"low");
      await log(s,g,"analysis",String(cx.data?.mode||""),r,sid,{wrongCount:wrong.length});
      const pos=new Set(wrong.map((x:any)=>+x.position));
      if(!Array.isArray(r.data?.items)||r.data.items.some((x:any)=>!pos.has(+x.position)))throw new Error("Sprint analysis positions do not match wrong items");
      const saved=await s.rpc("english_save_sprint_analysis",{p_session_id:sid,p_analysis:r.data.items});
      if(saved.error)throw new Error(errorText(saved.error));
      return reply({ok:true,analysis:r.data.items,targetedAdded:saved.data?.targetedAdded||0});
    }

    return reply({ok:false,error:"Unknown action"},400);
  }catch(e:any){
    console.error("english-ssc-sprint",e);
    return reply({ok:false,error:errorText(e)},500);
  }
});
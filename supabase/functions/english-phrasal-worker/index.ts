import { createClient } from "npm:@supabase/supabase-js@2";
import {
  ANTIGRAVITY_AGENT, ANTIGRAVITY_MODEL, LUNA_MODEL, GEMINI_RARE_RESCUE_MODEL,
} from "../_shared/english-antigravity-luna.ts";
import { finalizeSinglePhrasalItem } from "./single-slot-generation.ts";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info, x-english-context-token",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown Phrasal worker error");

async function authorize(req:Request,db:any){
  const privateToken=String(req.headers.get("x-english-context-token")||"").trim();
  if(privateToken){
    const {data,error}=await db.rpc("english_phrasal_worker_token_authorized",{p_token:privateToken});
    if(error||data!==true)throw new Error("Unauthorized private worker token");
    return {mode:"scheduler" as const,userId:null};
  }
  const auth=String(req.headers.get("authorization")||"");
  const accessToken=auth.startsWith("Bearer ")?auth.slice(7).trim():"";
  if(!accessToken)throw new Error("Authentication required");
  const {data,error}=await db.auth.getUser(accessToken);
  const userId=String(data?.user?.id||"");
  if(error||!userId)throw new Error("Authentication required");
  const {data:ownerOk,error:ownerError}=await db.rpc("english_phrasal_worker_user_authorized",{p_user_id:userId});
  if(ownerError||ownerOk!==true)throw new Error("Phrasal maintenance owner rejected");
  return {mode:"app" as const,userId};
}
async function featureEnabled(db:any,flag:string){
  const {data,error}=await db.rpc("english_ai_content_feature_enabled",{p_flag:flag});
  if(error)throw new Error(`FEATURE_READ_FAILED: ${error.message}`);
  return data===true;
}
async function auditApplied(db:any,items:any[]){
  const generated=items.filter(x=>x?.generatorProvider!=="legacy_bank");
  if(!generated.length)return;
  const payload=generated.map(x=>({
    lane:"phrasal",entityKey:String(x.conceptId||""),generatorProvider:String(x.generatorProvider||"unknown"),generatorModel:String(x.generatorModel||"unknown"),
    criticProvider:String(x.criticProvider||"openai"),criticModel:String(x.criticModel||LUNA_MODEL),qualityScore:Number(x?.quality?.score||0),criticDecision:String(x?.quality?.decision||""),
    repairCount:Number(x?.repairCount||0),questionFamily:String(x?.requestedQuestionFamily||""),senseKey:String(x?.senseKey||""),variantKey:String(x?.variantKey||""),variantFingerprint:String(x?.variantFingerprint||""),publicationResult:"applied",
    metadata:{
      requestMode:"single_slot_checkpoint",writer:String(x.generatorProvider||"unknown"),antigravityAgent:ANTIGRAVITY_AGENT,antigravityModel:ANTIGRAVITY_MODEL,
      critic:"luna",criticReasoning:"low",lunaModel:LUNA_MODEL,rareRescueModel:GEMINI_RARE_RESCUE_MODEL,rareRescue:x?.rareRescue===true,
      writerRequests:Number(x?.writerRequests||0),antigravityRequests:Number(x?.antigravityRequests||0),geminiWriterRequests:Number(x?.geminiWriterRequests||0),
      antigravityFallback:x?.antigravityFallback===true,antigravityFallbackReason:String(x?.antigravityFallbackReason||""),criticRequests:Number(x?.criticRequests||0),codeRepairCount:Number(x?.codeRepairCount||0),
    },
  }));
  const {error}=await db.rpc("english_record_content_generation_audits",{p_items:payload});
  if(error)throw new Error(`AUDIT_FAILED: ${error.message}`);
}
async function publishIfReady(db:any,runId:string,store:any,allowPublish:boolean){
  if(store?.publishReady!==true)return null;
  const items=Array.isArray(store?.items)?store.items:[];
  if(items.length!==20)throw new Error(`PHRASAL_READY_INVALID: expected 20 checkpointed slots, got ${items.length}`);
  if(!allowPublish)return {publishReady:true,published:false};
  const {data:applied,error:applyError}=await db.rpc("english_phrasal_task_apply",{p_run_id:runId,p_items:items});
  if(applyError)throw new Error(`PHRASAL_APPLY_FAILED: ${applyError.message}`);
  const {error:markError}=await db.rpc("english_phrasal_single_slot_mark_applied",{p_run_id:runId});
  if(markError)throw new Error(`PHRASAL_MARK_APPLIED_FAILED: ${markError.message}`);
  await auditApplied(db,items);
  return {publishReady:true,published:true,applied};
}

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return json({error:"Method not allowed"},405);
  const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!serviceKey)return json({error:"Supabase service configuration missing"},503);
  const db=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});

  let caller:{mode:"scheduler"|"app";userId:string|null};
  try{caller=await authorize(req,db)}catch(e){return json({ok:false,error:errorText(e)},401)}
  let body:any={};try{body=await req.json()}catch{body={}}
  if(String(body?.action||"run")!=="run")return json({ok:false,error:"Unknown action"},400);
  const allowPublish=body?.publish!==false;

  try{
    if(!await featureEnabled(db,"luna_critic_v1")||!await featureEnabled(db,"phrasal_sense_v1")||!await featureEnabled(db,"phrasal_context_fill_v1"))
      throw new Error("AI_PIPELINE_DISABLED: Phrasal Luna/sense/context flags are not enabled");

    const {data:claim,error:claimError}=await db.rpc("english_phrasal_single_slot_claim");
    if(claimError)throw new Error(`PHRASAL_SLOT_CLAIM_FAILED: ${claimError.message}`);

    if(Number(claim?.count||0)===0){
      const publish=claim?.publishReady===true?await publishIfReady(db,String(claim?.runId||""),claim,allowPublish):null;
      return json({...(claim||{ok:true,count:0}),...(publish||{}),trigger:caller.mode,singleSlot:true});
    }

    const runId=String(claim?.runId||""),slotNo=Number(claim?.slotNo||0),item=claim?.item;
    if(!runId||!slotNo||!item)throw new Error("PHRASAL_SLOT_CLAIM_INVALID");

    let finalized:any;
    try{finalized=await finalizeSinglePhrasalItem(item)}
    catch(e){
      const message=errorText(e);
      const {data:failed,error:storeError}=await db.rpc("english_phrasal_single_slot_store",{p_run_id:runId,p_slot_no:slotNo,p_item:null,p_error:message.slice(0,1200)});
      if(storeError)throw new Error(`${message} | CHECKPOINT_FAIL_FAILED: ${storeError.message}`);
      return json({ok:false,lane:"phrasal",singleSlot:true,runId,slotNo,conceptId:claim?.conceptId,requestedFamily:claim?.requestedFamily,checkpoint:failed,error:message,trigger:caller.mode},500);
    }

    const {data:stored,error:storeError}=await db.rpc("english_phrasal_single_slot_store",{p_run_id:runId,p_slot_no:slotNo,p_item:finalized,p_error:null});
    if(storeError)throw new Error(`PHRASAL_SLOT_STORE_FAILED: ${storeError.message}`);
    const publish=await publishIfReady(db,runId,stored,allowPublish);
    return json({
      ok:true,lane:"phrasal",singleSlot:true,runId,slotNo,conceptId:claim?.conceptId,requestedFamily:claim?.requestedFamily,
      checkpoint:stored,generatorProvider:finalized?.generatorProvider,generatorModel:finalized?.generatorModel,qualityScore:finalized?.quality?.score??null,
      writerRequests:Number(finalized?.writerRequests||0),antigravityRequests:Number(finalized?.antigravityRequests||0),geminiWriterRequests:Number(finalized?.geminiWriterRequests||0),
      antigravityFallback:finalized?.antigravityFallback===true,rareRescue:finalized?.rareRescue===true,criticRequests:Number(finalized?.criticRequests||0),
      ...(publish||{}),trigger:caller.mode,
    });
  }catch(e){return json({ok:false,lane:"phrasal",singleSlot:true,trigger:caller.mode,error:errorText(e)},500)}
});

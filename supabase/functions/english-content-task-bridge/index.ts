import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";
import { ingestSubmittedConfusionItems } from "./submitted-confusion.ts";
import { claimSubmittedPhrasal, ingestSubmittedPhrasal } from "./submitted-phrasal.ts";
import { claimSubmittedGrammar, ingestSubmittedGrammar } from "./submitted-grammar.ts";

const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "english-content-automation";
const REPOSITORY = "Hustler031/telegram-media-bot";
const PHRASE_REF = "refs/heads/automation/english-phrasal";
// Kept as a transport compatibility ref. Content semantics are Daily Confusion 15.
const HINDU_REF = "refs/heads/automation/english-hindu";
const GRAMMAR_REF = "refs/heads/automation/english-grammar";
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks`));
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown content automation error");
type Lane = "phrasal"|"hindu"|"grammar";

async function authorize(req:Request):Promise<Lane>{
  const auth=String(req.headers.get("authorization")||"");const token=auth.startsWith("Bearer ")?auth.slice(7).trim():"";
  if(!token)throw new Error("missing GitHub OIDC token");
  const {payload}=await jwtVerify(token,JWKS,{issuer:ISSUER,audience:AUDIENCE,algorithms:["RS256"]});
  if(payload.repository!==REPOSITORY)throw new Error("repository claim rejected");
  if(payload.event_name!=="push")throw new Error("event claim rejected");
  if(payload.ref===PHRASE_REF)return "phrasal";
  if(payload.ref===HINDU_REF)return "hindu";
  if(payload.ref===GRAMMAR_REF)return "grammar";
  throw new Error("ref claim rejected");
}

Deno.serve(async(req)=>{
  if(req.method!=="POST")return json({error:"Method not allowed"},405);
  let lane:Lane;try{lane=await authorize(req)}catch(e){return json({error:e instanceof Error?e.message:"OIDC authorization failed"},401)}
  const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");if(!url||!serviceKey)return json({error:"Supabase service configuration missing"},503);
  const db=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  let body:any={};try{body=await req.json()}catch{return json({error:"Invalid JSON body"},400)}const action=String(body?.action||"");

  if(action==="run"){
    if(lane==="phrasal")return json({ok:false,lane:"phrasal",error:"Legacy server-side Phrasal AI generation is disabled; use claim + ingest ChatGPT-owned workflow"},409);
    if(lane==="grammar")return json({ok:false,lane:"grammar",error:"Legacy/server-side Grammar AI generation is disabled; use claim + ingest ChatGPT-owned workflow"},409);
    return json({ok:false,lane:"hindu",contentLane:"daily_confusion",error:"Legacy Hindu/current-news generation is disabled; submit ChatGPT-owned Daily Confusion items from Confusion_Master_Bank"},409);
  }

  if(lane==="phrasal"){
    if(action==="claim"){
      try{return json(await claimSubmittedPhrasal(db))}catch(e){return json({ok:false,lane:"phrasal",mode:"chatgpt_owned",error:errorText(e)},500)}
    }
    if(action==="ingest"){
      const runId=String(body?.runId||"");const items=Array.isArray(body?.items)?body.items:null;
      if(!runId||!items||items.length>20)return json({error:"Phrasal ingest requires runId and an array of 0-20 ChatGPT-generated slot overrides"},400);
      try{return json(await ingestSubmittedPhrasal(db,runId,items))}catch(e){return json({ok:false,lane:"phrasal",mode:"chatgpt_owned",error:errorText(e)},500)}
    }
    return json({error:"Unknown Phrasal action"},400);
  }

  if(lane==="grammar"){
    if(action==="claim"){
      try{return json(await claimSubmittedGrammar(db))}catch(e){return json({ok:false,lane:"grammar",mode:"chatgpt_owned",error:errorText(e)},500)}
    }
    if(action==="ingest"){
      const runId=String(body?.runId||"");const items=Array.isArray(body?.items)?body.items:null;
      if(!runId||!items||items.length>20)return json({error:"Grammar ingest requires runId and an array of 0-20 ChatGPT-generated slot overrides"},400);
      try{return json(await ingestSubmittedGrammar(db,runId,items))}catch(e){return json({ok:false,lane:"grammar",mode:"chatgpt_owned",error:errorText(e)},500)}
    }
    return json({error:"Unknown Grammar action"},400);
  }

  // Legacy transport ref `automation/english-hindu` now carries Daily Confusion 15.
  if(action==="ingest"){
    const items=Array.isArray(body?.items)?body.items:null;
    if(!items||items.length<1||items.length>15)return json({error:"Daily Confusion ingest requires 1-15 ChatGPT-generated master-bank items"},400);
    try{return json(await ingestSubmittedConfusionItems(db,items))}catch(e){return json({ok:false,lane:"hindu",contentLane:"daily_confusion",mode:"sheet_ingest",error:errorText(e)},500)}
  }
  if(action==="claim"){
    const{data,error}=await db.rpc("english_hindu_task_claim");
    if(error)return json({error:error.message},500);
    return json(data??{ok:true,count:0,contentLane:"daily_confusion"});
  }
  if(action==="check"){
    const runId=String(body?.runId||""),candidates=Array.isArray(body?.candidates)?body.candidates:null;
    if(!runId||!candidates||candidates.length<1||candidates.length>30)return json({error:"Daily Confusion runId and 1-30 candidates are required"},400);
    const{data,error}=await db.rpc("english_hindu_task_check_candidates",{p_run_id:runId,p_candidates:candidates});
    if(error)return json({error:error.message},500);
    return json(data??{ok:true,items:[],contentLane:"daily_confusion"});
  }
  if(action==="apply"){
    const runId=String(body?.runId||""),items=Array.isArray(body?.items)?body.items:null;
    if(!runId||!items||items.length<1||items.length>15)return json({error:"Daily Confusion runId and 1-15 items are required"},400);
    const{data,error}=await db.rpc("english_hindu_task_apply",{p_run_id:runId,p_items:items});
    if(error)return json({error:error.message},500);
    return json(data??{ok:true,contentLane:"daily_confusion"});
  }
  return json({error:"Unknown Daily Confusion action"},400);
});

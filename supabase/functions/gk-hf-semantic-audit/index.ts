import { createClient } from "npm:@supabase/supabase-js@2";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
};
const MODEL="sentence-transformers/all-MiniLM-L6-v2";
const DIMENSIONS=384;
const HF_URL=`https://router.huggingface.co/hf-inference/models/${MODEL}/pipeline/feature-extraction`;
const HF_TIMEOUT_MS=45000;
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});

function message(error:unknown){
  if(error instanceof Error)return error.message;
  if(typeof error==="string")return error;
  try{return JSON.stringify(error);}catch{return "Unknown GK semantic audit error";}
}

function clampInt(value:unknown,fallback:number,min:number,max:number){
  const n=Number(value);
  if(!Number.isFinite(n))return fallback;
  return Math.max(min,Math.min(max,Math.trunc(n)));
}

function clampNumber(value:unknown,fallback:number,min:number,max:number){
  const n=Number(value);
  if(!Number.isFinite(n))return fallback;
  return Math.max(min,Math.min(max,n));
}

function vectorText(vector:number[]){return `[${vector.join(",")}]`;}

function validateVectors(payload:unknown,expected:number):number[][]{
  if(!Array.isArray(payload))throw new Error("Hugging Face returned a non-array embedding payload");
  let rows:unknown[]=payload;
  if(expected===1&&payload.length===DIMENSIONS&&payload.every(x=>typeof x==="number"))rows=[payload];
  if(rows.length!==expected)throw new Error(`Hugging Face returned ${rows.length} vectors for ${expected} questions`);
  return rows.map((row,i)=>{
    if(!Array.isArray(row)||row.length!==DIMENSIONS||!row.every(x=>typeof x==="number"&&Number.isFinite(x))){
      throw new Error(`Hugging Face vector ${i+1} is not a valid ${DIMENSIONS}-dimension embedding`);
    }
    return row as number[];
  });
}

async function embed(texts:string[],token:string){
  const controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),HF_TIMEOUT_MS);
  try{
    const response=await fetch(HF_URL,{
      method:"POST",
      signal:controller.signal,
      headers:{Authorization:`Bearer ${token}`,"Content-Type":"application/json"},
      body:JSON.stringify({inputs:texts}),
    });
    const payload=await response.json().catch(()=>null);
    if(!response.ok){
      const detail=payload&&typeof payload==="object"&&"error" in payload?String((payload as any).error):`HTTP ${response.status}`;
      throw new Error(`Hugging Face feature extraction failed: ${detail}`);
    }
    return validateVectors(payload,texts.length);
  }catch(error:any){
    if(error?.name==="AbortError")throw new Error("Hugging Face embedding request timed out safely");
    throw error;
  }finally{clearTimeout(timer);}
}

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return reply({ok:false,error:"POST required"},405);

  try{
    const authorization=req.headers.get("Authorization")||"";
    if(!authorization.startsWith("Bearer "))return reply({ok:false,error:"Authentication required"},401);

    const url=Deno.env.get("SUPABASE_URL");
    const anon=Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRole=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if(!url||!anon||!serviceRole)throw new Error("Supabase function environment is incomplete");

    const userClient=createClient(url,anon,{global:{headers:{Authorization:authorization}}});
    const user=await userClient.auth.getUser();
    if(user.error||!user.data.user)return reply({ok:false,error:"Authentication required"},401);
    const admin=createClient(url,serviceRole,{auth:{persistSession:false,autoRefreshToken:false}});

    const body=await req.json().catch(()=>({}));
    const action=String(body?.action||"status").trim().toLowerCase();
    const batchSize=clampInt(body?.batchSize,8,1,32);
    const threshold=clampNumber(body?.threshold,0.84,0.70,0.99);
    const perQuestion=clampInt(body?.perQuestion,5,1,10);

    if(action==="status"){
      const status=await userClient.rpc("gk_get_hf_semantic_status",{p_model:MODEL});
      if(status.error)throw status.error;
      return reply({ok:true,...status.data,provider:"hf-inference",dimensions:DIMENSIONS});
    }

    let embedded=0;
    let remainingBefore:number|null=null;
    if(action==="backfill"||action==="run"){
      const token=Deno.env.get("HF_TOKEN");
      if(!token)throw new Error("HF_TOKEN is not configured for gk-hf-semantic-audit");

      const batch=await admin.rpc("gk_hf_get_embedding_batch",{p_model:MODEL,p_limit:batchSize});
      if(batch.error)throw batch.error;
      const items=Array.isArray(batch.data?.items)?batch.data.items:[];
      remainingBefore=items.length;
      if(items.length){
        const texts=items.map((item:any)=>String(item?.text||"").trim());
        if(texts.some((text:string)=>!text))throw new Error("Embedding batch contains an empty GK semantic source");
        const vectors=await embed(texts,token);
        const writes=await Promise.all(items.map((item:any,index:number)=>admin.rpc("gk_hf_store_embedding",{
          p_question_id:String(item.questionId||""),
          p_model:MODEL,
          p_content_hash:String(item.contentHash||""),
          p_embedding_text:vectorText(vectors[index]),
        })));
        const failed=writes.find(x=>x.error);
        if(failed?.error)throw failed.error;
        embedded=items.length;
      }
    }

    let refresh:unknown=null;
    if(action==="refresh"||action==="run"){
      const result=await admin.rpc("gk_hf_refresh_duplicate_candidates",{
        p_model:MODEL,
        p_min_similarity:threshold,
        p_limit_per_question:perQuestion,
      });
      if(result.error)throw result.error;
      refresh=result.data;
    }

    if(!["backfill","refresh","run"].includes(action))return reply({ok:false,error:"Unknown action"},400);

    const status=await userClient.rpc("gk_get_hf_semantic_status",{p_model:MODEL});
    if(status.error)throw status.error;
    return reply({
      ok:true,
      action,
      provider:"hf-inference",
      model:MODEL,
      dimensions:DIMENSIONS,
      embeddedThisRun:embedded,
      batchRowsFound:remainingBefore,
      refresh,
      status:status.data,
    });
  }catch(error){
    console.error("gk-hf-semantic-audit",error);
    return reply({ok:false,error:message(error)},500);
  }
});

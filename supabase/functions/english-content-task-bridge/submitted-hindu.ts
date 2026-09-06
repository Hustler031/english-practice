import { LUNA_MODEL, type LunaQuality } from "../_shared/english-antigravity-luna.ts";
import { criticHinduTone, criticHinduVocab, hinduQualityPass, isHinduCriticTransient } from "../_shared/english-hindu-luna-critic.ts";

type Db = any;
type Json = Record<string, any>;
const normWord=(v:string)=>v.toLowerCase().replace(/[^a-z0-9]/g,"");
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown Hindu ingest error");

function structuralError(item:Json){
  const required=["word","meaning","question","explanation","optionA","optionB","optionC","optionD","correctKey","sourceUrl","articleTitle","sourceName"];
  for(const key of required)if(!String(item?.[key]??"").trim())return `missing_${key}`;
  if(!["A","B","C","D"].includes(String(item.correctKey).trim().toUpperCase()))return "invalid_correctKey";
  const options=[item.optionA,item.optionB,item.optionC,item.optionD].map(x=>String(x??"").trim().toLowerCase());
  if(new Set(options).size!==4)return "duplicate_options";
  if(!/^https?:\/\//i.test(String(item.sourceUrl)))return "invalid_sourceUrl";
  return null;
}
function toneStructuralError(item:Json){
  for(const key of ["contextParaphrase","question","correctKey","explanation","sourceName","sourceUrl"])if(!String(item?.[key]??"").trim())return `missing_${key}`;
  if(!["A","B","C","D"].includes(String(item.correctKey).toUpperCase()))return "invalid_correctKey";
  if(!Array.isArray(item.options)||item.options.length!==4)return "invalid_options";
  const keys=item.options.map((x:Json)=>String(x?.key||"").toUpperCase());
  const texts=item.options.map((x:Json)=>String(x?.text||"").trim().toLowerCase());
  if(new Set(keys).size!==4||new Set(texts).size!==4||texts.some((x:string)=>!x))return "invalid_options";
  if(String(item.contextParaphrase).length>700)return "context_too_long";
  return null;
}
async function releaseClaim(db:Db,runId:string,reason:unknown){
  if(!runId)return;
  try{await db.rpc("english_release_content_task_claim",{p_run_id:runId,p_lane:"hindu",p_reason:errorText(reason).slice(0,800)})}catch{}
}
async function recordAudits(db:Db,rows:Json[]){if(!rows.length)return;const{error}=await db.rpc("english_record_content_generation_audits",{p_items:rows});if(error)throw new Error(`AUDIT_FAILED: ${error.message}`)}
function ledgerStatus(d:Json|undefined){if(!d)return"submitted";if(d.status==="published")return"published";if(d.stage==="structure")return"rejected_structure";if(d.stage==="central_duplicate_gate")return"rejected_duplicate";return"rejected_quality"}
async function persistLedger(db:Db,batchDate:string,runId:string,submitted:Json[],decisions:Map<number,Json>){
  const rows=submitted.map((item,index)=>{const d=decisions.get(index);const word=String(item?.word||"").trim();const rejected=String(d?.status||"")==="rejected";return{batchDate,runId:runId||"",submittedIndex:index,word,normalizedWord:normWord(word)||`invalid${index}`,status:ledgerStatus(d),payload:item,qualityScore:d?.score??null,criticDecision:d?.criticDecision??null,criticModel:d?.criticModel??null,rejectionStage:rejected?String(d?.stage||""):null,rejectionReason:rejected?String(d?.reason||""):null}});
  const{error}=await db.rpc("english_hindu_candidate_backlog_upsert",{p_rows:rows});if(error)throw new Error(`HINDU_LEDGER_FAILED: ${error.message}`)
}
function qualityDecision(index:number,word:string,q:LunaQuality,model:string){
  const pass=hinduQualityPass(q);
  return pass?{index,word,status:"approved",stage:"backend_critic",score:Number(q.score||0),criticModel:model,criticDecision:q.decision}:{index,word,status:"rejected",stage:"backend_critic",reason:q.decision||"quality_rejected",score:Number(q.score||0),issues:q.issues||[],criticModel:model,criticDecision:q.decision};
}
async function reviewVocab(rows:{item:Json;index:number}[]){
  const reviewed:{item:Json;index:number;score:number}[]=[];const decisions:Json[]=[];
  for(let offset=0;offset<rows.length;offset+=3){
    const group=rows.slice(offset,offset+3);
    const settled=await Promise.allSettled(group.map(async({item,index})=>({item,index,result:await criticHinduVocab(item)})));
    for(let i=0;i<settled.length;i++){
      const s=settled[i],original=group[i];
      if(s.status==="rejected"){
        const msg=errorText(s.reason);
        if(isHinduCriticTransient(s.reason))throw new Error(`HINDU_CRITIC_RETRYABLE: ${msg}`);
        throw new Error(`HINDU_CRITIC_INFRA: ${msg}`);
      }
      const{item,index,result}=s.value;const d=qualityDecision(index,String(item.word||""),result.quality,result.model);decisions.push(d);
      if(d.status==="approved")reviewed.push({index,score:d.score,item:{...item,quality:result.quality,criticProvider:"openai",criticModel:result.model,generatorProvider:String(item.generatorProvider||"chatgpt"),generatorModel:String(item.generatorModel||"scheduled_chatgpt")}})
    }
  }
  return{reviewed,decisions};
}
async function ingestToneItems(db:Db,toneItems:Json[]){
  if(!Array.isArray(toneItems)||!toneItems.length)return{submitted:0,published:0,rejected:0,retryable:0,decisions:[]};
  if(toneItems.length>3)throw new Error("HINDU_TONE_COUNT: at most 3 tone/mood items are allowed");
  const approved:Json[]=[];const decisions:Json[]=[];
  for(let i=0;i<toneItems.length;i++){
    const item=toneItems[i],structural=toneStructuralError(item);if(structural){decisions.push({index:i,status:"rejected",stage:"structure",reason:structural});continue}
    try{
      const result=await criticHinduTone(item),q=result.quality;
      if(!hinduQualityPass(q)){decisions.push({index:i,status:"rejected",stage:"backend_critic",reason:q.decision||"quality_rejected",score:q.score,issues:q.issues||[],criticModel:result.model,criticDecision:q.decision});continue}
      approved.push({...item,quality:q,criticProvider:"openai",criticModel:result.model,generatorProvider:String(item.generatorProvider||"chatgpt"),generatorModel:String(item.generatorModel||"scheduled_chatgpt")});
      decisions.push({index:i,status:"published",stage:"published",score:q.score,criticModel:result.model,criticDecision:q.decision});
    }catch(e){
      const msg=errorText(e);if(isHinduCriticTransient(e)){decisions.push({index:i,status:"retryable",stage:"backend_critic_transport",reason:msg});continue}throw e
    }
  }
  let applied:any=null;if(approved.length){const{data,error}=await db.rpc("english_apply_editorial_tone_items",{p_items:approved});if(error)throw new Error(`HINDU_TONE_APPLY_FAILED: ${error.message}`);applied=data}
  return{submitted:toneItems.length,published:approved.length,rejected:decisions.filter(x=>x.status==="rejected").length,retryable:decisions.filter(x=>x.status==="retryable").length,decisions,applied};
}

export async function ingestSubmittedHinduItems(db:Db,submitted:Json[],toneItems:Json[]=[]){
  if(!Array.isArray(submitted)||submitted.length<25||submitted.length>30)throw new Error("HINDU_SUBMITTED_COUNT: exactly 25-30 fully generated vocabulary items are required");
  const{data:claim,error:claimError}=await db.rpc("english_hindu_task_claim");if(claimError)throw new Error(`HINDU_CLAIM_FAILED: ${claimError.message}`);if(claim?.busy)throw new Error(`HINDU_BUSY: ${String(claim?.runId||"active run")}`);
  if(Number(claim?.count||0)===0){const tone=await ingestToneItems(db,toneItems);return{ok:true,lane:"hindu",mode:"sheet_ingest",complete:true,submitted:submitted.length,accepted:0,published:0,retained:0,rejected:0,decisions:[],tone}}
  const runId=String(claim?.runId||""),batchDate=String(claim?.date||new Date().toISOString().slice(0,10)),capacity=Math.max(0,Number(claim?.capacityRemaining??claim?.count??30));
  const decisions=new Map<number,Json>();const setDecision=(d:Json)=>decisions.set(Number(d.index),d);
  try{
    const seen=new Set<string>(),clean:{item:Json;index:number}[]=[];
    submitted.forEach((item,index)=>{const word=String(item?.word||"").trim(),normalized=normWord(word),err=structuralError(item);if(!normalized||seen.has(normalized)){setDecision({index,word,status:"rejected",stage:"structure",reason:"duplicate_in_submission"});return}seen.add(normalized);if(err){setDecision({index,word,status:"rejected",stage:"structure",reason:err});return}clean.push({item,index})});
    const{data:check,error:checkError}=await db.rpc("english_hindu_task_check_candidates",{p_run_id:runId,p_candidates:clean.map(({item})=>({word:item.word,familyKeys:Array.isArray(item.familyKeys)?item.familyKeys:[]}))});if(checkError)throw new Error(`HINDU_CHECK_FAILED: ${checkError.message}`);
    const checkMap=new Map((check?.items||[]).map((x:Json)=>[normWord(String(x?.word||"")),x])),criticQueue:{item:Json;index:number}[]=[];
    for(const row of clean){const result=checkMap.get(normWord(String(row.item.word)))as Json|undefined;if(result?.duplicate)setDecision({index:row.index,word:row.item.word,status:"rejected",stage:"central_duplicate_gate",reason:"historical_or_family_collision",hits:result.hits||[]});else criticQueue.push(row)}
    const review=await reviewVocab(criticQueue);for(const d of review.decisions)setDecision(d);
    const passed=review.reviewed.sort((a,b)=>b.score-a.score||a.index-b.index);
    if(passed.length>capacity)throw new Error(`HINDU_CAPACITY_CHANGED: ${passed.length} approved but only ${capacity} slots remain`);
    for(const row of passed)setDecision({index:row.index,word:row.item.word,status:"approved",stage:"approved_for_publication",score:row.score,criticModel:row.item.criticModel,criticDecision:row.item.quality?.decision});
    await persistLedger(db,batchDate,runId,submitted,decisions);
    if(!passed.length){await releaseClaim(db,runId,"No submitted Hindu item passed duplicate + Luna critic gates");const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));return{ok:true,lane:"hindu",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:0,published:0,retained:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget:true,decisions:list,tone:await ingestToneItems(db,toneItems)}}
    const{data:applied,error:applyError}=await db.rpc("english_hindu_task_apply",{p_run_id:runId,p_items:passed.map(x=>x.item)});if(applyError)throw new Error(`HINDU_APPLY_FAILED: ${applyError.message}`);
    for(const row of passed)setDecision({index:row.index,word:row.item.word,status:"published",stage:"published",score:row.score,criticModel:row.item.criticModel,criticDecision:row.item.quality?.decision});await persistLedger(db,batchDate,runId,submitted,decisions);
    await recordAudits(db,passed.map(row=>({lane:"hindu",entityKey:String(row.item.word),generatorProvider:String(row.item.generatorProvider||"chatgpt"),generatorModel:String(row.item.generatorModel||"scheduled_chatgpt"),criticProvider:"openai",criticModel:String(row.item.criticModel||LUNA_MODEL),qualityScore:row.item.quality?.score,criticDecision:row.item.quality?.decision,repairCount:0,publicationResult:"applied",metadata:{mode:"chatgpt_sheet_submission",criticOnly:true,sourceName:row.item.sourceName,sourceUrl:row.item.sourceUrl,candidateType:row.item.candidateType||"vocabulary",fixedPreposition:row.item.fixedPreposition||"",confusableWith:row.item.confusableWith||"",examValueReason:row.item.examValueReason||""}})));
    const tone=await ingestToneItems(db,toneItems),list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
    return{ok:true,lane:"hindu",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:passed.length,published:passed.length,retained:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget:true,decisions:list,applied,tone};
  }catch(e){await releaseClaim(db,runId,e);throw e}
}

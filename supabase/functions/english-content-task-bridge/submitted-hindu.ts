import { critic, hardGatesPass, GROQ_MODEL } from "../_shared/english-hybrid-ai.ts";

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
async function recordAudits(db:Db,rows:Json[]){if(!rows.length)return;const {error}=await db.rpc("english_record_content_generation_audits",{p_items:rows});if(error)throw new Error(`AUDIT_FAILED: ${error.message}`)}
function ledgerStatus(decision:Json|undefined){
  if(!decision)return "submitted";
  if(decision.status==="published")return "published";
  if(decision.status==="accepted_retained")return "accepted_retained";
  if(decision.stage==="structure")return "rejected_structure";
  if(decision.stage==="central_duplicate_gate")return "rejected_duplicate";
  return "rejected_quality";
}
async function persistLedger(db:Db,batchDate:string,runId:string,submitted:Json[],decisions:Map<number,Json>){
  const rows=submitted.map((item,index)=>{const d=decisions.get(index);const word=String(item?.word||"").trim();const rejected=String(d?.status||"").startsWith("rejected");return{
    batchDate,runId:runId||"",submittedIndex:index,word,normalizedWord:normWord(word)||`invalid${index}`,status:ledgerStatus(d),payload:item,
    qualityScore:d?.score??null,criticDecision:d?.criticDecision??null,criticModel:d?.criticModel??null,
    rejectionStage:rejected?String(d?.stage||""):null,rejectionReason:rejected?String(d?.reason||""):null,
  }});
  const {error}=await db.rpc("english_hindu_candidate_backlog_upsert",{p_rows:rows});if(error)throw new Error(`HINDU_LEDGER_FAILED: ${error.message}`);
}
async function ingestToneItems(db:Db,toneItems:Json[]){
  if(!Array.isArray(toneItems)||toneItems.length===0)return {submitted:0,published:0,rejected:0,decisions:[]};
  if(toneItems.length>3)throw new Error("HINDU_TONE_COUNT: at most 3 tone/mood items are allowed");
  const approved:Json[]=[];const decisions:Json[]=[];
  for(let i=0;i<toneItems.length;i++){
    const item=toneItems[i];const structural=toneStructuralError(item);
    if(structural){decisions.push({index:i,status:"rejected",stage:"structure",reason:structural});continue}
    try{
      const reviewed=await critic(item,{lane:"tone",mode:"chatgpt_sheet_submission",criticOnly:true,toneKind:item.toneKind||"actual",sourceName:item.sourceName,sourceUrl:item.sourceUrl});
      const score=Number(reviewed.quality?.score||0);
      if(!hardGatesPass(reviewed.quality)){decisions.push({index:i,status:"rejected",stage:"backend_critic",reason:reviewed.quality?.decision||"quality_rejected",score,issues:reviewed.quality?.issues||[],criticModel:reviewed.model});continue}
      approved.push({...item,quality:reviewed.quality,criticProvider:"groq",criticModel:reviewed.model,generatorProvider:String(item.generatorProvider||"chatgpt"),generatorModel:String(item.generatorModel||"chatgpt_scheduled_task")});
      decisions.push({index:i,status:"published",stage:"published",score,criticModel:reviewed.model});
    }catch(e){decisions.push({index:i,status:"rejected",stage:"backend_critic",reason:errorText(e)})}
  }
  let applied:any=null;
  if(approved.length){const {data,error}=await db.rpc("english_apply_editorial_tone_items",{p_items:approved});if(error)throw new Error(`HINDU_TONE_APPLY_FAILED: ${error.message}`);applied=data}
  return {submitted:toneItems.length,published:approved.length,rejected:decisions.filter(x=>x.status==="rejected").length,decisions,applied};
}

export async function ingestSubmittedHinduItems(db:Db,submitted:Json[],toneItems:Json[]=[]){
  if(!Array.isArray(submitted)||submitted.length<25||submitted.length>30)throw new Error("HINDU_SUBMITTED_COUNT: exactly 25-30 fully generated vocabulary items are required");
  const {data:claim,error:claimError}=await db.rpc("english_hindu_task_claim");if(claimError)throw new Error(`HINDU_CLAIM_FAILED: ${claimError.message}`);
  if(claim?.busy)throw new Error(`HINDU_BUSY: ${String(claim?.runId||"active run")}`);
  if(Number(claim?.count||0)===0){const tone=await ingestToneItems(db,toneItems);return{ok:true,lane:"hindu",mode:"sheet_ingest",complete:true,submitted:submitted.length,accepted:0,published:0,retained:0,rejected:0,decisions:[],tone}}

  const runId=String(claim?.runId||"");const batchDate=String(claim?.date||new Date().toISOString().slice(0,10));
  const decisions=new Map<number,Json>();const setDecision=(d:Json)=>decisions.set(Number(d.index),d);
  try{
    const seen=new Set<string>();const clean:{item:Json;index:number}[]=[];
    submitted.forEach((item,index)=>{const word=String(item?.word||"").trim();const normalized=normWord(word);const err=structuralError(item);if(!normalized||seen.has(normalized)){setDecision({index,word,status:"rejected",stage:"structure",reason:"duplicate_in_submission"});return}seen.add(normalized);if(err){setDecision({index,word,status:"rejected",stage:"structure",reason:err});return}clean.push({item,index})});

    const {data:check,error:checkError}=await db.rpc("english_hindu_task_check_candidates",{p_run_id:runId,p_candidates:clean.map(({item})=>({word:item.word,familyKeys:Array.isArray(item.familyKeys)?item.familyKeys:[]}))});
    if(checkError)throw new Error(`HINDU_CHECK_FAILED: ${checkError.message}`);
    const checkMap=new Map((check?.items||[]).map((x:Json)=>[normWord(String(x?.word||"")),x]));const criticQueue:{item:Json;index:number}[]=[];
    for(const row of clean){const result=checkMap.get(normWord(String(row.item.word))) as Json|undefined;if(result?.duplicate)setDecision({index:row.index,word:row.item.word,status:"rejected",stage:"central_duplicate_gate",reason:"historical_or_family_collision",hits:result.hits||[]});else criticQueue.push(row)}

    const passed:{item:Json;index:number;score:number}[]=[];
    for(let offset=0;offset<criticQueue.length;offset+=3){const group=criticQueue.slice(offset,offset+3);const settled=await Promise.allSettled(group.map(async({item,index})=>({item,index,reviewed:await critic(item,{lane:"hindu",mode:"chatgpt_sheet_submission",criticOnly:true,targetWord:item.word,candidateType:item.candidateType||"vocabulary",fixedPreposition:item.fixedPreposition||"",confusableWith:item.confusableWith||"",examValueReason:item.examValueReason||"",sourceName:item.sourceName,sourceUrl:item.sourceUrl,articleTitle:item.articleTitle,sourceDate:item.sourceDate||null})})));
      settled.forEach((result,groupIndex)=>{const original=group[groupIndex];if(result.status==="rejected"){setDecision({index:original.index,word:original.item.word,status:"rejected",stage:"backend_critic",reason:errorText(result.reason)});return}const{item,index,reviewed}=result.value;const score=Number(reviewed.quality?.score||0);if(!hardGatesPass(reviewed.quality)){setDecision({index,word:item.word,status:"rejected",stage:"backend_critic",reason:reviewed.quality?.decision||"quality_rejected",score,issues:reviewed.quality?.issues||[],criticModel:reviewed.model,criticDecision:reviewed.quality?.decision});return}passed.push({index,score,item:{...item,quality:reviewed.quality,criticProvider:"groq",criticModel:reviewed.model,generatorProvider:String(item.generatorProvider||"chatgpt"),generatorModel:String(item.generatorModel||"chatgpt_scheduled_task")}})})}

    passed.sort((a,b)=>b.score-a.score||a.index-b.index);
    for(const row of passed)setDecision({index:row.index,word:row.item.word,status:"accepted_retained",stage:"approved_for_publication",score:row.score,criticModel:row.item.criticModel,criticDecision:row.item.quality?.decision});
    await persistLedger(db,batchDate,runId,submitted,decisions);
    if(!passed.length){await releaseClaim(db,runId,"No submitted Hindu item passed duplicate + critic gates");const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));return{ok:true,lane:"hindu",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:0,published:0,retained:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget:false,decisions:list,tone:await ingestToneItems(db,toneItems)}}

    const {data:applied,error:applyError}=await db.rpc("english_hindu_task_apply",{p_run_id:runId,p_items:passed.map(x=>x.item)});if(applyError)throw new Error(`HINDU_APPLY_FAILED: ${applyError.message}`);
    for(const row of passed)setDecision({index:row.index,word:row.item.word,status:"published",stage:"published",score:row.score,criticModel:row.item.criticModel,criticDecision:row.item.quality?.decision});
    await persistLedger(db,batchDate,runId,submitted,decisions);
    await recordAudits(db,passed.map(row=>({lane:"hindu",entityKey:String(row.item.word),generatorProvider:String(row.item.generatorProvider||"chatgpt"),generatorModel:String(row.item.generatorModel||"chatgpt_scheduled_task"),criticProvider:"groq",criticModel:String(row.item.criticModel||GROQ_MODEL),qualityScore:row.item.quality?.score,criticDecision:row.item.quality?.decision,repairCount:0,publicationResult:"applied",metadata:{mode:"chatgpt_sheet_submission",criticOnly:true,sourceName:row.item.sourceName,sourceUrl:row.item.sourceUrl,candidateType:row.item.candidateType||"vocabulary",fixedPreposition:row.item.fixedPreposition||"",confusableWith:row.item.confusableWith||"",examValueReason:row.item.examValueReason||""}})));
    const tone=await ingestToneItems(db,toneItems);const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
    return{ok:true,lane:"hindu",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:passed.length,published:passed.length,retained:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget:true,decisions:list,applied,tone};
  }catch(e){await releaseClaim(db,runId,e);throw e}
}

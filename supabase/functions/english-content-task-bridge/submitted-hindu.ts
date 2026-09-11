type Db = any;
type Json = Record<string, any>;

const normWord=(v:string)=>v.toLowerCase().replace(/[^a-z0-9]/g,"");
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown Hindu ingest error");

function structuralError(item:Json):string|null{
  const required=["word","meaning","question","explanation","optionA","optionB","optionC","optionD","correctKey","sourceUrl","articleTitle","sourceName"];
  for(const key of required)if(!String(item?.[key]??"").trim())return `missing_${key}`;
  if(!["A","B","C","D"].includes(String(item.correctKey).trim().toUpperCase()))return "invalid_correctKey";
  const options=[item.optionA,item.optionB,item.optionC,item.optionD].map(x=>String(x??"").trim().toLowerCase());
  if(new Set(options).size!==4)return "duplicate_options";
  if(!/^https?:\/\//i.test(String(item.sourceUrl)))return "invalid_sourceUrl";
  return null;
}

function toneStructuralError(item:Json):string|null{
  for(const key of ["contextParaphrase","question","correctKey","explanation","sourceName","sourceUrl"])if(!String(item?.[key]??"").trim())return `missing_${key}`;
  if(!["A","B","C","D"].includes(String(item.correctKey).trim().toUpperCase()))return "invalid_correctKey";
  if(!Array.isArray(item.options)||item.options.length!==4)return "invalid_options";
  const keys=item.options.map((x:Json)=>String(x?.key||"").trim().toUpperCase());
  const texts=item.options.map((x:Json)=>String(x?.text||"").trim().toLowerCase());
  if(new Set(keys).size!==4||new Set(texts).size!==4||texts.some((x:string)=>!x))return "invalid_options";
  if(String(item.contextParaphrase).length>700)return "context_too_long";
  if(!/^https?:\/\//i.test(String(item.sourceUrl)))return "invalid_sourceUrl";
  return null;
}

async function releaseClaim(db:Db,runId:string,reason:unknown){
  if(!runId)return;
  try{await db.rpc("english_release_content_task_claim",{p_run_id:runId,p_lane:"hindu",p_reason:errorText(reason).slice(0,800)})}catch{/* best effort */}
}

async function recordAudits(db:Db,rows:Json[]){
  if(!rows.length)return;
  const{error}=await db.rpc("english_record_content_generation_audits",{p_items:rows});
  if(error)throw new Error(`AUDIT_FAILED: ${error.message}`);
}

function ledgerStatus(d:Json|undefined){
  if(!d)return "submitted";
  if(d.status==="published")return "published";
  if(d.stage==="structure")return "rejected_structure";
  if(d.stage==="central_duplicate_gate")return "rejected_duplicate";
  return "submitted";
}

async function persistLedger(db:Db,batchDate:string,runId:string,submitted:Json[],decisions:Map<number,Json>){
  const rows=submitted.map((item,index)=>{
    const d=decisions.get(index),word=String(item?.word||"").trim(),rejected=String(d?.status||"")==="rejected";
    return{
      batchDate,runId:runId||"",submittedIndex:index,word,normalizedWord:normWord(word)||`invalid${index}`,
      status:ledgerStatus(d),payload:item,qualityScore:null,criticDecision:null,criticModel:null,
      rejectionStage:rejected?String(d?.stage||""):null,rejectionReason:rejected?String(d?.reason||""):null,
    };
  });
  const{error}=await db.rpc("english_hindu_candidate_backlog_upsert",{p_rows:rows});
  if(error)throw new Error(`HINDU_LEDGER_FAILED: ${error.message}`);
}

async function ingestToneItems(db:Db,toneItems:Json[]){
  if(!Array.isArray(toneItems)||!toneItems.length)return{submitted:0,published:0,rejected:0,decisions:[]};
  if(toneItems.length>3)throw new Error("HINDU_TONE_COUNT: at most 3 tone/mood items are allowed");

  const approved:{item:Json;index:number}[]=[];
  const decisions:Json[]=[];
  for(let index=0;index<toneItems.length;index++){
    const item=toneItems[index],structural=toneStructuralError(item);
    if(structural){decisions.push({index,status:"rejected",stage:"structure",reason:structural});continue}
    approved.push({index,item:{...item,generatorProvider:String(item.generatorProvider||"chatgpt"),generatorModel:String(item.generatorModel||"scheduled_chatgpt")}});
  }

  let applied:any=null;
  if(approved.length){
    const{data,error}=await db.rpc("english_apply_editorial_tone_items",{p_items:approved.map(x=>x.item)});
    if(error)throw new Error(`HINDU_TONE_APPLY_FAILED: ${error.message}`);
    applied=data;
    for(const row of approved)decisions.push({index:row.index,status:"published",stage:"published",editor:"scheduled_chatgpt",secondAiCritic:false});
    await recordAudits(db,approved.map(row=>({
      lane:"tone",entityKey:`${row.item.sourceDate||"current"}:${row.index}`,
      generatorProvider:String(row.item.generatorProvider||"chatgpt"),generatorModel:String(row.item.generatorModel||"scheduled_chatgpt"),
      repairCount:0,publicationResult:"applied",
      metadata:{mode:"chatgpt_sheet_submission",secondAiCritic:false,toneKind:row.item.toneKind||"actual",sourceName:row.item.sourceName,sourceUrl:row.item.sourceUrl},
    })));
  }

  decisions.sort((a,b)=>Number(a.index)-Number(b.index));
  return{submitted:toneItems.length,published:approved.length,rejected:decisions.filter(x=>x.status==="rejected").length,decisions,applied};
}

export async function ingestSubmittedHinduItems(db:Db,submitted:Json[],toneItems:Json[]=[]){
  // Exact-10 daily publication; smaller payloads are supported for deterministic refill/recovery.
  if(!Array.isArray(submitted)||submitted.length<1||submitted.length>30)throw new Error("HINDU_SUBMITTED_COUNT: 1-30 fully generated vocabulary items are required");

  const{data:claim,error:claimError}=await db.rpc("english_hindu_task_claim");
  if(claimError)throw new Error(`HINDU_CLAIM_FAILED: ${claimError.message}`);
  if(claim?.busy)throw new Error(`HINDU_BUSY: ${String(claim?.runId||"active run")}`);

  if(Number(claim?.count||0)===0){
    const tone=await ingestToneItems(db,toneItems);
    return{ok:true,lane:"hindu",mode:"sheet_ingest",complete:true,submitted:submitted.length,accepted:0,published:0,retained:0,rejected:0,decisions:[],tone};
  }

  const runId=String(claim?.runId||""),batchDate=String(claim?.date||new Date().toISOString().slice(0,10));
  const capacity=Math.max(0,Number(claim?.capacityRemaining??claim?.count??30));
  const decisions=new Map<number,Json>();
  const setDecision=(d:Json)=>decisions.set(Number(d.index),d);

  try{
    const seen=new Set<string>(),clean:{item:Json;index:number}[]=[];
    submitted.forEach((item,index)=>{
      const word=String(item?.word||"").trim(),normalized=normWord(word),err=structuralError(item);
      if(!normalized||seen.has(normalized)){setDecision({index,word,status:"rejected",stage:"structure",reason:"duplicate_in_submission"});return}
      seen.add(normalized);
      if(err){setDecision({index,word,status:"rejected",stage:"structure",reason:err});return}
      clean.push({item,index});
    });

    const{data:check,error:checkError}=await db.rpc("english_hindu_task_check_candidates",{
      p_run_id:runId,
      p_candidates:clean.map(({item})=>({
        word:item.word,
        familyKeys:Array.isArray(item.familyKeys)?item.familyKeys:[],
        partOfSpeech:item.partOfSpeech||"",
        meaning:item.meaning||"",
        questionType:item.questionType||"",
        candidateType:item.candidateType||"",
        fixedPreposition:item.fixedPreposition||"",
        confusableWith:item.confusableWith||"",
        examValueReason:item.examValueReason||"",
        usageNote:item.usageNote||"",
        distinctLearningException:Boolean(item.distinctLearningException),
        distinctSenseException:Boolean(item.distinctSenseException),
        noveltyType:item.noveltyType||"",
        noveltyEvidence:item.noveltyEvidence||"",
        senseKey:item.senseKey||"",
      })),
    });
    if(checkError)throw new Error(`HINDU_CHECK_FAILED: ${checkError.message}`);

    const checkMap=new Map((check?.items||[]).map((x:Json)=>[normWord(String(x?.word||"")),x]));
    const approved:{item:Json;index:number}[]=[];
    for(const row of clean){
      const result=checkMap.get(normWord(String(row.item.word)))as Json|undefined;
      if(result?.duplicate){
        setDecision({
          index:row.index,
          word:row.item.word,
          status:"rejected",
          stage:"central_duplicate_gate",
          reason:String(result.reason||"genuinely_redundant_repeat"),
          collisionClass:String(result.collisionClass||"unknown"),
          hits:result.hits||[],
        });
        continue;
      }
      const item:Json={...row.item,generatorProvider:String(row.item.generatorProvider||"chatgpt"),generatorModel:String(row.item.generatorModel||"scheduled_chatgpt")};
      approved.push({item,index:row.index});
      setDecision({
        index:row.index,
        word:item.word,
        status:"submitted",
        stage:"approved_by_chatgpt_and_deterministic_gates",
        collisionClass:String(result?.collisionClass||"none"),
        duplicateGateReason:String(result?.reason||"fresh_target"),
        documentedNovelty:Boolean(result?.documentedNovelty),
        secondAiCritic:false,
      });
    }

    if(approved.length>capacity)throw new Error(`HINDU_CAPACITY_CHANGED: ${approved.length} clean items but only ${capacity} slots remain`);
    await persistLedger(db,batchDate,runId,submitted,decisions);

    if(!approved.length){
      await releaseClaim(db,runId,"No submitted Hindu item passed structural + editorial redundancy gates");
      const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
      return{ok:true,lane:"hindu",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:0,published:0,retained:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget:false,decisions:list,tone:await ingestToneItems(db,toneItems)};
    }

    const{data:applied,error:applyError}=await db.rpc("english_hindu_task_apply",{p_run_id:runId,p_items:approved.map(x=>x.item)});
    if(applyError)throw new Error(`HINDU_APPLY_FAILED: ${applyError.message}`);

    for(const row of approved)setDecision({index:row.index,word:row.item.word,status:"published",stage:"published",editor:"scheduled_chatgpt",secondAiCritic:false});
    await persistLedger(db,batchDate,runId,submitted,decisions);

    await recordAudits(db,approved.map(row=>({
      lane:"hindu",entityKey:String(row.item.word),
      generatorProvider:String(row.item.generatorProvider||"chatgpt"),generatorModel:String(row.item.generatorModel||"scheduled_chatgpt"),
      repairCount:0,publicationResult:"applied",
      metadata:{
        mode:"chatgpt_sheet_submission",
        secondAiCritic:false,
        sourceName:row.item.sourceName,
        sourceUrl:row.item.sourceUrl,
        candidateType:row.item.candidateType||"vocabulary",
        fixedPreposition:row.item.fixedPreposition||"",
        confusableWith:row.item.confusableWith||"",
        examValueReason:row.item.examValueReason||"",
        distinctLearningException:Boolean(row.item.distinctLearningException||row.item.distinctSenseException),
        noveltyType:row.item.noveltyType||"",
        noveltyEvidence:row.item.noveltyEvidence||"",
        senseKey:row.item.senseKey||"",
      },
    })));

    const tone=await ingestToneItems(db,toneItems),list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
    const completeTarget=Boolean(applied?.verify?.sourceComplete??applied?.apply?.sourceComplete??false);
    return{ok:true,lane:"hindu",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:approved.length,published:approved.length,retained:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget,decisions:list,applied,tone};
  }catch(e){
    await releaseClaim(db,runId,e);
    throw e;
  }
}

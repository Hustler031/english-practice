type Db = any;
type Json = Record<string, any>;

const CATEGORIES=new Set([
  "Confusable Words",
  "Phrasal Verb Contrast",
  "Look-alike / Spelling",
  "Homophone / Homonym",
  "Usage / Collocation",
]);
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e||"Unknown Daily Confusion ingest error");

function structuralError(item:Json):string|null{
  const bankId=String(item?.bankId??item?.bank_id??"").trim().toUpperCase();
  const category=String(item?.category??"").trim();
  const pairCluster=String(item?.pairCluster??item?.pair_cluster??"").trim();
  if(!/^CB[0-9]{4}$/.test(bankId))return "invalid_bankId";
  if(!CATEGORIES.has(category))return "invalid_category";
  if(!pairCluster)return "missing_pairCluster";
  for(const key of ["question","explanation","optionA","optionB","optionC","optionD","correctKey"]){
    if(!String(item?.[key]??"").trim())return `missing_${key}`;
  }
  if(!["A","B","C","D"].includes(String(item.correctKey).trim().toUpperCase()))return "invalid_correctKey";
  const options=[item.optionA,item.optionB,item.optionC,item.optionD].map(x=>String(x??"").trim().toLowerCase());
  if(new Set(options).size!==4)return "duplicate_options";
  return null;
}

function normalizeBankRows(raw:unknown,submitted:Json[]):Json[]{
  const source=Array.isArray(raw)&&raw.length?raw:submitted;
  if(source.length<1||source.length>500)throw new Error(`CONFUSION_BANK_SYNC_COUNT: expected 1-500 rows, got ${source.length}`);
  const seen=new Set<string>();
  const rows:Json[]=[];
  for(const x of source as Json[]){
    const bankId=String(x?.bankId??x?.bank_id??"").trim().toUpperCase();
    const category=String(x?.category??"").trim();
    const pairCluster=String(x?.pairCluster??x?.pair_cluster??"").trim();
    if(!/^CB[0-9]{4}$/.test(bankId))throw new Error(`CONFUSION_BANK_SYNC_INVALID_ID: ${bankId||"blank"}`);
    if(!CATEGORIES.has(category))throw new Error(`CONFUSION_BANK_SYNC_INVALID_CATEGORY: ${bankId} ${category}`);
    if(!pairCluster)throw new Error(`CONFUSION_BANK_SYNC_MISSING_PAIR: ${bankId}`);
    if(seen.has(bankId))throw new Error(`CONFUSION_BANK_SYNC_DUPLICATE_ID: ${bankId}`);
    seen.add(bankId);
    rows.push({
      bank_id:bankId,
      category,
      pair_cluster:pairCluster,
      learning_objective:String(x?.learningObjective??x?.learning_objective??pairCluster).trim()||pairCluster,
      priority_score:Number.isFinite(Number(x?.priorityScore??x?.priority_score))?Number(x?.priorityScore??x?.priority_score):80
    });
  }
  return rows;
}

async function syncMasterBank(db:Db,raw:unknown,submitted:Json[]){
  const rows=normalizeBankRows(raw,submitted);
  const fullSnapshot=Array.isArray(raw)&&raw.length>0;
  const{data,error}=await db.rpc("english_sync_confusion_master_bank",{
    p_rows:rows,
    p_full_snapshot:fullSnapshot,
  });
  if(error)throw new Error(`CONFUSION_BANK_SYNC_FAILED: ${error.message}`);
  if(!data?.ok||Number(data?.verified||0)!==rows.length){
    throw new Error(`CONFUSION_BANK_SYNC_VERIFY_FAILED: expected ${rows.length}, got ${Number(data?.verified||0)}`);
  }
  return data as Json;
}

async function releaseClaim(db:Db,runId:string,reason:unknown){
  if(!runId)return;
  try{await db.rpc("english_release_content_task_claim",{p_run_id:runId,p_lane:"hindu",p_reason:errorText(reason).slice(0,800)})}catch{/* best effort */}
}

async function recordAudits(db:Db,rows:Json[]){
  if(!rows.length)return;
  const{error}=await db.rpc("english_record_content_generation_audits",{p_items:rows});
  if(error)throw new Error(`CONFUSION_AUDIT_FAILED: ${error.message}`);
}

export async function ingestSubmittedConfusionItems(db:Db,submitted:Json[],masterBank?:unknown){
  if(!Array.isArray(submitted)||submitted.length<1||submitted.length>15){
    throw new Error("CONFUSION_SUBMITTED_COUNT: 1-15 fully generated Daily Confusion items are required");
  }

  // Sheet is authoritative. Bank reconciliation happens through a security-definer RPC before
  // claim/check/apply. Full snapshots refresh the whole cache; absent snapshots self-heal the
  // selected rows, so a new CBxxxx cannot fail merely because the backend cache is stale.
  const bankSync=await syncMasterBank(db,masterBank,submitted);

  const{data:claim,error:claimError}=await db.rpc("english_hindu_task_claim");
  if(claimError)throw new Error(`CONFUSION_CLAIM_FAILED: ${claimError.message}`);
  if(claim?.busy)throw new Error(`CONFUSION_BUSY: ${String(claim?.runId||"active run")}`);
  if(Number(claim?.count||0)===0){
    return{ok:true,lane:"hindu",contentLane:"daily_confusion",mode:"sheet_ingest",complete:true,submitted:submitted.length,accepted:0,published:0,rejected:0,decisions:[],bankSync};
  }

  const runId=String(claim?.runId||"");
  const capacity=Math.max(0,Number(claim?.capacityRemaining??claim?.count??15));
  const decisions=new Map<number,Json>();
  const setDecision=(d:Json)=>decisions.set(Number(d.index),d);

  try{
    const seen=new Set<string>();
    const clean:{item:Json;index:number}[]=[];
    submitted.forEach((raw,index)=>{
      const bankId=String(raw?.bankId??raw?.bank_id??"").trim().toUpperCase();
      const err=structuralError(raw);
      if(!bankId||seen.has(bankId)){setDecision({index,bankId,status:"rejected",stage:"structure",reason:"duplicate_bank_in_submission"});return}
      seen.add(bankId);
      if(err){setDecision({index,bankId,status:"rejected",stage:"structure",reason:err});return}
      clean.push({index,item:{...raw,bankId,category:String(raw.category).trim(),pairCluster:String(raw?.pairCluster??raw?.pair_cluster??"").trim(),generatorProvider:String(raw.generatorProvider||"chatgpt"),generatorModel:String(raw.generatorModel||"scheduled_chatgpt")}});
    });

    if(!clean.length){
      await releaseClaim(db,runId,"No submitted Daily Confusion item passed structural gates");
      const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
      return{ok:true,lane:"hindu",contentLane:"daily_confusion",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:0,published:0,rejected:list.length,completeTarget:false,decisions:list,bankSync};
    }

    const{data:check,error:checkError}=await db.rpc("english_hindu_task_check_candidates",{
      p_run_id:runId,
      p_candidates:clean.map(({item})=>({bankId:item.bankId,category:item.category,pairCluster:item.pairCluster})),
    });
    if(checkError)throw new Error(`CONFUSION_CHECK_FAILED: ${checkError.message}`);

    const checkMap=new Map((check?.items||[]).map((x:Json)=>[String(x?.bankId||"").toUpperCase(),x]));
    const approved:{item:Json;index:number}[]=[];
    for(const row of clean){
      const checked=checkMap.get(row.item.bankId) as Json|undefined;
      if(!checked){setDecision({index:row.index,bankId:row.item.bankId,status:"rejected",stage:"bank_check",reason:"candidate_not_returned"});continue}
      if(checked.duplicate){setDecision({index:row.index,bankId:row.item.bankId,status:"rejected",stage:"bank_check",reason:String(checked.reason||"same_day_bank_repeat")});continue}
      approved.push(row);
      setDecision({index:row.index,bankId:row.item.bankId,status:"submitted",stage:"bank_check",reason:"valid_master_bank_candidate",secondAiCritic:false});
    }

    if(approved.length>capacity)throw new Error(`CONFUSION_CAPACITY_CHANGED: ${approved.length} clean items but only ${capacity} slots remain`);
    if(!approved.length){
      await releaseClaim(db,runId,"No submitted Daily Confusion item remained after bank checks");
      const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
      return{ok:true,lane:"hindu",contentLane:"daily_confusion",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:0,published:0,rejected:list.filter(x=>x.status==="rejected").length,completeTarget:false,decisions:list,bankSync};
    }

    const{data:applied,error:applyError}=await db.rpc("english_hindu_task_apply",{p_run_id:runId,p_items:approved.map(x=>x.item)});
    if(applyError)throw new Error(`CONFUSION_APPLY_FAILED: ${applyError.message}`);

    for(const row of approved)setDecision({index:row.index,bankId:row.item.bankId,status:"published",stage:"published",editor:"scheduled_chatgpt",secondAiCritic:false});
    await recordAudits(db,approved.map(row=>({
      lane:"hindu",
      entityKey:String(row.item.bankId),
      generatorProvider:String(row.item.generatorProvider||"chatgpt"),
      generatorModel:String(row.item.generatorModel||"scheduled_chatgpt"),
      repairCount:0,
      publicationResult:"applied",
      metadata:{mode:"daily_confusion_sheet_submission",contentLane:"daily_confusion",bankId:row.item.bankId,category:row.item.category,pairCluster:row.item.pairCluster,secondAiCritic:false,bankSyncMode:bankSync.mode},
    })));

    const list=[...decisions.values()].sort((a,b)=>Number(a.index)-Number(b.index));
    const completeTarget=Boolean(applied?.verify?.sourceComplete??applied?.apply?.sourceComplete??false);
    return{ok:true,lane:"hindu",contentLane:"daily_confusion",mode:"sheet_ingest",runId,submitted:submitted.length,accepted:approved.length,published:approved.length,rejected:list.filter(x=>x.status==="rejected").length,completeTarget,decisions:list,applied,bankSync};
  }catch(e){
    await releaseClaim(db,runId,e);
    throw e;
  }
}

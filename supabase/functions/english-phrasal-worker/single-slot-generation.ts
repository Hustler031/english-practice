import {
  fourOptionCodeGate,
  runAntigravityLunaPipeline,
} from "../_shared/english-antigravity-luna.ts";

type Json = Record<string, any>;

const normText=(v:string)=>v.toLowerCase().replace(/[^a-z0-9]+/g," ").trim();
const compactPhrasalTarget=(v:string)=>{
  const s=String(v||"").trim();
  if(!s||s.length>80)return false;
  const words=s.replace(/[\/|]+/g," ").match(/[A-Za-z]+(?:'[A-Za-z]+)?/g)||[];
  return words.length>=2&&words.length<=6;
};
const keyedReferenceOption=(reference:Json)=>{
  const key=String(reference?.correctKey||"").toUpperCase();
  if(!["A","B","C","D"].includes(key))return "";
  const hit=Array.isArray(reference?.options)
    ?reference.options.find((x:any)=>String(x?.key||"").toUpperCase()===key)
    :null;
  return String(hit?.text||reference?.[`option${key}`]||"").trim();
};
function resolvePhrasalTarget(item:Json,reference:Json,conceptId:string){
  const raw=String(reference?.word||item?.word||"").trim();
  if(compactPhrasalTarget(raw))return raw;
  const idMatch=String(conceptId||"").match(/^(?:PV_|phrasal_)(.+)$/i);
  if(idMatch){
    const fromId=idMatch[1].replace(/_/g," ").trim();
    if(compactPhrasalTarget(fromId))return fromId;
  }
  const question=String(reference?.question||item?.question||"");
  const keyed=keyedReferenceOption(reference);
  if(/phrasal verb|which pair|_{2,}|=\s*\?/i.test(question)&&compactPhrasalTarget(keyed))return keyed;
  return "";
}
const sha256=async(text:string)=>{
  const bytes=new TextEncoder().encode(text.trim().toLowerCase().replace(/\s+/g," "));
  const digest=await crypto.subtle.digest("SHA-256",bytes);
  return Array.from(new Uint8Array(digest)).map(x=>x.toString(16).padStart(2,"0")).join("");
};

const baseItemSchema:any={
  type:"object",additionalProperties:false,
  required:["word","senseKey","senseGloss","question","questionType","optionA","optionB","optionC","optionD","correctKey","explanation","tip","usageNote","example","memoryAid","related","difficulty"],
  properties:{
    word:{type:"string"},senseKey:{type:"string",pattern:"^[a-z0-9_]{2,80}$"},senseGloss:{type:"string",minLength:2,maxLength:240},
    question:{type:"string"},questionType:{type:"string"},optionA:{type:"string"},optionB:{type:"string"},optionC:{type:"string"},optionD:{type:"string"},
    correctKey:{type:"string",enum:["A","B","C","D"]},explanation:{type:"string"},tip:{type:"string"},usageNote:{type:"string"},example:{type:"string"},
    memoryAid:{type:"string"},related:{type:"string"},difficulty:{type:"string",enum:["Medium","Hard"]},
  },
};
function phrasalSchema(family:string,targetWord:string){
  const schema=structuredClone(baseItemSchema) as any;
  schema.properties.word={type:"string",enum:[targetWord]};
  if(family==="recall"){
    schema.properties.questionType={type:"string",enum:["Reverse Recall Card"]};
    schema.properties.optionA={type:"string",enum:["Yaad tha"]};
    schema.properties.optionB={type:"string",enum:["Confused"]};
    schema.properties.optionC={type:"string",enum:["Bhool gaya"]};
    schema.properties.optionD={type:"string",enum:[""]};
    schema.properties.correctKey={type:"string",enum:["A"]};
  }else{
    schema.properties.optionA={type:"string",minLength:1};schema.properties.optionB={type:"string",minLength:1};
    schema.properties.optionC={type:"string",minLength:1};schema.properties.optionD={type:"string",minLength:1};
    if(family==="context_fill")schema.properties.questionType={type:"string",enum:["Context Fill"]};
  }
  return schema;
}

function normalizeContextFillDraft(draft:Json,assignment:Json){
  if(String(assignment?.requestedFamily||"").toLowerCase()!=="context_fill")return;
  const targetWord=String(assignment?.targetWord||"").trim();if(!targetWord)return;
  draft.word=targetWord;draft.questionType="Context Fill";
  const keys=["A","B","C","D"] as const;
  const current=String(draft?.correctKey||"").toUpperCase();
  const key=keys.includes(current as any)?current as "A"|"B"|"C"|"D":keys[Math.abs(String(assignment?.conceptId||targetWord).split("").reduce((n:number,ch:string)=>n+ch.charCodeAt(0),0))%4];
  const targetNorm=normText(targetWord),seen=new Set<string>(),distractors:string[]=[];
  const add=(value:unknown)=>{const text=String(value||"").trim(),norm=normText(text);if(!text||!norm||norm===targetNorm||seen.has(norm))return;seen.add(norm);distractors.push(text)};
  keys.forEach(k=>add(draft?.[`option${k}`]));
  const reference=assignment?.referenceVariant||{};
  if(Array.isArray(reference?.options))reference.options.forEach((x:any)=>{const t=String(x?.text||"").trim();if(compactPhrasalTarget(t))add(t)});
  keys.forEach(k=>{const t=String(reference?.[`option${k}`]||"").trim();if(compactPhrasalTarget(t))add(t)});
  String(reference?.related||"").split(/[;,|]/).forEach((t:string)=>{if(compactPhrasalTarget(t))add(t)});
  draft.correctKey=key;let cursor=0;
  keys.forEach(k=>{if(k===key)draft[`option${k}`]=targetWord;else if(distractors[cursor])draft[`option${k}`]=distractors[cursor++]});
}
function normalizeRecallDraft(draft:Json,assignment:Json){
  if(String(assignment?.requestedFamily||"").toLowerCase()!=="recall")return;
  const targetWord=String(assignment?.targetWord||"").trim();if(!targetWord)return;
  draft.word=targetWord;draft.questionType="Reverse Recall Card";draft.optionA="Yaad tha";draft.optionB="Confused";draft.optionC="Bhool gaya";draft.optionD="";draft.correctKey="A";
}
function phrasalCodeGate(draft:Json,assignment:Json){
  const issues:string[]=[];
  const requested=String(assignment.requestedFamily||"recognition").toLowerCase();
  const targetWord=String(assignment.targetWord||"").trim();
  const preferredSenseKey=String(assignment.preferredSenseKey||"legacy_default");
  const outputSenseKey=String(draft?.senseKey||"").trim(),outputSenseGloss=String(draft?.senseGloss||"").trim();
  if(!/^[a-z0-9_]{2,80}$/.test(outputSenseKey))issues.push("senseKey must be valid lower_snake_case");
  if(!outputSenseGloss)issues.push("senseGloss is blank");
  if(preferredSenseKey!=="legacy_default"&&outputSenseKey!==preferredSenseKey)issues.push(`senseKey must remain ${preferredSenseKey}`);
  if(targetWord&&normText(String(draft?.word||""))!==normText(targetWord))issues.push("target phrasal verb word must be preserved exactly");
  if(!["Medium","Hard"].includes(String(draft?.difficulty||"")))issues.push("difficulty must be Medium or Hard");
  if(requested==="recall"){
    if(draft?.questionType!=="Reverse Recall Card")issues.push("recall questionType must be Reverse Recall Card");
    if(draft?.optionA!=="Yaad tha"||draft?.optionB!=="Confused"||draft?.optionC!=="Bhool gaya"||draft?.optionD!==""||draft?.correctKey!=="A")issues.push("Reverse Recall options/key contract drifted");
    if(!String(draft?.question||"").trim())issues.push("question is blank");if(!String(draft?.explanation||"").trim())issues.push("explanation is blank");
    const target=normText(targetWord),front=normText(String(draft?.question||""));if(target&&front.includes(target))issues.push("Reverse Recall front leaks the target phrasal verb");
  }else{
    issues.push(...fourOptionCodeGate(draft,"correctKey"));
    if(requested==="context_fill"&&draft?.questionType!=="Context Fill")issues.push("context-fill questionType must be Context Fill");
  }
  return issues;
}

const legacyOption=(reference:Json,key:"A"|"B"|"C"|"D")=>{
  const hit=Array.isArray(reference?.options)?reference.options.find((x:any)=>String(x?.key||"").toUpperCase()===key):null;
  return String(hit?.text??reference?.[`option${key}`]??"").trim();
};
function legacyPhrasal(item:Json){
  const conceptId=String(item?.phrasalConceptId||item?.conceptId||"");
  const requested=String(item?.requestedQuestionFamily||item?.missingFamily||item?.phrasalQuestionFamily||"recognition").toLowerCase();
  const legacy=String(item?.legacyFamily||item?.missingFamily||item?.phrasalQuestionFamily||requested||"recognition").toLowerCase();
  const reference=Object.keys(item?.referenceVariant||{}).length?item.referenceVariant:item;
  const targetWord=resolvePhrasalTarget(item,reference,conceptId);
  if(!conceptId||!targetWord)return null;
  if(item?.contentGap===true||String(item?.slotStatus||"").toLowerCase()==="content_gap")return null;
  if(requested==="context_fill"||requested!==legacy)return null;
  const draft:Json={
    word:targetWord,senseKey:String(item?.senseKey||"legacy_default"),senseGloss:String(item?.senseGloss||""),question:String(reference?.question||"").trim(),questionType:String(reference?.questionType||"").trim(),
    optionA:legacyOption(reference,"A"),optionB:legacyOption(reference,"B"),optionC:legacyOption(reference,"C"),optionD:legacyOption(reference,"D"),correctKey:String(reference?.correctKey||"").toUpperCase(),
    explanation:String(reference?.explanation||"").trim(),tip:String(reference?.tip||""),usageNote:String(reference?.usageNote||""),example:String(reference?.example||reference?.exampleSentence||""),
    memoryAid:String(reference?.memoryAid||""),related:String(reference?.related||reference?.relatedWords||""),difficulty:String(reference?.difficulty||item?.difficulty||"Medium"),sourcePage:String(reference?.sourcePage||""),sourceUrl:String(reference?.sourceUrl||""),
  };
  if(!draft.question||!draft.explanation)return null;
  if(requested==="recall"){
    if(draft.questionType!=="Reverse Recall Card"||draft.optionA!=="Yaad tha"||draft.optionB!=="Confused"||draft.optionC!=="Bhool gaya"||draft.optionD!==""||draft.correctKey!=="A")return null;
    if(normText(draft.question).includes(normText(targetWord)))return null;
  }else if(fourOptionCodeGate(draft,"correctKey").length)return null;
  return {...draft,conceptId,requestedQuestionFamily:requested,questionFamily:requested,legacyFamily:legacy,family:requested,baseQuestionId:String(reference?.id||reference?.questionId||item?.id||item?.questionId||""),contentGap:false,
    generatorProvider:"legacy_bank",generatorModel:"canonical_bank",criticProvider:null,criticModel:null,quality:null,repairCount:0,codeRepairCount:0,rareRescue:false,writerRequests:0,criticRequests:0,
    antigravityRequests:0,geminiWriterRequests:0,antigravityFallback:false,antigravityFallbackReason:"",variantFingerprint:"",variantKey:""};
}

function canonicalRecallCue(reference:Json,targetWord:string){
  let cue=keyedReferenceOption(reference).replace(/\s+/g," ").trim().replace(/[.?!]+$/g,"").trim();
  if(!cue)return "";const target=normText(targetWord),normalized=normText(cue);if(!normalized||(target&&normalized.includes(target)))return "";return cue;
}
async function deterministicRecallFromCanonical(item:Json){
  const requested=String(item?.requestedQuestionFamily||item?.missingFamily||item?.phrasalQuestionFamily||"recognition").toLowerCase();if(requested!=="recall")return null;
  const conceptId=String(item?.phrasalConceptId||item?.conceptId||"");
  const legacy=String(item?.legacyFamily||item?.missingFamily||item?.phrasalQuestionFamily||requested||"recall").toLowerCase();
  const reference=Object.keys(item?.referenceVariant||{}).length?item.referenceVariant:item;
  const targetWord=resolvePhrasalTarget(item,reference,conceptId),cue=canonicalRecallCue(reference,targetWord),explanation=String(reference?.explanation||"").trim();
  if(!conceptId||!targetWord||!cue||!explanation)return null;
  const preferredSenseKey=String(item?.senseKey||"legacy_default"),knownSenses=Array.isArray(item?.knownSenses)?item.knownSenses:[],sourceDifficulty=String(reference?.difficulty||item?.difficulty||"Medium");
  const assignment={conceptId,preferredSenseKey,requestedFamily:"recall",legacyFamily:legacy,targetWord,referenceVariant:reference,knownSenses,selectedVariantCooled:item?.selectedVariantCooled===true,recentConceptStems:Array.isArray(item?.recentConceptStems)?item.recentConceptStems:[],recentVariantFingerprints:Array.isArray(item?.recentVariantFingerprints)?item.recentVariantFingerprints:[],sourceMode:"canonical_recall_transform"};
  const draft:Json={word:targetWord,senseKey:preferredSenseKey,senseGloss:cue,question:`Which phrasal verb means “${cue}”?`,questionType:"Reverse Recall Card",optionA:"Yaad tha",optionB:"Confused",optionC:"Bhool gaya",optionD:"",correctKey:"A",explanation,tip:String(reference?.tip||""),usageNote:String(reference?.usageNote||""),example:String(reference?.example||reference?.exampleSentence||""),memoryAid:String(reference?.memoryAid||""),related:String(reference?.related||reference?.relatedWords||""),difficulty:["Medium","Hard"].includes(sourceDifficulty)?sourceDifficulty:"Medium"};
  const instructions=`You are the repair writer for exactly ONE SSC CGL Reverse Recall card grounded in canonical Phrasal evidence. Code already built the candidate. Never change the assigned phrasal verb, evidenced sense, or Reverse Recall controls. The front must hide targetWord. Only repair critic-identified wording or teaching defects. Return one complete JSON item.`;
  const reviewed=await runAntigravityLunaPipeline<any>({instructions,input:assignment,schema:phrasalSchema("recall",targetWord),criticContext:{lane:"phrasal",...assignment,recallContract:{front:"meaning/situation cue; target hidden",A:"Yaad tha",B:"Confused",C:"Bhool gaya",D:"",correctKey:"A",questionType:"Reverse Recall Card"}},initialItem:draft,initialGeneratorProvider:"deterministic_recall",initialGeneratorModel:"canonical_bank_transform",structuralGate:(candidate:Json)=>{normalizeRecallDraft(candidate,assignment);return phrasalCodeGate(candidate,assignment)},repairInput:(original,current,quality)=>({originalAssignment:original,currentItem:current,critic:{decision:quality.decision,issues:quality.issues,repairInstruction:quality.repairInstruction}})});
  const outputSenseKey=String(reviewed.item?.senseKey||"").trim(),outputSenseGloss=String(reviewed.item?.senseGloss||"").trim();
  if(!/^[a-z0-9_]{2,80}$/.test(outputSenseKey)||!outputSenseGloss)throw new Error(`PHRASAL_SENSE_INVALID: ${conceptId}`);
  if(preferredSenseKey!=="legacy_default"&&outputSenseKey!==preferredSenseKey)throw new Error(`PHRASAL_SENSE_DRIFT: expected ${preferredSenseKey}, got ${outputSenseKey}`);
  const fp=await sha256(`${conceptId}|${outputSenseKey}|recall|${reviewed.item.question}`);
  return {...reviewed.item,conceptId,senseKey:outputSenseKey,senseGloss:outputSenseGloss,requestedQuestionFamily:"recall",questionFamily:"recall",legacyFamily:legacy,family:"recall",baseQuestionId:String(reference?.id||reference?.questionId||item?.id||item?.questionId||""),contentGap:Boolean(item?.contentGap),generatorProvider:reviewed.generatorProvider,generatorModel:reviewed.generatorModel,criticProvider:reviewed.criticProvider,criticModel:reviewed.criticModel,quality:reviewed.quality,repairCount:reviewed.repairCount,codeRepairCount:reviewed.codeRepairCount,rareRescue:reviewed.rareRescue,writerRequests:reviewed.writerRequests,criticRequests:reviewed.criticRequests,antigravityRequests:reviewed.antigravityRequests,geminiWriterRequests:reviewed.geminiWriterRequests,antigravityFallback:reviewed.antigravityFallback,antigravityFallbackReason:reviewed.antigravityFallbackReason,variantFingerprint:fp,variantKey:`recall_${fp.slice(0,16)}`};
}

async function generatePhrasal(item:Json){
  const conceptId=String(item?.phrasalConceptId||item?.conceptId||"");
  const requested=String(item?.requestedQuestionFamily||item?.missingFamily||item?.phrasalQuestionFamily||"recognition").toLowerCase();
  const legacy=String(item?.legacyFamily||item?.missingFamily||item?.phrasalQuestionFamily||requested||"recognition").toLowerCase();
  const reference=Object.keys(item?.referenceVariant||{}).length?item.referenceVariant:item;
  const knownSenses=Array.isArray(item?.knownSenses)?item.knownSenses:[],preferredSenseKey=String(item?.senseKey||"legacy_default"),targetWord=resolvePhrasalTarget(item,reference,conceptId);
  if(!conceptId||!targetWord||!String(reference?.question||reference?.explanation||reference?.word||"").trim())throw new Error(`PHRASAL_REFERENCE_MISSING_OR_TARGET_UNRESOLVED: ${conceptId||"unknown"}`);
  const assignment={conceptId,preferredSenseKey,requestedFamily:requested,legacyFamily:legacy,targetWord,referenceVariant:reference,knownSenses,selectedVariantCooled:item?.selectedVariantCooled===true,recentConceptStems:Array.isArray(item?.recentConceptStems)?item.recentConceptStems:[],recentVariantFingerprints:Array.isArray(item?.recentVariantFingerprints)?item.recentVariantFingerprints:[]};
  const instructions=`You are the WRITER for exactly ONE SSC CGL Phrasal Verb learning card selected by Central Intelligence. Central Intelligence owns WHAT concept, sense and question family must be taught; you own only HOW to express that fixed assignment well. Preserve targetWord exactly and preserve the exact meaning/sense evidenced by referenceVariant. If preferredSenseKey is not legacy_default, reuse it exactly; otherwise create a short lower_snake_case key for this evidenced sense and a precise senseGloss. requestedFamily is binding.\ncontext_fill: natural sentence-level cloze/usage MCQ, four close phrasal-verb options, exactly one defensible answer, questionType exactly Context Fill, and do not repeat recentConceptStems.\nrecall: Reverse Recall front must hide targetWord; controls are fixed A=Yaad tha, B=Confused, C=Bhool gaya, D blank, correctKey=A.\nrecognition/confusion: normal four-option SSC MCQ with close defensible distractors.\nDifficulty Medium or Hard. Return one complete JSON item only.`;
  const reviewed=await runAntigravityLunaPipeline<any>({instructions,input:assignment,schema:phrasalSchema(requested,targetWord),criticContext:{lane:"phrasal",...assignment,recallContract:requested==="recall"?{front:"meaning/situation cue; target hidden",A:"Yaad tha",B:"Confused",C:"Bhool gaya",D:"",correctKey:"A",questionType:"Reverse Recall Card"}:null},structuralGate:(draft:Json)=>{normalizeContextFillDraft(draft,assignment);normalizeRecallDraft(draft,assignment);return phrasalCodeGate(draft,assignment)},repairInput:(original,current,quality)=>({originalAssignment:original,currentItem:current,critic:{decision:quality.decision,issues:quality.issues,repairInstruction:quality.repairInstruction}})});
  const outputSenseKey=String(reviewed.item?.senseKey||"").trim(),outputSenseGloss=String(reviewed.item?.senseGloss||"").trim();
  if(!/^[a-z0-9_]{2,80}$/.test(outputSenseKey)||!outputSenseGloss)throw new Error(`PHRASAL_SENSE_INVALID: ${conceptId}`);
  if(preferredSenseKey!=="legacy_default"&&outputSenseKey!==preferredSenseKey)throw new Error(`PHRASAL_SENSE_DRIFT: expected ${preferredSenseKey}, got ${outputSenseKey}`);
  const fp=await sha256(`${conceptId}|${outputSenseKey}|${requested}|${reviewed.item.question}`);
  return {...reviewed.item,word:targetWord,conceptId,senseKey:outputSenseKey,senseGloss:outputSenseGloss,requestedQuestionFamily:requested,questionFamily:requested,legacyFamily:legacy,family:requested==="context_fill"?"recognition":requested,baseQuestionId:String(reference?.id||reference?.questionId||item?.id||item?.questionId||""),contentGap:Boolean(item?.contentGap),generatorProvider:reviewed.generatorProvider,generatorModel:reviewed.generatorModel,criticProvider:reviewed.criticProvider,criticModel:reviewed.criticModel,quality:reviewed.quality,repairCount:reviewed.repairCount,codeRepairCount:reviewed.codeRepairCount,rareRescue:reviewed.rareRescue,writerRequests:reviewed.writerRequests,criticRequests:reviewed.criticRequests,antigravityRequests:reviewed.antigravityRequests,geminiWriterRequests:reviewed.geminiWriterRequests,antigravityFallback:reviewed.antigravityFallback,antigravityFallbackReason:reviewed.antigravityFallbackReason,variantFingerprint:fp,variantKey:`ai_${fp.slice(0,16)}`};
}

export async function finalizeSinglePhrasalItem(item:Json){
  const reused=legacyPhrasal(item);if(reused)return reused;
  const recall=await deterministicRecallFromCanonical(item);if(recall)return recall;
  return await generatePhrasal(item);
}

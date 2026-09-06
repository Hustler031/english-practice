from pathlib import Path

shared = Path('supabase/functions/_shared/english-antigravity-luna.ts')
s = shared.read_text()
old_sig = '''  structuralGate:(item:T)=>string[];\n  repairInput?:(original:unknown,current:T,quality:LunaQuality|{decision:"CODE";issues:string[];repairInstruction:string})=>unknown;\n}):Promise<{'''
new_sig = '''  structuralGate:(item:T)=>string[];\n  initialItem?:T;\n  initialGeneratorProvider?:string;\n  initialGeneratorModel?:string;\n  repairInput?:(original:unknown,current:T,quality:LunaQuality|{decision:"CODE";issues:string[];repairInstruction:string})=>unknown;\n}):Promise<{'''
assert old_sig in s, 'shared signature marker missing'
s = s.replace(old_sig, new_sig, 1)
old_init = '''  let first=await antigravityJson<T>(args.instructions,args.input,{schema:args.schema});\n  let current=first.data;\n  let finalProvider=first.provider as string,finalModel=first.model;\n  let writerRequests=1,criticRequests=0,codeRepairCount=0;'''
new_init = '''  let current:T;\n  let finalProvider:string,finalModel:string;\n  let writerRequests=0,criticRequests=0,codeRepairCount=0;\n  if(args.initialItem!==undefined){\n    current=args.initialItem;\n    finalProvider=args.initialGeneratorProvider||"deterministic";\n    finalModel=args.initialGeneratorModel||"canonical_transform";\n  }else{\n    const first=await antigravityJson<T>(args.instructions,args.input,{schema:args.schema});\n    current=first.data;\n    finalProvider=first.provider as string;finalModel=first.model;\n    writerRequests=1;\n  }'''
assert old_init in s, 'shared init marker missing'
s = s.replace(old_init, new_init, 1)
shared.write_text(s)

p = Path('supabase/functions/english-content-task-bridge/phrasal-generation.ts')
t = p.read_text()
marker = 'async function generatePhrasal(item: Json) {'
assert marker in t, 'generatePhrasal marker missing'
insert = r'''function canonicalRecallCue(reference: Json, targetWord: string) {
  let cue = keyedReferenceOption(reference).replace(/\s+/g, " ").trim();
  cue = cue.replace(/[.?!]+$/g, "").trim();
  if (!cue) return "";
  const target = normText(targetWord), normalized = normText(cue);
  if (!normalized || (target && normalized.includes(target))) return "";
  return cue;
}

async function deterministicRecallFromCanonical(item: Json) {
  const requested = String(item?.requestedQuestionFamily || item?.missingFamily || item?.phrasalQuestionFamily || "recognition").toLowerCase();
  if (requested !== "recall") return null;
  const conceptId = String(item?.phrasalConceptId || item?.conceptId || "");
  const legacy = String(item?.legacyFamily || item?.missingFamily || item?.phrasalQuestionFamily || requested || "recall").toLowerCase();
  const reference = Object.keys(item?.referenceVariant || {}).length ? item.referenceVariant : item;
  const targetWord = resolvePhrasalTarget(item, reference, conceptId);
  const cue = canonicalRecallCue(reference, targetWord);
  const explanation = String(reference?.explanation || "").trim();
  if (!conceptId || !targetWord || !cue || !explanation) return null;

  const preferredSenseKey = String(item?.senseKey || "legacy_default");
  const knownSenses = Array.isArray(item?.knownSenses) ? item.knownSenses : [];
  const sourceDifficulty = String(reference?.difficulty || item?.difficulty || "Medium");
  const assignment = {
    conceptId,
    preferredSenseKey,
    requestedFamily: "recall",
    legacyFamily: legacy,
    targetWord,
    referenceVariant: reference,
    knownSenses,
    selectedVariantCooled: item?.selectedVariantCooled === true,
    recentConceptStems: Array.isArray(item?.recentConceptStems) ? item.recentConceptStems : [],
    recentVariantFingerprints: Array.isArray(item?.recentVariantFingerprints) ? item.recentVariantFingerprints : [],
    sourceMode: "canonical_recall_transform",
  };
  const draft: Json = {
    word: targetWord,
    senseKey: preferredSenseKey,
    senseGloss: cue,
    question: `Which phrasal verb means “${cue}”?`,
    questionType: "Reverse Recall Card",
    optionA: "Yaad tha",
    optionB: "Confused",
    optionC: "Bhool gaya",
    optionD: "",
    correctKey: "A",
    explanation,
    tip: String(reference?.tip || ""),
    usageNote: String(reference?.usageNote || ""),
    example: String(reference?.example || reference?.exampleSentence || ""),
    memoryAid: String(reference?.memoryAid || ""),
    related: String(reference?.related || reference?.relatedWords || ""),
    difficulty: ["Medium", "Hard"].includes(sourceDifficulty) ? sourceDifficulty : "Medium",
  };
  const instructions = `You are Antigravity, the repair writer for exactly ONE SSC CGL Reverse Recall card grounded in a canonical Phrasal reference. Code has already built the recall candidate from the keyed canonical meaning. Do not change the assigned phrasal verb, family or evidenced sense. Only if the independent critic requests repair, improve the meaning/situation cue or teaching explanation minimally. The front must hide targetWord. Reverse Recall controls are fixed: questionType=\"Reverse Recall Card\"; A=\"Yaad tha\"; B=\"Confused\"; C=\"Bhool gaya\"; D=\"\"; correctKey=\"A\". Return the complete JSON item only.`;

  let reviewed: Awaited<ReturnType<typeof runAntigravityLunaPipeline<any>>>;
  try {
    reviewed = await runAntigravityLunaPipeline<any>({
      instructions,
      input: assignment,
      schema: phrasalSchema("recall", targetWord),
      criticContext: {
        lane: "phrasal",
        ...assignment,
        recallContract: { front: "meaning/situation cue; target hidden", A: "Yaad tha", B: "Confused", C: "Bhool gaya", D: "", correctKey: "A", questionType: "Reverse Recall Card" },
      },
      initialItem: draft,
      initialGeneratorProvider: "deterministic_recall",
      initialGeneratorModel: "canonical_bank_transform",
      structuralGate: (candidate: Json) => { normalizeRecallDraft(candidate, assignment); return phrasalCodeGate(candidate, assignment); },
      repairInput: (original, current, quality) => ({
        originalAssignment: original,
        currentItem: current,
        critic: { decision: quality.decision, issues: quality.issues, repairInstruction: quality.repairInstruction },
      }),
    });
  } catch (e) {
    throw new Error(`PHRASAL_ITEM_FAILED ${conceptId}/recall: ${errorText(e)}`);
  }

  const outputSenseKey = String(reviewed.item?.senseKey || "").trim();
  const outputSenseGloss = String(reviewed.item?.senseGloss || "").trim();
  if (!/^[a-z0-9_]{2,80}$/.test(outputSenseKey) || !outputSenseGloss) throw new Error(`PHRASAL_SENSE_INVALID: ${conceptId}`);
  if (preferredSenseKey !== "legacy_default" && outputSenseKey !== preferredSenseKey) throw new Error(`PHRASAL_SENSE_DRIFT: expected ${preferredSenseKey}, got ${outputSenseKey}`);

  const fp = await sha256(`${conceptId}|${outputSenseKey}|recall|${reviewed.item.question}`);
  return {
    ...reviewed.item,
    word: targetWord,
    conceptId,
    senseKey: outputSenseKey,
    senseGloss: outputSenseGloss,
    requestedQuestionFamily: "recall",
    questionFamily: "recall",
    legacyFamily: legacy,
    family: "recall",
    baseQuestionId: String(reference?.id || reference?.questionId || item?.id || item?.questionId || ""),
    contentGap: Boolean(item?.contentGap),
    generatorProvider: reviewed.generatorProvider,
    generatorModel: reviewed.generatorModel,
    criticProvider: reviewed.criticProvider,
    criticModel: reviewed.criticModel,
    quality: reviewed.quality,
    repairCount: reviewed.repairCount,
    codeRepairCount: reviewed.codeRepairCount,
    rareRescue: reviewed.rareRescue,
    writerRequests: reviewed.writerRequests,
    criticRequests: reviewed.criticRequests,
    variantFingerprint: fp,
    variantKey: `recall_${fp.slice(0, 16)}`,
  };
}

'''
t = t.replace(marker, insert + marker, 1)
old_route = 'const finalized = await mapLimit(items, 2, async (item: Json) => legacyPhrasal(item) || await generatePhrasal(item));'
new_route = '''const finalized = await mapLimit(items, 2, async (item: Json) => {
      const reused = legacyPhrasal(item);
      if (reused) return reused;
      const canonicalRecall = await deterministicRecallFromCanonical(item);
      return canonicalRecall || await generatePhrasal(item);
    });'''
assert old_route in t, 'finalized route marker missing'
t = t.replace(old_route, new_route, 1)
old_meta = '''        requestMode: "one_item_per_generation_request",\n        writer: "antigravity",\n        writerReasoning: "high",'''
new_meta = '''        requestMode: Number(x.writerRequests ?? 0) > 0 ? "one_item_per_generation_request" : "deterministic_canonical_recall",\n        writer: Number(x.writerRequests ?? 0) > 0 ? "antigravity" : "deterministic_recall",\n        writerReasoning: Number(x.writerRequests ?? 0) > 0 ? "high" : "none",'''
assert old_meta in t, 'audit metadata marker missing'
t = t.replace(old_meta, new_meta, 1)
t = t.replace('writerRequests: Number(x.writerRequests || 1),', 'writerRequests: Number(x.writerRequests ?? 0),', 1)
# Surface the sparse split in the run result without changing existing compatibility fields.
t = t.replace('''      generated: generated.length,\n      reused,''', '''      generated: generated.length,\n      deterministicRecalls: generated.filter(x => x.generatorProvider === "deterministic_recall").length,\n      antigravityGenerated: generated.filter(x => Number(x.writerRequests ?? 0) > 0).length,\n      reused,''', 1)
p.write_text(t)

v = Path('.github/scripts/validate-english-hybrid-ai-content.cjs')
u = v.read_text()
u = u.replace("need(stage1,'fourOptionCodeGate','Deterministic pre/post structural gate exists');", "need(stage1,'fourOptionCodeGate','Deterministic pre/post structural gate exists');\nneed(stage1,'initialItem?:T','Shared pipeline can begin from deterministic canonical content before Luna review');")
u = u.replace("need(phrasal,'legacyPhrasal(item) || await generatePhrasal(item)','Only unusable or gap slots reach AI');", "need(phrasal,'deterministicRecallFromCanonical','Missing Recall can be built from canonical evidence before writer escalation');\nneed(phrasal,'initialGeneratorProvider: \"deterministic_recall\"','Canonical Recall transform has truthful provenance');\nneed(phrasal,'canonicalRecall || await generatePhrasal(item)','Only Recall candidates that cannot be built canonically reach the writer');")
u = u.replace("need(phrasal,'requestMode: \"one_item_per_generation_request\"','Phrasal audit records one-item request mode');", "need(phrasal,'\"one_item_per_generation_request\" : \"deterministic_canonical_recall\"','Phrasal audit distinguishes writer calls from deterministic Recall transforms');")
u = u.replace("need(phrasal,'writerReasoning: \"high\"','Phrasal audit records writer reasoning intent');", "need(phrasal,'? \"high\" : \"none\"','Phrasal audit records reasoning only when a writer was actually called');")
v.write_text(u)

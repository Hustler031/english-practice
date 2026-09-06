from pathlib import Path

p=Path('supabase/functions/english-content-task-bridge/phrasal-generation.ts')
s=p.read_text()
marker='async function generatePhrasal(item: Json) {'
assert s.count(marker)==1
helper='''const legacyOption = (reference: Json, key: "A"|"B"|"C"|"D") => {
  const hit = Array.isArray(reference?.options)
    ? reference.options.find((x: any) => String(x?.key || "").toUpperCase() === key)
    : null;
  return String(hit?.text ?? reference?.[`option${key}`] ?? "").trim();
};
function legacyPhrasal(item: Json) {
  const conceptId = String(item?.phrasalConceptId || item?.conceptId || "");
  const requested = String(item?.requestedQuestionFamily || item?.missingFamily || item?.phrasalQuestionFamily || "recognition").toLowerCase();
  const legacy = String(item?.legacyFamily || item?.missingFamily || item?.phrasalQuestionFamily || requested || "recognition").toLowerCase();
  const reference = Object.keys(item?.referenceVariant || {}).length ? item.referenceVariant : item;
  const targetWord = resolvePhrasalTarget(item, reference, conceptId);
  if (!conceptId || !targetWord) return null;
  if (item?.contentGap === true || String(item?.slotStatus || "").toLowerCase() === "content_gap") return null;
  if (requested === "context_fill" || requested !== legacy) return null;

  const draft: Json = {
    word: targetWord,
    senseKey: String(item?.senseKey || "legacy_default"),
    senseGloss: String(item?.senseGloss || ""),
    question: String(reference?.question || "").trim(),
    questionType: String(reference?.questionType || "").trim(),
    optionA: legacyOption(reference, "A"),
    optionB: legacyOption(reference, "B"),
    optionC: legacyOption(reference, "C"),
    optionD: legacyOption(reference, "D"),
    correctKey: String(reference?.correctKey || "").toUpperCase(),
    explanation: String(reference?.explanation || "").trim(),
    tip: String(reference?.tip || ""),
    usageNote: String(reference?.usageNote || ""),
    example: String(reference?.example || reference?.exampleSentence || ""),
    memoryAid: String(reference?.memoryAid || ""),
    related: String(reference?.related || reference?.relatedWords || ""),
    difficulty: String(reference?.difficulty || item?.difficulty || "Medium"),
    sourcePage: String(reference?.sourcePage || ""),
    sourceUrl: String(reference?.sourceUrl || ""),
  };
  if (!draft.question || !draft.explanation) return null;
  if (requested === "recall") {
    if (draft.questionType !== "Reverse Recall Card" || draft.optionA !== "Yaad tha" || draft.optionB !== "Confused" || draft.optionC !== "Bhool gaya" || draft.optionD !== "" || draft.correctKey !== "A") return null;
    if (normText(draft.question).includes(normText(targetWord))) return null;
  } else if (fourOptionCodeGate(draft, "correctKey").length) return null;

  return {
    ...draft,
    conceptId,
    requestedQuestionFamily: requested,
    questionFamily: requested,
    legacyFamily: legacy,
    family: requested,
    baseQuestionId: String(reference?.id || reference?.questionId || item?.id || item?.questionId || ""),
    contentGap: false,
    generatorProvider: "legacy_bank",
    generatorModel: "canonical_bank",
    criticProvider: null,
    criticModel: null,
    quality: null,
    repairCount: 0,
    codeRepairCount: 0,
    rareRescue: false,
    writerRequests: 0,
    criticRequests: 0,
    variantFingerprint: "",
    variantKey: "",
  };
}

'''
s=s.replace(marker,helper+marker,1)
s=s.replace('if (expectedContextCount > 8) throw new Error(`PHRASAL_CONTEXT_SELECTION_INVALID: maximum 8 contextual slots, got ${expectedContextCount}`);','if (expectedContextCount > 6) throw new Error(`PHRASAL_CONTEXT_SELECTION_INVALID: maximum 6 contextual slots, got ${expectedContextCount}`);',1)
old='''    // Quality-first Stage 1: every Central-selected slot gets its own writer + critic path.\n    const finalized = await mapLimit(items, 4, async (item: Json) => await generatePhrasal(item));\n    const contextCount = finalized.filter((x) => x.requestedQuestionFamily === "context_fill").length;\n    if (contextCount !== expectedContextCount || contextCount > 8) throw new Error(`PHRASAL_CONTEXT_MIX_REJECTED: Central requested ${expectedContextCount}, finalized ${contextCount}`);'''
new='''    // Central Intelligence owns the 20-slot batch. Reuse structurally valid serviceable cards;\n    // AI only fills actual family/content gaps and context-fill slots.\n    const finalized = await mapLimit(items, 4, async (item: Json) => legacyPhrasal(item) || await generatePhrasal(item));\n    const contextCount = finalized.filter((x) => x.requestedQuestionFamily === "context_fill").length;\n    if (contextCount !== expectedContextCount || contextCount > 6) throw new Error(`PHRASAL_CONTEXT_MIX_REJECTED: Central requested ${expectedContextCount}, finalized ${contextCount}`);'''
assert old in s
s=s.replace(old,new,1)
old='    await audit(db, finalized.map((x) => ({'
new='''    const generated = finalized.filter((x) => x.generatorProvider !== "legacy_bank");\n    const reused = finalized.length - generated.length;\n    await audit(db, generated.map((x) => ({'''
assert old in s
s=s.replace(old,new,1)
s=s.replace('      generated: finalized.length,','      generated: generated.length,\n      reused,',1)
s=s.replace('      rareRescues: finalized.filter(x => x.rareRescue === true).length,','      rareRescues: generated.filter(x => x.rareRescue === true).length,',1)
s=s.replace('      writerRequests: finalized.reduce((n, x) => n + Number(x.writerRequests || 1), 0),','      writerRequests: generated.reduce((n, x) => n + Number(x.writerRequests || 0), 0),',1)
s=s.replace('      criticRequests: finalized.reduce((n, x) => n + Number(x.criticRequests || 1), 0),','      criticRequests: generated.reduce((n, x) => n + Number(x.criticRequests || 0), 0),',1)
s=s.replace('      codeRepairs: finalized.reduce((n, x) => n + Number(x.codeRepairCount || 0), 0),','      codeRepairs: generated.reduce((n, x) => n + Number(x.codeRepairCount || 0), 0),',1)
p.write_text(s)

src=Path('supabase/managed-migrations/20260905231800_english_phrasal_context_metadata.sql').read_text()
start=src.index('create or replace function public.english_get_phrasal_hybrid_maintenance_batch')
end_marker='grant execute on function public.english_get_phrasal_hybrid_maintenance_batch(text,integer) to authenticated, service_role;'
end=src.index(end_marker,start)+len(end_marker)
fn=src[start:end]
assert fn.count('eligible_rank<=8')==1
fn=fn.replace('eligible_rank<=8','eligible_rank<=6',1)
Path('supabase/managed-migrations/20260906033000_english_phrasal_context_fill_cap_six.sql').write_text('-- Cap adaptive Daily Phrasal context-fill/filler slots at six.\n-- Central Intelligence still selects the exact 20 concepts.\n\n'+fn+'\n')

v=Path('.github/scripts/validate-english-hybrid-ai-content.cjs')
t=v.read_text()
anchor="const stage1Flags=read('supabase/managed-migrations/20260906031000_english_antigravity_luna_stage1_flags.sql');"
assert anchor in t
t=t.replace(anchor,anchor+"\nconst phrasalCap=read('supabase/managed-migrations/20260906033000_english_phrasal_context_fill_cap_six.sql');",1)
t=t.replace("need(metadata,'eligible_rank<=8','Context-fill remains capped at eight');","need(phrasalCap,'eligible_rank<=6','Context-fill is capped at six');\nforbid(phrasalCap,'eligible_rank<=8','Eight-slot context-fill cap is retired');",1)
t=t.replace('// Phrasal: every Central-selected slot is generated and independently criticised one-item-at-a-time.','// Phrasal: Central selects 20; serviceable cards reuse bank content, only real gaps use one-item AI.',1)
old_checks="""need(phrasal,'const finalized = await mapLimit(items, 4, async (item: Json) => await generatePhrasal(item))','All 20 Central slots use item-wise generation');\nforbid(phrasal,'legacyPhrasal','Legacy zero-AI shortcut removed from Stage 1');\nneed(phrasal,'items.length !== 20','Phrasal claim remains exact-20');\nneed(phrasal,'expectedContextCount > 8','Maximum eight context-fill slots remains enforced');"""
new_checks="""need(phrasal,'function legacyPhrasal','Serviceable canonical Phrasal cards can bypass AI');\nneed(phrasal,'generatorProvider: \"legacy_bank\"','Reused cards are explicitly marked as bank reuse');\nneed(phrasal,'legacyPhrasal(item) || await generatePhrasal(item)','Only unusable or gap slots reach AI');\nneed(phrasal,'const generated = finalized.filter((x) => x.generatorProvider !== \"legacy_bank\")','Only AI-generated slots are audited as generated');\nneed(phrasal,'items.length !== 20','Phrasal claim remains exact-20');\nneed(phrasal,'expectedContextCount > 6','Maximum six context-fill slots remains enforced');"""
assert old_checks in t
t=t.replace(old_checks,new_checks,1)
v.write_text(t)

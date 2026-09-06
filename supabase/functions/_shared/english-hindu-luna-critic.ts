import { LUNA_MODEL, lunaJson, lunaQualitySchema, type LunaQuality } from "./english-antigravity-luna.ts";

type Json = Record<string, any>;

const currentIstDate=()=>new Date().toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});
const VOCAB_INSTRUCTIONS = `You are the independent final quality critic for one SSC-oriented current-news/editorial English learning item authored by ChatGPT. Do not rewrite the item. Judge only whether it is safe and useful to publish. The reviewContext.currentAsiaKolkataDate is the authoritative current date for this task; never substitute a model-training or guessed date, and never call a source future-dated when sourceDate is on or before that date. Source discovery and live-article retrieval were already performed by the scheduled ChatGPT author before this critic call. Do not require a verbatim article quotation or external source re-verification merely because no excerpt is supplied; reject source grounding only for an internal contradiction, impossible metadata, or a target/sense that conflicts with the supplied source context. Verify the target word/sense is natural; exactly one option is defensibly correct; all distractors are close, realistic and not obviously eliminable; the explanation matches the exact question/options/correct answer; fixed-preposition, confusable-pair and logical-function claims are accurate when present; no ambiguity, stale explanation, lexical/grammar error or factual error is introduced. Score strictly. PASS requires score >=85 and every hard gate true. Use REPAIR when the item is potentially useful but needs author revision. Use REJECT only for fundamental defects.`;

const TONE_INSTRUCTIONS = `You are the independent final quality critic for one SSC-style editorial tone/mood question authored by ChatGPT. Do not rewrite it. The reviewContext.currentAsiaKolkataDate is authoritative; a source dated on or before it is not future-dated. Source discovery was already performed by the scheduled ChatGPT author, so do not require a verbatim article quotation or external source lookup. Verify that the short context paraphrase supports the requested actual or counterfactual tone task; writer tone and passage mood are not confused; exactly one option is defensibly correct; distractors are close and realistic; the explanation distinguishes the nearest trap; source metadata is internally plausible; no ambiguity, grammar error or factual contradiction is introduced. PASS requires score >=85 and every hard gate true. Use REPAIR for fixable question-quality defects and REJECT only for fundamental defects.`;

export type HinduCriticResult = { quality: LunaQuality; provider: "openai"; model: string };

export function hinduQualityPass(q: LunaQuality | null | undefined) {
  return !!q && Number(q.score || 0) >= 85 && q.decision === "PASS" && Object.values(q.hardGates || {}).every(Boolean);
}

export function isHinduCriticTransient(error: unknown) {
  const s = error instanceof Error ? error.message : String(error || "");
  return /^LUNA_(429|500|502|503|504|TIMEOUT|RETRY_EXHAUSTED)/.test(s);
}

export async function criticHinduVocab(item: Json): Promise<HinduCriticResult> {
  const result = await lunaJson<LunaQuality>(VOCAB_INSTRUCTIONS, {
    item,
    reviewContext: {
      lane: "hindu",
      mode: "chatgpt_sheet_submission",
      currentAsiaKolkataDate:currentIstDate(),
      targetWord: item.word,
      candidateType: item.candidateType || "vocabulary",
      fixedPreposition: item.fixedPreposition || "",
      confusableWith: item.confusableWith || "",
      examValueReason: item.examValueReason || "",
      logicalFunction: item.logicalFunction || "",
      sourceName: item.sourceName,
      sourceUrl: item.sourceUrl,
      articleTitle: item.articleTitle,
      sourceDate: item.sourceDate || null,
    },
  }, lunaQualitySchema);
  return { quality: result.data, provider: "openai", model: result.model || LUNA_MODEL };
}

export async function criticHinduTone(item: Json): Promise<HinduCriticResult> {
  const result = await lunaJson<LunaQuality>(TONE_INSTRUCTIONS, {
    item,
    reviewContext: {
      lane: "tone",
      mode: "chatgpt_sheet_submission",
      currentAsiaKolkataDate:currentIstDate(),
      toneKind: item.toneKind || "actual",
      sourceName: item.sourceName,
      sourceUrl: item.sourceUrl,
      sourceDate: item.sourceDate || null,
    },
  }, lunaQualitySchema);
  return { quality: result.data, provider: "openai", model: result.model || LUNA_MODEL };
}

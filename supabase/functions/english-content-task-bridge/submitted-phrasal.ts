type Db = any;
type Json = Record<string, any>;

const text = (v: unknown) => String(v ?? "").trim();
const lower = (v: unknown) => text(v).toLowerCase();
const norm = (v: unknown) => lower(v).replace(/[^a-z0-9]+/g, " ").trim();
const conceptOf = (x: Json) => text(x?.phrasalConceptId || x?.conceptId);
const requestedOf = (x: Json) => lower(x?.requestedQuestionFamily || x?.missingFamily || x?.phrasalQuestionFamily || x?.questionFamily || x?.family || "recognition");
const legacyOf = (x: Json) => lower(x?.legacyFamily || x?.missingFamily || x?.phrasalQuestionFamily || x?.family || requestedOf(x) || "recognition");
const keys = ["A", "B", "C", "D"] as const;
const qualityGateNames = [
  "exactlyOneCorrect", "correctKeyMatches", "linguisticallyValid", "conceptPreserved",
  "sensePreserved", "learnerRequestPreserved", "noFactualError", "noLexicalGrammarError",
  "requiredOptionsValid", "explanationMatchesQuestion", "explanationMatchesAnswer",
  "noStaleExplanation", "noAmbiguity", "noSecondCorrectOption", "intentSpecificTaskValid",
  "questionFamilyValid", "plausibleDistractors", "distractorsNotObvious",
];

function validateSubmittedItem(item: Json, selection: Json, index: number) {
  const n = index + 1;
  const expectedConcept = conceptOf(selection);
  const expectedRequested = requestedOf(selection);
  const expectedLegacy = legacyOf(selection);
  const gotConcept = text(item?.conceptId);
  const gotRequested = requestedOf(item);
  const gotFamily = lower(item?.family || item?.legacyFamily || gotRequested);
  const gotQuestionFamily = lower(item?.questionFamily || gotRequested);
  const provider = lower(item?.generatorProvider || "");

  if (!expectedConcept || gotConcept !== expectedConcept) throw new Error(`Phrasal slot ${n}: Central concept mismatch`);
  if (gotRequested !== expectedRequested) throw new Error(`Phrasal slot ${n}: requested family mismatch`);
  if (expectedRequested === "context_fill") {
    if (gotQuestionFamily !== "context_fill" || gotFamily !== "recognition") throw new Error(`Phrasal slot ${n}: context-fill family contract mismatch`);
  } else if (gotQuestionFamily !== expectedRequested || gotFamily !== expectedLegacy) {
    throw new Error(`Phrasal slot ${n}: family contract mismatch`);
  }
  if (!text(item?.question) || !text(item?.explanation)) throw new Error(`Phrasal slot ${n}: question/explanation required`);
  if (!provider || !["legacy_bank", "chatgpt"].includes(provider)) throw new Error(`Phrasal slot ${n}: generatorProvider must be legacy_bank or chatgpt`);

  const correct = text(item?.correctKey).toUpperCase();
  if (expectedRequested === "recall") {
    if (text(item?.questionType) !== "Reverse Recall Card" || correct !== "A" ||
        text(item?.optionA) !== "Yaad tha" || text(item?.optionB) !== "Confused" ||
        text(item?.optionC) !== "Bhool gaya" || text(item?.optionD) !== "") {
      throw new Error(`Phrasal slot ${n}: recall control contract mismatch`);
    }
    if (text(item?.word) && norm(item?.question).includes(norm(item?.word))) throw new Error(`Phrasal slot ${n}: recall cue leaks target phrase`);
  } else {
    if (!keys.includes(correct as any)) throw new Error(`Phrasal slot ${n}: invalid correctKey`);
    const opts = keys.map((k) => text(item?.[`option${k}`]));
    if (opts.some((x) => !x)) throw new Error(`Phrasal slot ${n}: four nonblank options required`);
    if (new Set(opts.map(norm)).size !== 4) throw new Error(`Phrasal slot ${n}: options must be distinct`);
  }

  if (provider === "legacy_bank") {
    if (!text(item?.baseQuestionId)) throw new Error(`Phrasal slot ${n}: legacy slot missing baseQuestionId`);
    return;
  }

  if (!text(item?.word)) throw new Error(`Phrasal slot ${n}: ChatGPT target word required`);
  if (!text(item?.senseKey) || !text(item?.senseGloss)) throw new Error(`Phrasal slot ${n}: ChatGPT sense metadata required`);
  const q = item?.quality || {};
  if (Number(q?.score || 0) < 85 || !["PASS", "PASS_WITH_MINOR_ISSUES"].includes(text(q?.decision).toUpperCase())) {
    throw new Error(`Phrasal slot ${n}: ChatGPT self-critic quality gate failed`);
  }
  for (const gate of qualityGateNames) {
    if (q?.hardGates?.[gate] !== true) throw new Error(`Phrasal slot ${n}: self-critic hard gate ${gate} failed`);
  }
  if (lower(item?.criticProvider) !== "chatgpt_self_critic") throw new Error(`Phrasal slot ${n}: ChatGPT-generated item must carry ChatGPT self-critic provenance`);
}

export async function claimSubmittedPhrasal(db: Db) {
  const { data, error } = await db.rpc("english_phrasal_task_claim");
  if (error) throw new Error(error.message);
  const out = (data || { ok: true, count: 0 }) as Json;
  if (out?.complete === true || out?.busy === true || Number(out?.count || 0) === 0) return out;

  const selection = Array.isArray(out?.items) ? out.items : [];
  const runId = text(out?.runId);
  const batchDate = text(out?.date);
  const sourceId = text(out?.sourceId);
  if (!runId || !/^\d{4}-\d{2}-\d{2}$/.test(batchDate) || selection.length !== 20) {
    throw new Error("Phrasal claim did not return one exact Central-selected 20-slot batch");
  }

  const batchRow = {
    batch_date: batchDate,
    run_id: runId,
    source_id: sourceId,
    status: "building",
    selection,
    expected_count: 20,
    last_error: null,
    updated_at: new Date().toISOString(),
  };
  const { error: batchError } = await db.schema("english").from("phrasal_generation_batches").upsert(batchRow, { onConflict: "batch_date" });
  if (batchError) throw new Error(`Phrasal batch staging failed: ${batchError.message}`);

  const slots = selection.map((s: Json, i: number) => ({
    batch_date: batchDate,
    slot_no: i + 1,
    concept_id: conceptOf(s),
    requested_family: requestedOf(s),
    assignment: s,
    status: "pending",
    finalized: null,
    attempt_count: 0,
    lease_expires_at: null,
    last_error: null,
    retry_after: null,
    transient_failure_count: 0,
    last_error_class: null,
    updated_at: new Date().toISOString(),
    ready_at: null,
  }));
  if (slots.some((s: Json) => !s.concept_id)) throw new Error("Phrasal Central selection contains a slot without concept identity");
  const { error: slotError } = await db.schema("english").from("phrasal_generation_slots").upsert(slots, { onConflict: "batch_date,slot_no" });
  if (slotError) throw new Error(`Phrasal slot staging failed: ${slotError.message}`);

  const generatedNeeded = selection.filter((s: Json) => s?.contentGap === true || lower(s?.slotStatus) === "content_gap" || requestedOf(s) !== legacyOf(s)).length;
  return { ...out, mode: "chatgpt_owned", generatedNeeded };
}

export async function ingestSubmittedPhrasal(db: Db, runIdRaw: unknown, itemsRaw: unknown) {
  const runId = text(runIdRaw);
  const items = Array.isArray(itemsRaw) ? itemsRaw as Json[] : [];
  if (!runId || items.length !== 20) throw new Error("Phrasal ingest requires runId and exactly 20 finalized items");

  const { data: run, error: runError } = await db.schema("english").from("chatgpt_content_task_runs")
    .select("run_id,lane,batch_date,status,result").eq("run_id", runId).eq("lane", "phrasal").maybeSingle();
  if (runError) throw new Error(runError.message);
  if (!run) throw new Error("Unknown Phrasal run");
  if (run.status === "applied") return run.result || { ok: true, alreadyApplied: true };
  if (run.status !== "claimed") throw new Error(`Phrasal run is not claimable: ${run.status}`);

  const { data: batch, error: batchError } = await db.schema("english").from("phrasal_generation_batches")
    .select("batch_date,run_id,selection,status").eq("run_id", runId).maybeSingle();
  if (batchError) throw new Error(batchError.message);
  const selection = Array.isArray(batch?.selection) ? batch.selection as Json[] : [];
  if (!batch || selection.length !== 20) throw new Error("Phrasal staged Central selection is missing or incomplete");

  items.forEach((item, i) => validateSubmittedItem(item, selection[i], i));

  const now = new Date().toISOString();
  const slotRows = items.map((item, i) => ({
    batch_date: batch.batch_date,
    slot_no: i + 1,
    concept_id: conceptOf(selection[i]),
    requested_family: requestedOf(selection[i]),
    assignment: selection[i],
    status: "ready",
    finalized: item,
    attempt_count: 1,
    lease_expires_at: null,
    last_error: null,
    retry_after: null,
    transient_failure_count: 0,
    last_error_class: null,
    updated_at: now,
    ready_at: now,
  }));
  const { error: slotError } = await db.schema("english").from("phrasal_generation_slots").upsert(slotRows, { onConflict: "batch_date,slot_no" });
  if (slotError) throw new Error(`Phrasal finalized-slot staging failed: ${slotError.message}`);

  const { error: readyError } = await db.schema("english").from("phrasal_generation_batches")
    .update({ status: "ready", last_error: null, updated_at: now }).eq("run_id", runId);
  if (readyError) throw new Error(`Phrasal ready-state update failed: ${readyError.message}`);

  const { data: applied, error: applyError } = await db.rpc("english_phrasal_task_apply", { p_run_id: runId, p_items: items });
  if (applyError) {
    await db.schema("english").from("phrasal_generation_batches").update({ last_error: applyError.message, updated_at: new Date().toISOString() }).eq("run_id", runId);
    throw new Error(applyError.message);
  }

  await db.schema("english").from("phrasal_generation_batches")
    .update({ status: "applied", applied_at: new Date().toISOString(), last_error: null, updated_at: new Date().toISOString() }).eq("run_id", runId);

  const legacyCount = items.filter((x) => lower(x?.generatorProvider) === "legacy_bank").length;
  const chatgptCount = items.filter((x) => lower(x?.generatorProvider) === "chatgpt").length;
  const sourceId = `PHRASAL_DAILY_${String(batch.batch_date).replace(/-/g, "")}`;
  await db.schema("english").from("sources").update({
    notes: `Central-selected adaptive Phrasal batch. ${legacyCount} existing canonical questions reused with permanent Question_IDs; ${chatgptCount} ChatGPT-owned variants generated after self-critic. Server-side Phrasal AI generation was not used.`,
  }).eq("source_id", sourceId);

  return { ...(applied || { ok: true }), mode: "chatgpt_owned", reused: legacyCount, generatedByChatGPT: chatgptCount };
}

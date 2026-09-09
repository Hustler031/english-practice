type Db = any;
type Json = Record<string, any>;

const text = (v: unknown) => String(v ?? "").trim();

export async function claimSubmittedGrammar(db: Db) {
  const { data, error } = await db.rpc("english_grammar_task_claim");
  if (error) throw new Error(error.message);
  const out = (data || { ok: true, count: 0 }) as Json;
  if (out?.complete === true || out?.busy === true || Number(out?.count || 0) === 0) return out;

  const selection = Array.isArray(out?.items) ? out.items : [];
  const runId = text(out?.runId);
  const batchDate = text(out?.date);
  if (!runId || !/^\d{4}-\d{2}-\d{2}$/.test(batchDate) || selection.length !== 20) {
    throw new Error("Grammar claim did not return one exact Central-selected 20-slot batch");
  }

  const generatedNeeded = selection.filter((s: Json) =>
    s?.contentGap === true || s?.aiPlanner?.required === true || !s?.referenceVariant?.id
  ).length;

  return {
    ...out,
    mode: "chatgpt_owned",
    planner: "central_intelligence_plus_chatgpt",
    generatedNeeded,
  };
}

export async function ingestSubmittedGrammar(db: Db, runIdRaw: unknown, itemsRaw: unknown) {
  const runId = text(runIdRaw);
  if (!runId || !Array.isArray(itemsRaw) || itemsRaw.length > 20) {
    throw new Error("Grammar ingest requires runId and an array of 0-20 ChatGPT-generated slot overrides");
  }

  const { data, error } = await db.rpc("english_grammar_task_ingest", {
    p_run_id: runId,
    p_items: itemsRaw as Json[],
  });
  if (error) throw new Error(error.message);
  return (data || { ok: true, runId, mode: "chatgpt_owned" }) as Json;
}

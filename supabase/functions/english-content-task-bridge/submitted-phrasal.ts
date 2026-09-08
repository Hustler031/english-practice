type Db = any;
type Json = Record<string, any>;

const text = (v: unknown) => String(v ?? "").trim();
const lower = (v: unknown) => text(v).toLowerCase();
const requestedOf = (x: Json) => lower(x?.requestedQuestionFamily || x?.missingFamily || x?.phrasalQuestionFamily || x?.questionFamily || x?.family || "recognition");
const legacyOf = (x: Json) => lower(x?.legacyFamily || x?.missingFamily || x?.phrasalQuestionFamily || x?.family || requestedOf(x) || "recognition");

export async function claimSubmittedPhrasal(db: Db) {
  const { data, error } = await db.rpc("english_phrasal_task_claim");
  if (error) throw new Error(error.message);
  const out = (data || { ok: true, count: 0 }) as Json;
  if (out?.complete === true || out?.busy === true || Number(out?.count || 0) === 0) return out;

  const selection = Array.isArray(out?.items) ? out.items : [];
  const runId = text(out?.runId);
  const batchDate = text(out?.date);
  if (!runId || !/^\d{4}-\d{2}-\d{2}$/.test(batchDate) || selection.length !== 20) {
    throw new Error("Phrasal claim did not return one exact Central-selected 20-slot batch");
  }

  const generatedNeeded = selection.filter((s: Json) =>
    s?.contentGap === true || lower(s?.slotStatus) === "content_gap" || requestedOf(s) !== legacyOf(s)
  ).length;
  return { ...out, mode: "chatgpt_owned", generatedNeeded };
}

export async function ingestSubmittedPhrasal(db: Db, runIdRaw: unknown, itemsRaw: unknown) {
  const runId = text(runIdRaw);
  const items = Array.isArray(itemsRaw) ? itemsRaw as Json[] : [];
  if (!runId || items.length !== 20) throw new Error("Phrasal ingest requires runId and exactly 20 finalized items");

  const { data, error } = await db.rpc("english_phrasal_task_ingest", {
    p_run_id: runId,
    p_items: items,
  });
  if (error) throw new Error(error.message);
  return (data || { ok: true, runId, mode: "chatgpt_owned" }) as Json;
}

import { critic, hardGatesPass, GROQ_MODEL } from "../_shared/english-hybrid-ai.ts";

type Db = any;
type Json = Record<string, any>;

const normWord = (v: string) => v.toLowerCase().replace(/[^a-z0-9]/g, "");
const errorText = (e: unknown) => e instanceof Error ? e.message : String(e || "Unknown Hindu ingest error");

function structuralError(item: Json): string | null {
  const required = ["word", "meaning", "question", "explanation", "optionA", "optionB", "optionC", "optionD", "correctKey", "sourceUrl", "articleTitle", "sourceName"];
  for (const key of required) if (!String(item?.[key] ?? "").trim()) return `missing_${key}`;
  if (!["A", "B", "C", "D"].includes(String(item.correctKey).trim().toUpperCase())) return "invalid_correctKey";
  const options = [item.optionA, item.optionB, item.optionC, item.optionD].map((x) => String(x ?? "").trim().toLowerCase());
  if (new Set(options).size !== 4) return "duplicate_options";
  if (!/^https?:\/\//i.test(String(item.sourceUrl))) return "invalid_sourceUrl";
  return null;
}

async function releaseClaim(db: Db, runId: string, reason: unknown) {
  if (!runId) return;
  try {
    await db.rpc("english_release_content_task_claim", {
      p_run_id: runId,
      p_lane: "hindu",
      p_reason: errorText(reason).slice(0, 800),
    });
  } catch {
    // best effort only; original result/error remains authoritative
  }
}

async function recordAudits(db: Db, rows: Json[]) {
  if (!rows.length) return;
  const { error } = await db.rpc("english_record_content_generation_audits", { p_items: rows });
  if (error) throw new Error(`AUDIT_FAILED: ${error.message}`);
}

export async function ingestSubmittedHinduItems(db: Db, submitted: Json[]) {
  if (!Array.isArray(submitted) || submitted.length < 25 || submitted.length > 30) {
    throw new Error("HINDU_SUBMITTED_COUNT: exactly 25-30 fully generated candidate items are required");
  }

  const { data: claim, error: claimError } = await db.rpc("english_hindu_task_claim");
  if (claimError) throw new Error(`HINDU_CLAIM_FAILED: ${claimError.message}`);
  if (Number(claim?.count || 0) === 0) {
    return { ok: true, lane: "hindu", mode: "sheet_ingest", complete: true, submitted: submitted.length, accepted: 0, decisions: [] };
  }

  const runId = String(claim?.runId || "");
  const need = Math.min(20, Number(claim?.count || 0));
  const decisions: Json[] = [];

  try {
    const seen = new Set<string>();
    const structurallyClean: { item: Json; index: number }[] = [];
    submitted.forEach((item, index) => {
      const word = String(item?.word || "").trim();
      const normalized = normWord(word);
      const error = structuralError(item);
      if (!normalized || seen.has(normalized)) {
        decisions.push({ index, word, status: "rejected", stage: "structure", reason: "duplicate_in_submission" });
        return;
      }
      seen.add(normalized);
      if (error) {
        decisions.push({ index, word, status: "rejected", stage: "structure", reason: error });
        return;
      }
      structurallyClean.push({ item, index });
    });

    const candidates = structurallyClean.map(({ item }) => ({
      word: item.word,
      familyKeys: Array.isArray(item.familyKeys) ? item.familyKeys : [],
    }));
    const { data: check, error: checkError } = await db.rpc("english_hindu_task_check_candidates", {
      p_run_id: runId,
      p_candidates: candidates,
    });
    if (checkError) throw new Error(`HINDU_CHECK_FAILED: ${checkError.message}`);

    const checkMap = new Map((check?.items || []).map((x: Json) => [normWord(String(x?.word || "")), x]));
    const criticQueue: { item: Json; index: number }[] = [];
    for (const row of structurallyClean) {
      const result = checkMap.get(normWord(String(row.item.word))) as Json | undefined;
      if (result?.duplicate) {
        decisions.push({ index: row.index, word: row.item.word, status: "rejected", stage: "central_duplicate_gate", reason: "historical_or_family_collision", hits: result.hits || [] });
      } else {
        criticQueue.push(row);
      }
    }

    const passed: { item: Json; index: number; score: number }[] = [];
    for (let offset = 0; offset < criticQueue.length; offset += 3) {
      const group = criticQueue.slice(offset, offset + 3);
      const settled = await Promise.allSettled(group.map(async ({ item, index }) => {
        const reviewed = await critic(item, {
          lane: "hindu",
          mode: "chatgpt_sheet_submission",
          criticOnly: true,
          targetWord: item.word,
          candidateType: item.candidateType || "vocabulary",
          sourceName: item.sourceName,
          sourceUrl: item.sourceUrl,
          articleTitle: item.articleTitle,
          sourceDate: item.sourceDate || null,
        });
        return { item, index, reviewed };
      }));

      settled.forEach((result, groupIndex) => {
        const original = group[groupIndex];
        if (result.status === "rejected") {
          decisions.push({ index: original.index, word: original.item.word, status: "rejected", stage: "backend_critic", reason: errorText(result.reason) });
          return;
        }
        const { item, index, reviewed } = result.value;
        const score = Number(reviewed.quality?.score || 0);
        if (!hardGatesPass(reviewed.quality)) {
          decisions.push({ index, word: item.word, status: "rejected", stage: "backend_critic", reason: reviewed.quality?.decision || "quality_rejected", score, issues: reviewed.quality?.issues || [], criticModel: reviewed.model });
          return;
        }
        passed.push({
          index,
          score,
          item: {
            ...item,
            quality: reviewed.quality,
            criticProvider: "groq",
            criticModel: reviewed.model,
            generatorProvider: String(item.generatorProvider || "chatgpt"),
            generatorModel: String(item.generatorModel || "chatgpt_scheduled_task"),
          },
        });
      });
    }

    passed.sort((a, b) => b.score - a.score || a.index - b.index);
    const selected = passed.slice(0, need);
    const overflow = passed.slice(need);
    overflow.forEach((row) => decisions.push({ index: row.index, word: row.item.word, status: "rejected", stage: "central_slot_selection", reason: "daily_capacity", score: row.score }));

    if (!selected.length) {
      await releaseClaim(db, runId, "No submitted Hindu item passed duplicate + critic gates");
      return {
        ok: true,
        lane: "hindu",
        mode: "sheet_ingest",
        runId,
        submitted: submitted.length,
        requestedSlots: need,
        accepted: 0,
        rejected: decisions.length,
        completeTarget: false,
        decisions: decisions.sort((a, b) => Number(a.index) - Number(b.index)),
      };
    }

    const items = selected.map((x) => x.item);
    const { data: applied, error: applyError } = await db.rpc("english_hindu_task_apply", {
      p_run_id: runId,
      p_items: items,
    });
    if (applyError) throw new Error(`HINDU_APPLY_FAILED: ${applyError.message}`);

    selected.forEach((row) => decisions.push({ index: row.index, word: row.item.word, status: "accepted", stage: "published", score: row.score, criticModel: row.item.criticModel }));

    await recordAudits(db, selected.map((row) => ({
      lane: "hindu",
      entityKey: String(row.item.word),
      generatorProvider: String(row.item.generatorProvider || "chatgpt"),
      generatorModel: String(row.item.generatorModel || "chatgpt_scheduled_task"),
      criticProvider: "groq",
      criticModel: String(row.item.criticModel || GROQ_MODEL),
      qualityScore: row.item.quality?.score,
      criticDecision: row.item.quality?.decision,
      repairCount: 0,
      publicationResult: "applied",
      metadata: {
        mode: "chatgpt_sheet_submission",
        criticOnly: true,
        sourceName: row.item.sourceName,
        sourceUrl: row.item.sourceUrl,
        candidateType: row.item.candidateType || "vocabulary",
      },
    })));

    return {
      ok: true,
      lane: "hindu",
      mode: "sheet_ingest",
      runId,
      submitted: submitted.length,
      requestedSlots: need,
      accepted: selected.length,
      rejected: decisions.filter((x) => x.status === "rejected").length,
      completeTarget: selected.length === need,
      decisions: decisions.sort((a, b) => Number(a.index) - Number(b.index)),
      applied,
    };
  } catch (e) {
    await releaseClaim(db, runId, e);
    throw e;
  }
}

const upstreamFetch = globalThis.fetch.bind(globalThis);
const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
const PARALLEL_NAMES = new Set([
  "english_ssc_sprint",
  "english_ssc_sprint_independent_critic_polish",
]);

function errorText(error: unknown) {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  try {
    const serialized = JSON.stringify(error);
    return serialized && serialized !== "{}" ? serialized : "Unknown parallel Sprint AI error";
  } catch {
    return "Unknown parallel Sprint AI error";
  }
}

function responseText(payload: any) {
  if (typeof payload?.output_text === "string") return payload.output_text;
  for (const item of payload?.output || []) {
    for (const content of item?.content || []) {
      if (content?.type === "output_text") return content.text || "";
    }
  }
  return "";
}

function balancedRanges(total: number) {
  const partCount = total >= 20 ? 3 : total >= 12 ? 2 : 1;
  if (partCount === 1) return [{ start: 0, end: total }];
  const base = Math.floor(total / partCount);
  let remainder = total % partCount;
  const ranges: Array<{ start: number; end: number }> = [];
  let cursor = 0;
  for (let i = 0; i < partCount; i++) {
    const size = base + (remainder > 0 ? 1 : 0);
    remainder = Math.max(0, remainder - 1);
    ranges.push({ start: cursor, end: cursor + size });
    cursor += size;
  }
  return ranges;
}

function sumUsage(payloads: any[]) {
  let input = 0;
  let output = 0;
  let reasoning = 0;
  let total = 0;
  for (const payload of payloads) {
    const usage = payload?.usage || {};
    input += Number(usage.input_tokens) || 0;
    output += Number(usage.output_tokens) || 0;
    reasoning += Number(usage.output_tokens_details?.reasoning_tokens) || 0;
    total += Number(usage.total_tokens) || 0;
  }
  return {
    input_tokens: input,
    output_tokens: output,
    output_tokens_details: { reasoning_tokens: reasoning },
    total_tokens: total || input + output,
  };
}

(globalThis as any).fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url =
    typeof input === "string"
      ? input
      : input instanceof URL
        ? input.href
        : input.url;

  if (url !== OPENAI_RESPONSES_URL || typeof init?.body !== "string") {
    return upstreamFetch(input, init);
  }

  let body: any;
  let structuredInput: any;
  try {
    body = JSON.parse(init.body);
    structuredInput = typeof body?.input === "string" ? JSON.parse(body.input) : null;
  } catch {
    return upstreamFetch(input, init);
  }

  const format = body?.text?.format;
  const schema = format?.schema;
  const itemArray = schema?.properties?.items;
  const expected = Number(itemArray?.minItems);
  const sameFixedCount = expected > 0 && expected === Number(itemArray?.maxItems);
  const slotPlan = structuredInput?.slotPlan;

  if (
    !PARALLEL_NAMES.has(String(format?.name || "")) ||
    !sameFixedCount ||
    expected < 12 ||
    !Array.isArray(slotPlan) ||
    slotPlan.length !== expected
  ) {
    return upstreamFetch(input, init);
  }

  const ranges = balancedRanges(expected);
  if (ranges.length === 1) return upstreamFetch(input, init);

  try {
    const results = await Promise.all(
      ranges.map(async ({ start, end }, partIndex) => {
        const partBody = structuredClone(body);
        const partInput = structuredClone(structuredInput);
        const partSize = end - start;

        partInput.slotPlan = slotPlan.slice(start, end);
        if (Array.isArray(partInput.draftItems) && partInput.draftItems.length === expected) {
          partInput.draftItems = partInput.draftItems.slice(start, end);
        }

        partBody.input = JSON.stringify(partInput);
        partBody.reasoning = { ...(partBody.reasoning || {}), effort: "low" };
        partBody.max_output_tokens = Math.min(Number(partBody.max_output_tokens) || 12000, 5000);
        partBody.instructions = `${String(partBody.instructions || "")}\n\nThis request is part ${partIndex + 1} of ${ranges.length}. Return ONLY the items for the supplied slotPlan, in the same order. Keep explanations concise (maximum 30 words) and metadata text compact while preserving correctness and SSC-level quality.`;
        partBody.text.format.name = `${String(format.name)}_p${partIndex + 1}`;
        partBody.text.format.schema.properties.items.minItems = partSize;
        partBody.text.format.schema.properties.items.maxItems = partSize;

        const response = await upstreamFetch(input, {
          ...init,
          body: JSON.stringify(partBody),
        });
        const payload = await response.json();
        if (!response.ok) {
          throw new Error(payload?.error?.message || `OpenAI parallel chunk failed (${response.status})`);
        }

        const output = responseText(payload);
        if (!output) throw new Error(`OpenAI parallel chunk ${partIndex + 1} returned no structured output`);
        const parsed = JSON.parse(output);
        if (!Array.isArray(parsed?.items) || parsed.items.length !== partSize) {
          throw new Error(`OpenAI parallel chunk ${partIndex + 1} returned the wrong item count`);
        }

        const items = parsed.items.map((item: any, itemIndex: number) => ({
          ...item,
          itemKey: `${String(item?.itemKey || "item")}-p${partIndex + 1}-${itemIndex + 1}`,
        }));
        return { payload, items };
      }),
    );

    const mergedItems = results.flatMap((result) => result.items);
    const payloads = results.map((result) => result.payload);
    const synthetic = {
      id: `parallel_${payloads.map((payload) => String(payload?.id || "")).filter(Boolean).join("_")}`,
      model: String(payloads[0]?.model || body?.model || ""),
      output_text: JSON.stringify({ items: mergedItems }),
      usage: sumUsage(payloads),
    };

    return new Response(JSON.stringify(synthetic), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    return new Response(
      JSON.stringify({ error: { message: `Parallel Sprint AI chunk failed: ${errorText(error)}` } }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    );
  }
};

await import(
  "https://raw.githubusercontent.com/Hustler031/english-practice/b69257331cdb6d08c1d40fafb5e97d5d64dddc86/supabase/functions/english-ssc-sprint/index.ts"
);

"use client";

import { localProductionSafetyMode, supabaseBrowser } from "./supabase";

export type PhrasalWorkerResult = {
  ok?: boolean;
  lane?: string;
  runId?: string;
  generated?: number;
  reused?: number;
  contextCount?: number;
  expectedContextCount?: number;
  writerRequests?: number;
  criticRequests?: number;
  trigger?: "app" | "scheduler";
  busy?: boolean;
  count?: number;
  error?: string;
  [key: string]: unknown;
};

export async function runPhrasalWorkerDirect(): Promise<PhrasalWorkerResult> {
  if (localProductionSafetyMode()) {
    throw new Error("Direct Phrasal generation is disabled from localhost against production.");
  }
  const { data, error } = await supabaseBrowser().functions.invoke<PhrasalWorkerResult>("english-phrasal-worker", {
    body: { action: "run" },
  });
  if (error) throw error;
  if (!data?.ok && data?.error) throw new Error(data.error);
  return data ?? { ok: false, error: "Phrasal worker returned no result" };
}

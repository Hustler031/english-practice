"use client";

import { type ReactNode, useEffect, useRef, useState } from "react";

import { localProductionSafetyMode, supabaseBrowser } from "@/lib/supabase";

const MIN_SYNC_GAP_MS = 60_000;
const OPEN_APP_HEARTBEAT_MS = 5 * 60_000;
const DAILY_RESUME_CACHE_KEY = "ep:v2:rpc-cache:english_resume_daily:{}";

function evictDailyResumeCache() {
  try { window.localStorage.removeItem(DAILY_RESUME_CACHE_KEY); } catch { /* best effort */ }
}

export default function DailyRolloverSync({ children }: Readonly<{ children: ReactNode }>) {
  const [bootReady, setBootReady] = useState(false);
  const lastSyncAt = useRef(0);
  const lastBatchDate = useRef("");
  const inFlight = useRef<Promise<string> | null>(null);

  useEffect(() => {
    let active = true;

    // english_resume_daily is day-sensitive and also owns the idempotent rollover.
    // Never let yesterday's generic 12-hour cache decide whether today's queue exists.
    evictDailyResumeCache();

    const sync = async (initial = false): Promise<string> => {
      if (!active) return "";
      if (localProductionSafetyMode()) {
        if (initial) setBootReady(true);
        return "";
      }
      if (inFlight.current) {
        const batchDate = await inFlight.current;
        if (initial && active) setBootReady(true);
        return batchDate;
      }
      if (!initial && Date.now() - lastSyncAt.current < MIN_SYNC_GAP_MS) return lastBatchDate.current;

      const work = (async () => {
        const { data: auth } = await supabaseBrowser().auth.getSession();
        if (!auth.session || !active) return "";

        // Direct Supabase RPC is intentional: the cache-first helper must not be
        // allowed to return a previous-day resume payload before rollover runs.
        const { data: daily, error: dailyError } = await supabaseBrowser().rpc("english_resume_daily");
        if (dailyError || !active) return "";
        lastSyncAt.current = Date.now();
        evictDailyResumeCache();

        const batchDate = String((daily as any)?.batch_date || (daily as any)?.today || "");
        const previousBatchDate = lastBatchDate.current;
        if (batchDate) lastBatchDate.current = batchDate;

        // Home is intentionally read-only. Refresh its card only after the live
        // rollover owner has completed, preserving the Local Safe mutation boundary.
        const { data: home, error: homeError } = await supabaseBrowser().rpc("english_get_home_snapshot");
        if (!homeError && home && active) {
          window.dispatchEvent(new CustomEvent("ep:v2-rpc-fresh", {
            detail: { name: "english_get_home_snapshot", args: {}, data: home },
          }));
        }

        // If the app stayed open across midnight on the Daily route, refresh only
        // after a real batch-date change. ensure_daily itself refuses to advance an
        // unfinished previous day, so this cannot discard unfinished Daily work.
        if (!initial && previousBatchDate && batchDate && batchDate !== previousBatchDate
            && window.location.pathname === "/english/daily") {
          window.location.reload();
        }
        return batchDate;
      })().finally(() => {
        inFlight.current = null;
      });

      inFlight.current = work;
      const batchDate = await work;
      if (initial && active) setBootReady(true);
      return batchDate;
    };

    // Children are held until this first live check completes. That guarantees a
    // Daily page cannot run its own cache-first effect before stale resume data is
    // evicted and the current IST-day rollover has been attempted.
    void sync(true).catch(() => {
      if (active) setBootReady(true);
    });

    const onWake = () => {
      if (document.visibilityState === "visible") {
        evictDailyResumeCache();
        void sync(false);
      }
    };
    window.addEventListener("focus", onWake);
    document.addEventListener("visibilitychange", onWake);
    const heartbeat = window.setInterval(() => {
      evictDailyResumeCache();
      void sync(false);
    }, OPEN_APP_HEARTBEAT_MS);

    return () => {
      active = false;
      window.removeEventListener("focus", onWake);
      document.removeEventListener("visibilitychange", onWake);
      window.clearInterval(heartbeat);
    };
  }, []);

  return bootReady ? <>{children}</> : null;
}

"use client";

import { useEffect, useRef } from "react";

import { localProductionSafetyMode, supabaseBrowser } from "@/lib/supabase";

const MIN_SYNC_GAP_MS = 60_000;
const OPEN_APP_HEARTBEAT_MS = 5 * 60_000;
const DAILY_RESUME_CACHE_KEY = "ep:v2:rpc-cache:english_resume_daily:{}";

function evictDailyResumeCache() {
  try { window.localStorage.removeItem(DAILY_RESUME_CACHE_KEY); } catch { /* best effort */ }
}

export default function DailyRolloverSync() {
  const lastSyncAt = useRef(0);
  const inFlight = useRef<Promise<void> | null>(null);

  useEffect(() => {
    let active = true;

    // A Daily resume response is day-sensitive and also owns rollover. Keeping a
    // previous-day response in the generic 12-hour cache can make the new day
    // appear missing, so evict it before any child Daily route reads it.
    evictDailyResumeCache();

    const sync = async () => {
      if (!active || localProductionSafetyMode()) return;
      if (inFlight.current) return inFlight.current;
      if (Date.now() - lastSyncAt.current < MIN_SYNC_GAP_MS) return;

      const work = (async () => {
        const { data: auth } = await supabaseBrowser().auth.getSession();
        if (!auth.session || !active) return;

        // Call the idempotent rollover owner live rather than through the
        // cache-first helper. Local Safe is explicitly excluded above.
        const { error: dailyError } = await supabaseBrowser().rpc("english_resume_daily");
        if (dailyError || !active) return;
        lastSyncAt.current = Date.now();
        evictDailyResumeCache();

        // Refresh the Home card after a successful rollover without making the
        // read model itself mutating. This preserves Local Safe's read-only rule.
        const { data: home, error: homeError } = await supabaseBrowser().rpc("english_get_home_snapshot");
        if (!homeError && home && active) {
          window.dispatchEvent(new CustomEvent("ep:v2-rpc-fresh", {
            detail: { name: "english_get_home_snapshot", args: {}, data: home },
          }));
        }
      })().finally(() => {
        inFlight.current = null;
      });

      inFlight.current = work;
      return work;
    };

    void sync();
    const onWake = () => {
      if (document.visibilityState === "visible") {
        evictDailyResumeCache();
        void sync();
      }
    };
    window.addEventListener("focus", onWake);
    document.addEventListener("visibilitychange", onWake);
    const heartbeat = window.setInterval(() => {
      evictDailyResumeCache();
      void sync();
    }, OPEN_APP_HEARTBEAT_MS);

    return () => {
      active = false;
      window.removeEventListener("focus", onWake);
      document.removeEventListener("visibilitychange", onWake);
      window.clearInterval(heartbeat);
    };
  }, []);

  return null;
}

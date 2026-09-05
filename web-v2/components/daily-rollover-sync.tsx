"use client";

import { useEffect, useRef } from "react";

import { localProductionSafetyMode, supabaseBrowser } from "@/lib/supabase";

const MIN_SYNC_GAP_MS = 60_000;
const OPEN_APP_HEARTBEAT_MS = 5 * 60_000;

export default function DailyRolloverSync() {
  const lastSyncAt = useRef(0);
  const inFlight = useRef<Promise<void> | null>(null);

  useEffect(() => {
    let active = true;

    const sync = async () => {
      if (!active || localProductionSafetyMode()) return;
      if (inFlight.current) return inFlight.current;
      if (Date.now() - lastSyncAt.current < MIN_SYNC_GAP_MS) return;

      const work = (async () => {
        const { data: auth } = await supabaseBrowser().auth.getSession();
        if (!auth.session || !active) return;

        // english_resume_daily is deliberately called live rather than through the
        // cache-first rpc helper. It owns the idempotent previous-day-complete ->
        // current-day rollover contract and must not be hidden by a stale cache.
        const { error: dailyError } = await supabaseBrowser().rpc("english_resume_daily");
        if (dailyError || !active) return;
        lastSyncAt.current = Date.now();

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
      if (document.visibilityState === "visible") void sync();
    };
    window.addEventListener("focus", onWake);
    document.addEventListener("visibilitychange", onWake);
    const heartbeat = window.setInterval(() => void sync(), OPEN_APP_HEARTBEAT_MS);

    return () => {
      active = false;
      window.removeEventListener("focus", onWake);
      document.removeEventListener("visibilitychange", onWake);
      window.clearInterval(heartbeat);
    };
  }, []);

  return null;
}

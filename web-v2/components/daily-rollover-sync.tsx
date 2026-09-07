"use client";

import { type ReactNode, useEffect, useRef, useState } from "react";
import { usePathname } from "next/navigation";

import { localProductionSafetyMode, supabaseBrowser } from "@/lib/supabase";

const MIN_SYNC_GAP_MS = 60_000;
const OPEN_APP_HEARTBEAT_MS = 5 * 60_000;
const DAILY_RESUME_CACHE_KEY = "ep:v2:rpc-cache:english_resume_daily:{}";

function evictDailyResumeCache() {
  try { window.localStorage.removeItem(DAILY_RESUME_CACHE_KEY); } catch { /* best effort */ }
}

export default function DailyRolloverSync({ children }: Readonly<{ children: ReactNode }>) {
  const pathname = usePathname();
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
        if (batchDate || !initial) {
          if (initial && active) setBootReady(true);
          return batchDate;
        }
        // A concurrent initial attempt may have started before Supabase restored the
        // persisted session. Fall through and retry now instead of treating the empty
        // result as a successful rollover check.
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

        // The only route that must wait for the live rollover owner is /english/daily.
        // Release that route as soon as rollover itself is complete; the Home refresh
        // below is informational and must never extend the Daily boot gate.
        if (initial && active) setBootReady(true);

        // Home is intentionally read-only. Refresh its card after the live rollover
        // owner completes, but do this in the background so Home and other English
        // routes can render immediately instead of showing an empty shell.
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

    // Start rollover immediately, but do not blank the entire English app while it
    // runs. Only /english/daily is gated because that route can consume the day-
    // sensitive resume payload. Home and every other route render at once.
    void sync(true).catch(() => {
      if (active) setBootReady(true);
    });

    // The layout can mount before Supabase emits INITIAL_SESSION. If that first
    // getSession() returns empty, retry as soon as auth restoration finishes. This is
    // the key fail-safe that prevents an effectively-complete old Daily from sticking
    // on Home until focus/heartbeat happens later.
    const supabase = supabaseBrowser();
    const { data: authSub } = supabase.auth.onAuthStateChange((event, session) => {
      if (!active || !session || lastSyncAt.current > 0) return;
      if (event === "INITIAL_SESSION" || event === "SIGNED_IN" || event === "TOKEN_REFRESHED" || event === "USER_UPDATED") {
        void sync(true);
      }
    });

    // Also cover transient bootstrap/network ordering where no auth event is emitted
    // after this component subscribes. These are bounded one-shot retries, not a loop.
    const bootRetry1 = window.setTimeout(() => {
      if (active && lastSyncAt.current === 0) void sync(true);
    }, 1500);
    const bootRetry2 = window.setTimeout(() => {
      if (active && lastSyncAt.current === 0) void sync(true);
    }, 5000);

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
      authSub.subscription.unsubscribe();
      window.clearTimeout(bootRetry1);
      window.clearTimeout(bootRetry2);
      window.removeEventListener("focus", onWake);
      document.removeEventListener("visibilitychange", onWake);
      window.clearInterval(heartbeat);
    };
  }, []);

  const blockDailyBoot = pathname === "/english/daily" && !bootReady;
  if (blockDailyBoot) {
    return <div className="loading-shell" role="status" aria-live="polite"><i/><i/><i/><span>Preparing today’s Daily…</span></div>;
  }

  return <>{children}</>;
}
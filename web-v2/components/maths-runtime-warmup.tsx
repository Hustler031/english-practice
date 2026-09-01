"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";
import { mathsRpc, prefetchMathsCore, prefetchMathsPath } from "@/lib/maths-rpc";

function mathsHref(target: EventTarget | null) {
  const element = target instanceof Element ? target : null;
  const anchor = element?.closest<HTMLAnchorElement>('a[href^="/maths"]');
  if (!anchor) return "";
  try { return new URL(anchor.href, window.location.origin).pathname; }
  catch { return anchor.getAttribute("href") || ""; }
}
function timedMathsSession(path: string) {
  return path.startsWith("/maths/session") || path.startsWith("/maths/exam/session");
}
async function prefetchExam() {
  await Promise.allSettled([
    mathsRpc("maths_get_readiness"),
    mathsRpc("maths_get_calculation_hub"),
    mathsRpc("maths_get_weekly_leakage"),
    mathsRpc("maths_get_home_snapshot"),
  ]);
}
async function warmPath(path: string) {
  if (timedMathsSession(path)) return;
  if (path === "/maths/exam" || path.startsWith("/maths/exam?")) {
    await prefetchExam();
    return;
  }
  await prefetchMathsPath(path);
}

export function MathsRuntimeWarmup() {
  const pathname = usePathname();

  useEffect(() => {
    const warmCore = () => {
      if (document.hidden || timedMathsSession(window.location.pathname)) return;
      void prefetchMathsCore();
    };
    const warmTarget = (event: Event) => {
      const href = mathsHref(event.target);
      if (href) void warmPath(href);
    };
    const initial = window.setTimeout(warmCore, 80);
    const interval = window.setInterval(warmCore, 120000);
    window.addEventListener("online", warmCore);
    document.addEventListener("visibilitychange", warmCore);
    document.addEventListener("pointerover", warmTarget, { passive: true });
    document.addEventListener("focusin", warmTarget);
    document.addEventListener("touchstart", warmTarget, { passive: true });
    return () => {
      window.clearTimeout(initial);
      window.clearInterval(interval);
      window.removeEventListener("online", warmCore);
      document.removeEventListener("visibilitychange", warmCore);
      document.removeEventListener("pointerover", warmTarget);
      document.removeEventListener("focusin", warmTarget);
      document.removeEventListener("touchstart", warmTarget);
    };
  }, []);

  useEffect(() => {
    if (timedMathsSession(pathname)) return;
    const timer = window.setTimeout(() => void warmPath(pathname), 0);
    return () => window.clearTimeout(timer);
  }, [pathname]);

  return null;
}

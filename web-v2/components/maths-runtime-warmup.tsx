"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";
import { prefetchMathsCore, prefetchMathsPath } from "@/lib/maths-rpc";

function mathsHref(target: EventTarget | null) {
  const element = target instanceof Element ? target : null;
  const anchor = element?.closest<HTMLAnchorElement>('a[href^="/maths"]');
  if (!anchor) return "";
  try { return new URL(anchor.href, window.location.origin).pathname; }
  catch { return anchor.getAttribute("href") || ""; }
}

export function MathsRuntimeWarmup() {
  const pathname = usePathname();

  useEffect(() => {
    const warmCore = () => {
      if (document.hidden || window.location.pathname.startsWith("/maths/session")) return;
      void prefetchMathsCore();
    };
    const warmTarget = (event: Event) => {
      const href = mathsHref(event.target);
      if (href) void prefetchMathsPath(href);
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
    if (pathname.startsWith("/maths/session")) return;
    const timer = window.setTimeout(() => void prefetchMathsPath(pathname), 0);
    return () => window.clearTimeout(timer);
  }, [pathname]);

  return null;
}

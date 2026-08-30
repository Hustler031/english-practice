"use client";

import type { MouseEvent, ReactNode } from "react";
import "./gk-home-english-parity.css";

export default function GkLayout({ children }: { children: ReactNode }) {
  function forceSamePageNavigation(event: MouseEvent<HTMLDivElement>) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const target = event.target as Element | null;
    const anchor = target?.closest("a");
    if (!anchor) return;
    const href = anchor.getAttribute("href");
    if (!href || href.startsWith("#")) return;
    const url = new URL(href, window.location.href);
    if (url.origin !== window.location.origin || url.pathname !== "/gk" || !url.searchParams.has("tab")) return;
    event.preventDefault();
    event.stopPropagation();
    window.location.assign(`${url.pathname}${url.search}${url.hash}`);
  }

  return <div className="gk-parity-scope" onClickCapture={forceSamePageNavigation}>{children}</div>;
}

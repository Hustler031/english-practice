"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ReactNode, useEffect, useState } from "react";
import { pendingAnswerSaves, prefetchEnglishCore } from "@/lib/supabase";

type Tab = "home" | "practice" | "revision" | "library" | "progress";
type Theme = "dark" | "light";

const tabs: { id: Tab; href: string; icon: string; label: string }[] = [
  { id: "home", href: "/english", icon: "⌂", label: "Home" },
  { id: "practice", href: "/english/practice", icon: "◎", label: "Practice" },
  { id: "revision", href: "/english/revision", icon: "↻", label: "Revision" },
  { id: "library", href: "/english/library", icon: "▦", label: "Library" },
  { id: "progress", href: "/english/progress", icon: "◔", label: "Progress" },
];

function tabForPath(pathname: string): Tab {
  if (pathname === "/english" || pathname.startsWith("/english/daily") || pathname.startsWith("/english/resume")) return "home";
  if (pathname === "/english/practice" || /\/(new|topics|sources|demand|bank)(?:\/|$)/.test(pathname)) return "practice";
  if (pathname === "/english/revision" || /\/(starred|difficult|phrasal)(?:\/|$)/.test(pathname)) return "revision";
  if (pathname === "/english/library" || /\/(saved|hindu|library)(?:\/|$)/.test(pathname)) return "library";
  if (pathname === "/english/progress" || pathname.startsWith("/english/progress/")) return "progress";
  return "home";
}

export function EnglishFrame({ children, tab }: { children: ReactNode; tab?: Tab }) {
  const pathname = usePathname();
  const active = tab ?? tabForPath(pathname);
  const [theme, setTheme] = useState<Theme>("dark");
  const [pendingSaves, setPendingSaves] = useState(0);

  useEffect(() => {
    const saved = window.localStorage.getItem("english-theme");
    const next: Theme = saved === "light" ? "light" : "dark";
    setTheme(next);
    document.documentElement.dataset.theme = next;
    const warm = () => { void prefetchEnglishCore(); };
    const refreshPending = () => setPendingSaves(pendingAnswerSaves());
    warm();refreshPending();
    const warmTimer = window.setInterval(warm, 120000);
    const saveTimer = window.setInterval(refreshPending, 800);
    const onVisible = () => { if (!document.hidden) { warm();refreshPending(); } };
    const onDurable = () => refreshPending();
    window.addEventListener("online", warm);
    window.addEventListener("ep:answer-durable", onDurable as EventListener);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.clearInterval(warmTimer);window.clearInterval(saveTimer);
      window.removeEventListener("online", warm);
      window.removeEventListener("ep:answer-durable", onDurable as EventListener);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);

  function toggleTheme() {
    const next: Theme = theme === "dark" ? "light" : "dark";
    setTheme(next);
    document.documentElement.dataset.theme = next;
    window.localStorage.setItem("english-theme", next);
  }

  return (
    <div className="english-app">
      <header className="english-header">
        <Link href="/english" className="english-brand" aria-label="English Mastery home">
          <strong>English Mastery</strong>
          <span>SSC English practice + revision</span>
        </Link>
        <div className="header-controls">
          {pendingSaves>0&&<span className="sync-pill" title="Answers are stored locally and syncing in the background"><i/>Syncing {pendingSaves}</span>}
          <button className="control-icon theme-toggle" type="button" aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"} onClick={toggleTheme}>{theme === "dark" ? "☀" : "☾"}</button>
        </div>
      </header>
      <div className="english-content">{children}</div>
      <nav className="english-nav" aria-label="English navigation">
        {tabs.map((item) => <Link key={item.id} href={item.href} className={`english-nav-item ${active === item.id ? "active":""}`} aria-current={active === item.id ? "page" : undefined}><b>{item.icon}</b><span>{item.label}</span></Link>)}
      </nav>
    </div>
  );
}

export function EnglishLoading({ text = "Loading…" }: { text?: string }) {
  return <div className="english-app"><div className="loading-shell"><i/><i/><i/><span>{text}</span></div></div>;
}

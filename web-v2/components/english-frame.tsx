"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ReactNode, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase";

type Tab = "home" | "practice" | "revision" | "library" | "progress";

const tabs: { id: Tab; href: string; icon: string; label: string }[] = [
  { id: "home", href: "/english", icon: "⌂", label: "Home" },
  { id: "practice", href: "/english/practice", icon: "▤", label: "Practice" },
  { id: "revision", href: "/english/revision", icon: "★", label: "Revision" },
  { id: "library", href: "/english/library", icon: "▥", label: "Library" },
  { id: "progress", href: "/english/progress", icon: "◔", label: "Progress" },
];

function tabForPath(pathname: string): Tab {
  // Keep the selected tab tied to the current route, never to the page that
  // happened to launch the nested screen.
  if (pathname === "/english" || pathname.startsWith("/english/daily") || pathname.startsWith("/english/resume")) return "home";
  if (/\/(new|topics|sources|demand)/.test(pathname)) return "practice";
  if (/\/(starred|difficult|phrasal)/.test(pathname)) return "revision";
  if (/\/(saved|hindu|library)/.test(pathname)) return "library";
  if (pathname.includes("/progress")) return "progress";
  return "home";
}

export function EnglishFrame({ children, tab }: { children: ReactNode; tab?: Tab }) {
  const pathname = usePathname();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const active = tab ?? tabForPath(pathname);

  async function signOut() {
    await supabaseBrowser().auth.signOut();
    router.replace("/login");
  }

  return (
    <div className="english-app">
      <header className="english-header">
        <Link href="/english" className="english-brand" aria-label="English Mastery home">
          <strong>English Mastery</strong>
          <span>SSC English practice + revision</span>
        </Link>
        <div className="header-controls">
          <Link href="/" className="control-icon" aria-label="All subjects">⌘</Link>
          <button className="control-icon" aria-label="Settings" aria-expanded={open} onClick={() => setOpen((v) => !v)}>⚙</button>
          {open && <div className="settings-popover"><button onClick={signOut}>Sign out</button></div>}
        </div>
      </header>
      <div className="english-content">{children}</div>
      <nav className="english-nav" aria-label="English navigation">
        {tabs.map((item) => <Link key={item.id} href={item.href} className={`english-nav-item ${active === item.id ? "active" : ""}`} aria-current={active === item.id ? "page" : undefined}><b>{item.icon}</b><span>{item.label}</span></Link>)}
      </nav>
    </div>
  );
}

export function EnglishLoading({ text = "Loading…" }: { text?: string }) {
  return <div className="english-app"><div className="loading-copy">{text}</div></div>;
}

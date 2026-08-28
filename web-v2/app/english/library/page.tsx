"use client";

import Link from "next/link";
import { EnglishLoading } from "@/components/english-frame";
import { useAuthGuard } from "@/lib/use-auth";

const rows = [["📝", "My Saved Words", "Manage saved words, doubts and usage points", "/english/saved"], ["★", "Starred Collection", "Your marked revision questions", "/english/starred"], ["!", "Difficult Collection", "Questions that need deliberate practice", "/english/difficult"], ["📰", "The Hindu Vocabulary", "Today&apos;s vocabulary and history", "/english/hindu"], ["↗", "Phrasal Verb Bank", "Concept bank and permanent history", "/english/phrasal"], ["📚", "Source / PDF Collections", "Browse content by its source", "/english/sources"]];
export default function LibraryHome() { const ready = useAuthGuard(); if (!ready) return <EnglishLoading text="Checking session…" />; return <><section className="page-intro"><h1>Library</h1><p>What you have saved and what content is available.</p></section><div className="study-list">{rows.map(([icon, title, sub, href]) => <Link className="study-row" href={href} key={href}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{sub}</small></span><i>›</i></Link>)}</div></>; }

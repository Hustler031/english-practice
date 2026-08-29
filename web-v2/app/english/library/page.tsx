"use client";
import Link from "next/link";
import { EnglishLoading } from "@/components/english-frame";
import { useAuthGuard } from "@/lib/use-auth";
const rows=[["📝 My Words","View and manage every word you captured","/english/words?return=/english/library"],["↗ Phrasal Verb","Today’s 20 · Smart Revision · permanent concept history","/english/phrasal"],["📚 Sources / PDFs","Automatically grows as new material is added","/english/sources?return=/english/library"],["📰 The Hindu Vocabulary","Today’s words and practice rounds","/english/hindu?return=/english/library"]];
export default function LibraryHome(){const ready=useAuthGuard();if(!ready)return <EnglishLoading text="Checking session…"/>;return <div className="top-level-parity"><section className="page-intro"><h1>Library</h1><p>Your saved words and study sources.</p></section><div className="legacy-list">{rows.map(([name,sub,href])=><Link className="legacy-row" href={href} key={href}><span className="legacy-row-copy"><b>{name}</b><small>{sub}</small></span><span className="legacy-chevron">›</span></Link>)}</div></div>}

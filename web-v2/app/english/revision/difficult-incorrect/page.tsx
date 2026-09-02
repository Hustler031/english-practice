"use client";

import Link from "next/link";
import { EnglishLoading } from "@/components/english-frame";
import { useAuthGuard } from "@/lib/use-auth";

export default function DifficultIncorrectPage(){
 const ready=useAuthGuard();
 if(!ready)return <EnglishLoading text="Checking session…"/>;
 return <main className="top-level-parity revision-clean-page">
  <section className="page-intro"><Link href="/english/revision" className="back-link">← Revision</Link><span className="intelligence-kicker">Repair practice</span><h1>Difficult &amp; Incorrect</h1><p>Choose the evidence you want to repair.</p></section>
  <section className="revision-primary-list">
   <Link className="revision-primary-row tone-repair" href="/english/weak"><span className="revision-row-icon">!</span><span><b>Incorrect &amp; Weak</b><small>Questions and concepts with recent wrong or weak evidence</small></span><i>›</i></Link>
   <Link className="revision-primary-row tone-due" href="/english/difficult"><span className="revision-row-icon">⚡</span><span><b>Difficult</b><small>Items you manually marked as difficult</small></span><i>›</i></Link>
  </section>
 </main>;
}

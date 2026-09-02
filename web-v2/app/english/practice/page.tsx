"use client";

import Link from "next/link";
import { EnglishLoading } from "@/components/english-frame";
import { useAuthGuard } from "@/lib/use-auth";

const primary=[
 ["▸","Daily Practice","Today’s adaptive due work","/english/daily","daily"],
 ["◎","Targeted Mastery","Focused repair from mistakes, uncertainty and confusions","/english/targeted","targeted"],
 ["⚡","Fast Track","Accelerated proof for concepts that may already be strong","/english/fast-track","fast"],
 ["＋","New Practice","Recently added content by category","/english/new","new"],
 ["▦","Topic Practice","Choose a topic and practise deliberately","/english/topics","topic"],
 ["↗","Exam Sprint","SSC-focused exam preparation and sprint work","/english/exam","exam"],
] as const;
const more=[
 ["Source / PDF Practice","Named PDFs, notes, The Hindu and imported sources","/english/sources?return=/english/practice"],
 ["Demanded Practice","Your saved custom practice batches","/english/demand"],
 ["Bank Coverage","Explore unseen genuine-bank questions","/english/bank"],
] as const;

export default function PracticeHome(){
 const ready=useAuthGuard();if(!ready)return <EnglishLoading text="Checking session…"/>;
 return <main className="top-level-parity practice-clean-page">
  <section className="page-intro"><h1>Practice</h1><p>Choose the kind of practice you need.</p></section>
  <section className="practice-primary-grid">{primary.map(([icon,title,sub,href,tone])=><Link className={`practice-primary-card tone-${tone}`} href={href} key={href}><span className="practice-primary-icon">{icon}</span><span><b>{title}</b><small>{sub}</small></span><i>›</i></Link>)}</section>
  <details className="practice-more-details"><summary><span><b>More practice options</b><small>Sources, custom batches and bank coverage</small></span><i>›</i></summary><div className="practice-more-list">{more.map(([title,sub,href])=><Link href={href} key={href}><span><b>{title}</b><small>{sub}</small></span><i>›</i></Link>)}</div></details>
 </main>;
}

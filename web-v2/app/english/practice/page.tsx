"use client";
import Link from "next/link";
import { EnglishLoading } from "@/components/english-frame";
import { useAuthGuard } from "@/lib/use-auth";

const explore=[["✨ New Practice","Recently added content by category","/english/new"],["◫ Bank Coverage","Explore unseen genuine-bank questions","/english/bank"]];
const focused=[["🎯 Topic Practice","Choose a topic, mode and number of questions","/english/topics"],["📚 Source / PDF Practice","Handwritten notes, The Hindu, screenshots and named PDFs/sources","/english/sources?return=/english/practice"],["🎯 Demanded Practice","Saved custom batches created for exactly what you want to practise","/english/demand"]];
export default function PracticeHome(){const ready=useAuthGuard();if(!ready)return <EnglishLoading text="Checking session…"/>;return <div className="top-level-parity"><section className="page-intro"><h1>Practice</h1><p>Choose a focused practice area.</p></section><Section title="Explore" rows={explore}/><Section title="Focused Practice" rows={focused}/></div>}
function Section({title,rows}:{title:string;rows:string[][]}){return <section className="section-block"><h2 className="section-cap">{title}</h2><div className="legacy-list">{rows.map(([name,sub,href])=><Link className="legacy-row" href={href} key={href}><span className="legacy-row-copy"><b>{name}</b><small>{sub}</small></span><span className="legacy-chevron">›</span></Link>)}</div></section>}

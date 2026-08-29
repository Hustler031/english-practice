"use client";
import Link from "next/link";
import { EnglishLoading } from "@/components/english-frame";
import { useAuthGuard } from "@/lib/use-auth";

const personal=[["📝 My Words","View and manage every word you captured","/english/words?return=/english/library"],["↗ Phrasal Verb","Today’s batch, Smart Revision and concept history","/english/phrasal"]] as const;
const sources=[["📰 The Hindu – Today","Today’s vocabulary batch","/english/hindu?return=/english/library"],["📚 Sources / PDFs","PDFs, screenshots and older The Hindu days grouped by source and date","/english/sources?return=/english/library"]] as const;

function Rows({rows}:{rows:readonly (readonly [string,string,string])[]}){return <div className="legacy-list">{rows.map(([name,sub,href])=><Link className="legacy-row" href={href} key={href}><span className="legacy-row-copy"><b>{name}</b><small>{sub}</small></span><span className="legacy-chevron">›</span></Link>)}</div>}

export default function LibraryHome(){const ready=useAuthGuard();if(!ready)return <EnglishLoading text="Checking session…"/>;return <div className="top-level-parity"><section className="page-intro"><h1>Library</h1><p>Your own learning first, then reading and source history.</p></section><div className="library-groups"><section className="library-group"><div className="section-cap">My Learning</div><Rows rows={personal}/></section><section className="library-group"><div className="section-cap">Reading & Sources</div><Rows rows={sources}/></section></div></div>}

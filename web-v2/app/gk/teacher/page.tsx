"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { gkRpc } from "@/lib/gk-rpc";
import { useAuthGuard } from "@/lib/use-auth";

type Lecture={seriesId:string;seriesKind:string;title:string;lectureKey:string;sourceLabel?:string;sourceDate?:string;total:number;exposed:number;weak:number;mastered:number};
type Library={ok:boolean;lectures:Lecture[]};
const SERIES:[{id:string;title:string;copy:string;kind:string},{id:string;title:string;copy:string;kind:string}]=[
 {id:"TEACHER_TOPIC_PYQ",title:"Topic-wise PYQ",copy:"Concept-building and gap-filling. One global learning history.",kind:"TOPIC_PYQ"},
 {id:"TEACHER_MIXED_PYQ",title:"Mixed PYQ",copy:"Interleaving and exam-transfer while preserving real subject/topic classification.",kind:"MIXED_PYQ"}
];
const qs=(p:Record<string,string|number|null>)=>`/gk/quiz?${new URLSearchParams(Object.entries(p).filter(([,v])=>v!==null&&v!=="").map(([k,v])=>[k,String(v)]))}`;
function percent(a:number,b:number){return b?Math.round(a*1000/b)/10:0}

export default function TeacherLibraryPage(){
 const ready=useAuthGuard();const[data,setData]=useState<Library|null>(null),[series,setSeries]=useState(""),[error,setError]=useState("");
 useEffect(()=>{if(!ready)return;const p=new URLSearchParams(window.location.search);setSeries(p.get("series")||"");let live=true;gkRpc<Library>("gk_get_teacher_library").then(x=>{if(live&&x?.ok)setData(x)}).catch(()=>{if(live)setError("Teacher library could not be refreshed.")});return()=>{live=false};},[ready]);
 const lectures=useMemo(()=>data?.lectures.filter(x=>!series||x.seriesId===series)||[],[data,series]);
 if(!ready||!data)return <main className="gk-intel-page"><div className="loading-copy">Loading Teacher PYQ…</div>{error&&<div className="gk-intel-notice">{error}</div>}</main>;
 if(!series)return <main className="gk-intel-page"><section className="gk-intel-title"><div><span>Teacher content authority</span><h1>Teacher PYQ</h1><p>Topic-wise and Mixed are source libraries, not separate mastery systems. A canonical question carries one learning history everywhere it appears.</p></div><Link className="gk-intel-secondary" href="/gk/intelligence">View progress</Link></section><section className="gk-intel-grid2">{SERIES.map(s=>{const rows=data.lectures.filter(x=>x.seriesId===s.id),total=rows.reduce((a,x)=>a+x.total,0),seen=rows.reduce((a,x)=>a+x.exposed,0);return <Link className="gk-intel-card gk-teacher-series" href={`/gk/teacher?series=${s.id}`} key={s.id}><span>{s.kind.replaceAll("_"," ")}</span><h2>{s.title}</h2><p>{s.copy}</p><div><b>{rows.length}</b> lectures · <b>{total}</b> memberships · <b>{percent(seen,total)}%</b> exposed</div></Link>})}</section><section className="gk-intel-card"><div className="gk-intel-cardhead"><div><span>Content rule</span><h2>Teacher remains authoritative</h2></div></div><p>GPT enrichment, verification, memory cues and Booster material remain a support layer. They do not silently replace teacher provenance or create an independent mastery engine.</p></section></main>;
 const def=SERIES.find(x=>x.id===series);
 return <main className="gk-intel-page"><div className="gk-intel-back"><Link href="/gk/teacher">← Teacher PYQ</Link></div><section className="gk-intel-title"><div><span>{def?.kind.replaceAll("_"," ")}</span><h1>{def?.title||"Teacher Series"}</h1><p>{def?.copy}</p></div><Link className="gk-intel-primary" href={qs({teacherSeries:series,mode:"smart",lane:"MIXED",count:20,title:`${def?.title||"Teacher PYQ"} · Smart`})}>Smart Practice</Link></section>{error&&<div className="gk-intel-notice">{error}</div>}<section className="gk-intel-card"><div className="gk-intel-cardhead"><div><span>Lectures</span><h2>Source progress</h2></div><small>{lectures.length} lecture identities</small></div><div className="gk-intel-series">{lectures.map(l=><div className="gk-intel-seriesrow" key={`${l.seriesId}-${l.lectureKey}`}><div><b>{l.sourceLabel||l.lectureKey}</b><small>{l.exposed}/{l.total} exposed · {l.weak} weak · {l.mastered} mastered</small></div><strong>{percent(l.exposed,l.total)}%</strong><div className="gk-intel-bar"><i style={{width:`${percent(l.exposed,l.total)}%`}}/></div><div className="gk-intel-actions"><Link href={qs({teacherSeries:series,lecture:l.lectureKey,mode:"all",lane:"MIXED",count:20,title:l.sourceLabel||"Teacher Lecture"})}>Practice</Link><Link href={qs({teacherSeries:series,lecture:l.lectureKey,mode:"weak",lane:"MIXED",count:20,title:`${l.sourceLabel||"Lecture"} · Weak`})}>Weak</Link><Link href={qs({teacherSeries:series,lecture:l.lectureKey,mode:"new",lane:"MAIN",count:20,title:`${l.sourceLabel||"Lecture"} · New Main`})}>New Main</Link></div></div>)}</div></section></main>;
}

"use client";
import Link from "next/link";
import { useCallback,useEffect,useState } from "react";
import QuizRunner from "@/components/quiz-runner";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
type Group={id:string;name:string;total:number;weak:number;started:number;newCount:number};
export default function TopicsPage(){const ready=useAuthGuard();const [groups,setGroups]=useState<Group[]>([]);const [pick,setPick]=useState<{g:Group;mode:string}|null>(null);useEffect(()=>{if(ready)rpc<Group[]>("english_get_topic_hub").then(setGroups)},[ready]);const load=useCallback(()=>pick?rpc<any[]>("english_get_topic_batch",{p_category:pick.g.id,p_mode:pick.mode,p_count:30}):Promise.resolve([]),[pick]);if(!ready)return <main className="center"><div className="muted">Checking session…</div></main>;if(pick)return <QuizRunner title={`${pick.g.name} · ${pick.mode}`} backHref="/english/topics" load={load}/>;return <main className="shell"><div className="topbar"><Link className="btn ghost" href="/english">← English</Link><div className="brand">Topic Practice</div></div><div className="grid">{groups.map(g=><div className="card stack" key={g.id}><div><h3>{g.name}</h3><div className="muted">{g.total} active · {g.weak} weak · {g.started} started · {g.newCount} new</div></div><div className="row">{["weak","started","new","random","all"].map(m=><button key={m} className="btn" onClick={()=>setPick({g,mode:m})}>{m}</button>)}</div></div>)}</div></main>}

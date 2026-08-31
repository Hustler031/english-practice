"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { gkRpc, isGkLocalSafe } from "@/lib/gk-rpc";
import { useAuthGuard } from "@/lib/use-auth";

type RepairSet={ok:boolean;setId?:string;title?:string;count?:number;message?:string};

export default function GkSprintRepairLauncher(){
 const ready=useAuthGuard();
 const[error,setError]=useState("");
 useEffect(()=>{if(!ready)return;const p=new URLSearchParams(window.location.search),session=p.get("session")||"",concept=p.get("concept")||"",count=Math.max(1,Math.min(40,Number(p.get("count")||12)));if(!session){setError("Sprint repair session is missing.");return;}if(isGkLocalSafe()){setError("Local Safe keeps production repair-set creation disabled. Open this repair from production after validation.");return;}let live=true;gkRpc<RepairSet>("gk_create_sprint_repair_set",{p_exam_session_id:session,p_concept_key:concept||null,p_count:count}).then(x=>{if(!live)return;if(!x?.ok||!x.setId){setError(x?.message||"No canonical repair questions are available for this recommendation.");return;}const query=new URLSearchParams({mode:"demand",demand:x.setId,lane:"MIXED",count:String(x.count||count),title:x.title||"Sprint Smart Repair"});window.location.replace(`/gk/quiz?${query}`);}).catch(()=>{if(live)setError("Repair session could not be prepared. Your Sprint result is still safe.");});return()=>{live=false};},[ready]);
 if(!ready)return <main className="gk-intel-page"><div className="loading-copy">Checking session…</div></main>;
 return <main className="gk-intel-page"><section className="gk-intel-title"><div><span>Sprint Repair</span><h1>{error?"Repair not started":"Preparing targeted learning…"}</h1><p>{error||"Selecting verified canonical questions from the concepts that cost marks. The normal GK QuizEngine will own the learning session."}</p></div></section>{error&&<div className="gk-intel-actions"><Link href="/gk/sprint">Back to Sprint</Link><Link href="/gk/intelligence">Open Progress</Link></div>}</main>;
}

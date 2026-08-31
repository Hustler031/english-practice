"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { learnerErrorMessage, localProductionSafetyMode, rpc, supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type ActiveSprint={ok?:boolean;active?:boolean;sessionId?:string;status?:string;currentPosition?:number};
type MarksPayload={ok?:boolean;items?:{position:number}[]};
type MarkResult={ok?:boolean;saved?:boolean;subject?:string;pending?:boolean};

async function liveRpc<T>(name:string,args?:Record<string,unknown>):Promise<T>{
  const {data,error}=await supabaseBrowser().rpc(name,args||{});
  if(error)throw error;
  return data as T;
}

export default function SprintBankCapture(){
  const ready=useAuthGuard();
  const[sessionId,setSessionId]=useState("");
  const[position,setPosition]=useState(0);
  const[marks,setMarks]=useState<Set<number>>(new Set());
  const[visible,setVisible]=useState(false);
  const[busy,setBusy]=useState(false);
  const[error,setError]=useState("");
  const fetching=useRef(false);
  const finalized=useRef("");

  const loadSession=useCallback(async()=>{
    if(fetching.current||!ready)return;
    fetching.current=true;
    try{
      const active=await liveRpc<ActiveSprint>("english_get_active_sprint");
      if(!active?.active||!active.sessionId)return;
      setSessionId(active.sessionId);
      const saved=await liveRpc<MarksPayload>("english_get_sprint_bank_marks",{p_session_id:active.sessionId});
      setMarks(new Set((saved?.items||[]).map(x=>Number(x.position)).filter(Boolean)));
    }catch{}finally{fetching.current=false}
  },[ready]);

  const syncDom=useCallback(()=>{
    if(typeof document==="undefined")return;
    const question=document.querySelector(".sprint-question-clean");
    const result=document.querySelector(".sprint-result-clean");
    const home=document.querySelector(".exam-clean-page");
    if(home&&!question&&!result){setVisible(false);setPosition(0);setSessionId("");setMarks(new Set());finalized.current="";return;}
    if(question){
      setVisible(true);
      const text=document.querySelector(".sprint-command-title span")?.textContent||"";
      const match=text.match(/Q\s*(\d+)\s*\//i);
      if(match)setPosition(Number(match[1]));
      if(!sessionId)void loadSession();
      return;
    }
    setVisible(false);
    if(result&&sessionId&&finalized.current!==sessionId&&!localProductionSafetyMode()){
      finalized.current=sessionId;
      void rpc("english_finalize_sprint_bank_marks",{p_session_id:sessionId}).catch(()=>{finalized.current=""});
    }
  },[loadSession,sessionId]);

  useEffect(()=>{
    if(!ready||typeof document==="undefined")return;
    syncDom();
    const observer=new MutationObserver(syncDom);
    observer.observe(document.body,{subtree:true,childList:true,characterData:true});
    return()=>observer.disconnect();
  },[ready,syncDom]);

  async function toggle(){
    if(!sessionId||!position||busy)return;
    if(localProductionSafetyMode()){setError("Sprint Bank writes are disabled in Local Safe.");return;}
    const next=!marks.has(position);setBusy(true);setError("");
    setMarks(current=>{const copy=new Set(current);next?copy.add(position):copy.delete(position);return copy});
    try{
      const out=await rpc<MarkResult>("english_set_sprint_bank_mark",{p_session_id:sessionId,p_position:position,p_saved:next});
      if(out?.ok===false)throw new Error("Could not update Sprint Bank");
    }catch(e:any){
      setMarks(current=>{const copy=new Set(current);next?copy.delete(position):copy.add(position);return copy});
      setError(learnerErrorMessage(e,"Could not update Sprint Bank."));
    }finally{setBusy(false)}
  }

  if(!ready||!visible||!position)return null;
  const saved=marks.has(position);
  return <div className="sprint-bank-capture-wrap">
    <button type="button" className={`sprint-bank-capture ${saved?"saved":""}`} disabled={busy||!sessionId} aria-pressed={saved} onClick={()=>void toggle()}>{saved?"✓ Bank":"+ Bank"}</button>
    {error&&<span className="sprint-bank-capture-error">{error}</span>}
  </div>;
}

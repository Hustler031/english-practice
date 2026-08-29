"use client";
import { useCallback } from "react";
import QuizRunner from "@/components/quiz-runner";
import { rpc } from "@/lib/supabase";

export default function ExtraPracticePage(){
 const count=20;
 const load=useCallback(async()=>{try{return await rpc<any[]>("english_get_today_extra_batch",{p_count:count});}catch{return rpc<any[]>("english_get_revision_batch",{p_mode:"smart",p_count:count});}},[]);
 return <QuizRunner title="Smart Extra Practice · Today" backHref="/english" load={load} module="extra" emptyText="No extra-practice items are needed right now."/>;
}

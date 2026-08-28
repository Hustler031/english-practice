"use client";
import { useCallback } from "react";
import QuizRunner from "@/components/quiz-runner";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
export default function StarredPage(){const ready=useAuthGuard();const load=useCallback(()=>rpc<any[]>("english_get_starred_items",{p_mode:"all",p_count:100}),[]);if(!ready)return <main className="center"><div className="muted">Checking session…</div></main>;return <QuizRunner title="Starred Revision" backHref="/english/revision" load={load}/>}

"use client";
import { useCallback } from "react";
import QuizRunner from "@/components/quiz-runner";
import { rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";
export default function DifficultPage(){const ready=useAuthGuard();const load=useCallback(()=>rpc<any[]>("english_get_difficult_items",{p_count:100}),[]);if(!ready)return <main className="center"><div className="muted">Checking session…</div></main>;return <QuizRunner title="Difficult Revision" backHref="/english" load={load}/>}

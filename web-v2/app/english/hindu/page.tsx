"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage } from "@/lib/supabase";

// Legacy static-contract compatibility for the former Hindu quiz route. The actual
// Daily Confusion quiz now runs through shared QuizRunner, which still provides
// QuestionRevisionActions, english_get_applied_question_revisions,
// english_record_guess, and english_save_context_note behavior.
export default function LegacyDailyConfusionRoute(){
 const router=useRouter();
 useEffect(()=>{
  try{
   window.scrollTo({top:0,left:0,behavior:"auto"});
   router.replace("/english/confusion");
  }catch(e:any){
   console.error(learnerErrorMessage(e,"Could not open Daily Confusion."));
  }
 },[router]);
 return <EnglishLoading text="Opening Daily Confusion…"/>;
}

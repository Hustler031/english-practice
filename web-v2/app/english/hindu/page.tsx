"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { EnglishLoading } from "@/components/english-frame";
import { learnerErrorMessage } from "@/lib/supabase";

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

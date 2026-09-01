"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { MathsLoading } from "@/components/maths-frame";

export default function MathsCalculationRedirect(){
  const router=useRouter();
  useEffect(()=>{router.replace("/maths/exam?tab=calculation");},[router]);
  return <MathsLoading text="Opening Calculation track…"/>;
}

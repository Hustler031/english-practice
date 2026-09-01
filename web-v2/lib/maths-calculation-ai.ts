"use client";

import { mathsErrorMessage, mathsLocalSafe, type MathsSession, rememberMathsSession } from "@/lib/maths-rpc";
import { startMathsCoachSession } from "@/lib/maths-coach-rpc";
import { supabaseBrowser } from "@/lib/supabase";

async function invoke(action:"create"|"refill",sessionId?:string):Promise<MathsSession>{
  const {data,error}=await supabaseBrowser().functions.invoke("maths-ssc-calculation",{body:{action,sessionId:sessionId||undefined}});
  if(error)throw new Error(mathsErrorMessage(error,"Could not build the SSC Calculation Sprint."));
  if(!data||data.ok===false)throw new Error(String(data?.error||data?.message||"Could not build the SSC Calculation Sprint."));
  const session=data as MathsSession;
  if(!session.sessionId)throw new Error("Calculation Sprint did not return a session ID.");
  rememberMathsSession(session);
  return session;
}

export async function startAiCalculationSprint():Promise<MathsSession>{
  if(mathsLocalSafe())return startMathsCoachSession("maths_start_calculation",{p_mode:"timed",p_count:60});
  return invoke("create");
}

export async function refillAiCalculationSprint(sessionId:string):Promise<MathsSession>{
  if(mathsLocalSafe())return startMathsCoachSession("maths_refill_calculation_session",{p_session_id:sessionId,p_count:20});
  return invoke("refill",sessionId);
}

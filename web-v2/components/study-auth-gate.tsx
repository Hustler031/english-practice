"use client";

import type { FormEvent, ReactNode } from "react";
import { useEffect, useState } from "react";
import { englishSupabaseBrowser, studySupabaseBrowser } from "@/lib/study-supabase";

type GateState = "checking" | "login" | "sending" | "sent" | "ready" | "error";

export function StudyAuthGate({ children, subject }: { children: ReactNode; subject: "Maths" | "GK" }) {
  const [state, setState] = useState<GateState>("checking");
  const [email, setEmail] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    let cancelled = false;
    let sourceUserId = "";
    const study = studySupabaseBrowser();

    const acceptSession = (studyUserId?: string | null) => {
      if (!studyUserId) return false;
      if (sourceUserId && sourceUserId !== studyUserId) {
        setMessage("The Study session belongs to a different account. Sign out of that Study session and reconnect.");
        setState("error");
        return true;
      }
      setState("ready");
      return true;
    };

    const boot = async () => {
      try {
        const source = await englishSupabaseBrowser().auth.getSession();
        sourceUserId = source.data.session?.user.id ?? "";
        const sourceEmail = source.data.session?.user.email ?? "";
        if (!cancelled && sourceEmail) setEmail(sourceEmail);

        const current = await study.auth.getSession();
        if (cancelled) return;
        if (current.error) throw current.error;
        if (acceptSession(current.data.session?.user.id)) return;
        setState("login");
      } catch (error) {
        if (cancelled) return;
        setMessage(error instanceof Error ? error.message : "Could not verify the Study session.");
        setState("error");
      }
    };

    void boot();
    const { data: listener } = study.auth.onAuthStateChange((_event, session) => {
      if (!cancelled && session?.user?.id) acceptSession(session.user.id);
    });
    return () => {
      cancelled = true;
      listener.subscription.unsubscribe();
    };
  }, []);

  async function sendLink(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const cleanEmail = email.trim();
    if (!cleanEmail) {
      setMessage("Enter the email used for this revision app.");
      return;
    }
    setState("sending");
    setMessage("");
    try {
      const target = `${window.location.origin}${window.location.pathname}${window.location.search}`;
      const { error } = await studySupabaseBrowser().auth.signInWithOtp({
        email: cleanEmail,
        options: { shouldCreateUser: false, emailRedirectTo: target },
      });
      if (error) throw error;
      setState("sent");
      setMessage("Sign-in link sent. Open it on this device; this page will unlock automatically after the Study session is created.");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Could not send the Study sign-in link.");
      setState("login");
    }
  }

  if (state === "ready") return <>{children}</>;

  return <main style={{minHeight:"70vh",display:"grid",placeItems:"center",padding:"24px"}}>
    <section style={{width:"min(460px,100%)",border:"1px solid rgba(148,163,184,.22)",borderRadius:18,padding:22,background:"rgba(15,23,42,.72)",boxShadow:"0 18px 50px rgba(0,0,0,.18)"}}>
      <div style={{fontSize:12,fontWeight:800,letterSpacing:".12em",opacity:.62,marginBottom:8}}>STUDY BACKEND</div>
      <h1 style={{fontSize:22,margin:"0 0 8px"}}>{state === "checking" ? `Checking ${subject} session…` : `Connect ${subject}`}</h1>
      <p style={{margin:"0 0 18px",lineHeight:1.55,opacity:.78}}>
        {state === "checking"
          ? "Verifying the separate Maths/GK Supabase session."
          : "Maths and GK now use their own Supabase project. English stays on the existing project. This is a one-time sign-in for the Study backend."}
      </p>

      {state !== "checking" && <form onSubmit={sendLink} style={{display:"grid",gap:12}}>
        <input
          type="email"
          autoComplete="email"
          value={email}
          onChange={event => setEmail(event.target.value)}
          placeholder="Email"
          disabled={state === "sending" || state === "sent"}
          style={{width:"100%",boxSizing:"border-box",borderRadius:12,border:"1px solid rgba(148,163,184,.3)",padding:"12px 14px",fontSize:15,background:"rgba(2,6,23,.48)",color:"inherit"}}
        />
        <button
          type="submit"
          disabled={state === "sending" || state === "sent"}
          style={{border:0,borderRadius:12,padding:"12px 14px",fontSize:14,fontWeight:800,cursor:state === "sending" || state === "sent" ? "default" : "pointer"}}
        >
          {state === "sending" ? "Sending…" : state === "sent" ? "Link sent" : "Send one-time sign-in link"}
        </button>
      </form>}

      {message && <p style={{margin:"14px 0 0",fontSize:13,lineHeight:1.5,opacity:.82}}>{message}</p>}
      {state === "error" && <button type="button" onClick={() => window.location.reload()} style={{marginTop:14,borderRadius:10,padding:"9px 12px",cursor:"pointer"}}>Retry</button>}
    </section>
  </main>;
}

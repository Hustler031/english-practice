"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    const { error } = await supabaseBrowser().auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) return setError(error.message);
    router.replace("/english");
  }

  return (
    <main className="login-shell">
      <section className="login-visual">
        <div className="login-copy">
          <div className="eyebrow">Revision Platform · V2</div>
          <h1 className="login-title">Study fast.<br/>Remember longer.</h1>
          <p className="login-note">Your Daily, weak areas, saved doubts and focused practice in one responsive revision workspace.</p>
        </div>
      </section>

      <section className="login-panel">
        <form className="login-card stack" onSubmit={submit}>
          <div>
            <div className="brand-sub">Welcome back</div>
            <div className="brand" style={{fontSize:28}}>Sign in to Revision</div>
            <p className="muted" style={{lineHeight:1.55}}>Continue from the exact state you left on any device.</p>
          </div>
          <div className="stack" style={{gap:10}}>
            <input className="input" type="email" placeholder="Email address" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} required/>
            <input className="input" type="password" placeholder="Password" autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)} required/>
          </div>
          {error&&<div className="error-box">{error}</div>}
          <button className="btn primary" style={{width:"100%"}} disabled={busy}>{busy?"Signing in…":"Sign in →"}</button>
          <div className="muted-2" style={{fontSize:12,textAlign:"center"}}>Secure session powered by Supabase Auth</div>
        </form>
      </section>
    </main>
  );
}

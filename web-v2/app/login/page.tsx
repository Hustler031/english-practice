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
    e.preventDefault(); setBusy(true); setError("");
    const { error } = await supabaseBrowser().auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) return setError(error.message);
    router.replace("/english");
  }

  return <main className="center"><form className="card auth stack" onSubmit={submit}><div><div className="brand">Revision Platform</div><p className="muted">Sign in to your revision data.</p></div><input className="input" type="email" placeholder="Email" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} required/><input className="input" type="password" placeholder="Password" autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)} required/>{error&&<div className="error">{error}</div>}<button className="btn primary" disabled={busy}>{busy?"Signing in…":"Sign in"}</button></form></main>;
}

"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase";

export default function LoginPage() {
  const router = useRouter(); const [email, setEmail] = useState(""); const [password, setPassword] = useState(""); const [error, setError] = useState(""); const [busy, setBusy] = useState(false);
  async function submit(event: FormEvent) { event.preventDefault(); setBusy(true); setError(""); const { error: signInError } = await supabaseBrowser().auth.signInWithPassword({ email, password }); setBusy(false); if (signInError) return setError(signInError.message); router.replace("/"); }
  return <main className="login-page"><form className="login-card stack" onSubmit={submit}><div className="login-heading"><strong>English Mastery</strong><span>SSC English practice + revision</span></div><p className="muted">Sign in to continue your revision.</p><input className="input" type="email" placeholder="Email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required /><input className="input" type="password" placeholder="Password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />{error && <div className="error-box">{error}</div>}<button className="btn primary full-width" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button></form></main>;
}

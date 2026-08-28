import Link from "next/link";

export default function Home() {
  return (
    <main className="shell">
      <div className="topbar"><div><div className="brand">Revision Platform</div><div className="muted">One fast home for SSC revision.</div></div><Link className="btn" href="/login">Sign in</Link></div>
      <div className="grid">
        <Link className="card" href="/english"><h2>English</h2><p className="muted">Daily, My Saved, Starred, Difficult, Hindu, Topic and Source practice.</p><span className="pill">V2 active build</span></Link>
        <div className="card"><h2>GK</h2><p className="muted">Module slot reserved. Existing GK app remains isolated.</p><span className="pill">Migration later</span></div>
        <div className="card"><h2>Maths</h2><p className="muted">Module slot reserved. Existing Maths app remains isolated.</p><span className="pill">Migration later</span></div>
      </div>
    </main>
  );
}

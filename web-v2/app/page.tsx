import Link from "next/link";

export default function Home() {
  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <div className="brand-sub">SSC Revision</div>
          <div className="brand">Revision Platform</div>
        </div>
        <Link className="btn primary" href="/login">Sign in →</Link>
      </header>

      <section className="hero" style={{gridTemplateColumns:"1fr"}}>
        <div className="hero-main" style={{padding:"38px"}}>
          <div className="eyebrow">One revision workspace</div>
          <h1 className="hero-title" style={{maxWidth:760}}>English now. Maths and GK next. One fast home for all three.</h1>
          <p className="hero-copy">The new platform keeps each subject logically isolated while giving you one modern, installable revision experience.</p>
          <div className="row" style={{marginTop:24}}>
            <Link className="btn primary" href="/english">Open English →</Link>
            <Link className="btn ghost" href="/login">Sign in</Link>
          </div>
        </div>
      </section>

      <section className="platform-grid">
        <Link className="platform-card active" href="/english">
          <div className="platform-letter">E</div>
          <h2>English</h2>
          <p className="muted">Daily, Starred, Difficult, My Saved, Phrasal, Hindu, Topic, Source and Demand practice.</p>
          <span className="pill">V2 Preview active</span>
        </Link>
        <div className="platform-card">
          <div className="platform-letter">M</div>
          <h2>Maths</h2>
          <p className="muted">Existing Maths app remains isolated until its migration begins.</p>
          <span className="pill">Coming next</span>
        </div>
        <div className="platform-card">
          <div className="platform-letter">G</div>
          <h2>GK</h2>
          <p className="muted">Existing GK app remains isolated until its migration begins.</p>
          <span className="pill">Coming next</span>
        </div>
      </section>
    </main>
  );
}

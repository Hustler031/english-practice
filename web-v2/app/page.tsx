"use client";

import Link from "next/link";
import { useAuthGuard } from "@/lib/use-auth";

export default function SubjectHome() {
  const ready = useAuthGuard();
  if (!ready) return <main className="subject-home"><div className="loading-copy">Checking session…</div></main>;
  return <main className="subject-home">
    <section className="subject-home-inner">
      <div className="subject-home-title"><strong>Revision</strong><span>Choose your study area</span></div>
      <div className="subject-stack">
        <Link href="/english" className="subject-choice active"><span className="subject-icon">E</span><span><b>English</b><small>Daily practice, revision and your saved learning</small></span><i>›</i></Link>
        <div className="subject-choice muted-choice"><span className="subject-icon">G</span><span><b>GK</b><small>Coming later</small></span><em>Not migrated</em></div>
        <div className="subject-choice muted-choice"><span className="subject-icon">M</span><span><b>Maths</b><small>Coming later</small></span><em>Not migrated</em></div>
      </div>
    </section>
  </main>;
}

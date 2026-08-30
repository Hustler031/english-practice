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
        <Link href="/gk" className="subject-choice active"><span className="subject-icon">G</span><span><b>GK</b><small>Daily revision, smart practice and rapid recall</small></span><i>›</i></Link>
        <Link href="/maths" className="subject-choice active"><span className="subject-icon">M</span><span><b>Maths</b><small>Daily revision, chapters, specialist training and mocks</small></span><i>›</i></Link>
      </div>
    </section>
  </main>;
}

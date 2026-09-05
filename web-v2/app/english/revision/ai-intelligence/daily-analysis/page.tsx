"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/learner-ui";
import { DAILY_ANALYSIS_CATEGORIES,type DailyAnalysisSummary } from "@/lib/daily-analysis";
import { learnerErrorMessage,rpc } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

export default function DailyAnalysisPage(){
 const ready=useAuthGuard();
 const [data,setData]=useState<DailyAnalysisSummary|null>(null);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");
 useEffect(()=>{if(!ready)return;let alive=true;rpc<DailyAnalysisSummary>("english_get_daily_analysis_summary").then(x=>alive&&setData(x)).catch((e:any)=>alive&&setError(learnerErrorMessage(e,"Could not load today’s analysis."))).finally(()=>alive&&setLoading(false));return()=>{alive=false}},[ready]);
 if(!ready)return null;
 return <main className="top-level-parity learner-rebuild-page learner-insights-page daily-analysis-page">
  <PageHeader back={<Link href="/english/revision/ai-intelligence" className="back-link">← Learning Insights</Link>} eyebrow="Today only" title="Daily Analysis" subtitle="Inspect why questions entered today’s Daily plan."/>
  <div className="daily-analysis-readonly-note">Read-only review · opening a question does not change attempts, mastery, or cooldown.</div>
  {error&&<div className="error-box">{error}</div>}
  {loading?<div className="loading-copy">Loading today’s analysis…</div>:<>
   <div className="daily-analysis-mini-summary"><span><b>{data?.attemptedToday||0}</b><small>attempted in Daily</small></span><span><b>{data?.wrongToday||0}</b><small>wrong today</small></span><span><b>{data?.relevantCount||0}</b><small>review items</small></span></div>
   <section className="daily-analysis-category-list" aria-label="Daily analysis categories">
    {DAILY_ANALYSIS_CATEGORIES.map(item=><Link key={item.key} className={`daily-analysis-category-row category-${item.key}`} href={`/english/revision/ai-intelligence/daily-analysis/questions?category=${encodeURIComponent(item.key)}`}>
      <span><b>{item.title}</b><small>{item.subtitle}</small></span><strong>{data?.categories?.[item.key]??0}</strong><i>›</i>
    </Link>)}
   </section>
  </>}
 </main>;
}

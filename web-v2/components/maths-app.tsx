"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { Suspense, useCallback, useEffect, useState } from "react";
import { useAuthGuard } from "@/lib/use-auth";
import {
  getMathsSession,
  mathsRpc,
  type MathsMetric,
  type MathsSession,
  rememberMathsSession,
  subscribeMathsFresh,
} from "@/lib/maths-rpc";
import { MathsLoading } from "@/components/maths-frame";
import { MathsDiagram } from "@/components/maths-diagram";

type Home = {
  ok: boolean;
  studyDay: number;
  config: {
    dailyTarget: number;
    newQuota: number;
    difficultRotationDays: number;
    practiceMoreSize: number;
    timezone: string;
  };
  daily: {
    target: number;
    done: number;
    remaining: number;
    completed: boolean;
    sessionId: string;
    composition?: unknown;
  };
  resume?: {
    sessionId: string;
    title: string;
    mode: string;
    currentIndex: number;
    target: number;
    completed?: boolean;
  } | null;
  overall: MathsMetric;
  counts: {
    new: number;
    starred: number;
    concepts: number;
    mocks: number;
    formulas: number;
    calculation: number;
  };
};

type ChaptersHub = {
  ok: boolean;
  groups: { key: string; label: string; metric: MathsMetric }[];
  chapters: { chapter: string; group: string; metric: MathsMetric }[];
};
type ChapterHub = {
  ok: boolean;
  chapter: string;
  topic?: string | null;
  metric: MathsMetric;
  topics: { name: string; metric: MathsMetric }[];
};
type Progress = {
  ok: boolean;
  overall: MathsMetric;
  advanced: MathsMetric;
  arithmetic: MathsMetric;
  misc: MathsMetric;
  chapters: { chapter: string; group: string; metric: MathsMetric }[];
};
type SpecialistHub = {
  ok: boolean;
  setId?: string;
  overall?: MathsMetric;
  metric?: MathsMetric;
  due?: number;
  chapters: {
    chapter: string;
    metric: MathsMetric;
    topics?: { name: string; metric: MathsMetric }[];
  }[];
};
type CalculationHub = {
  ok: boolean;
  total: number;
  memory: number;
  methods: number;
  drills: number;
  slow: number;
  wrong: number;
  skills: { skill: string; total: number; memory: number; methods: number; drills: number }[];
};
type OnDemand = {
  ok: boolean;
  calculation: number;
  mocks: number;
  formulas: number;
  concepts: number;
  generated: number;
  demandSets: {
    setId: string;
    name: string;
    description: string;
    status: string;
    count: number;
    specialist: boolean;
  }[];
};
type Library = {
  ok: boolean;
  counts: Record<string, number>;
  cluster?: string | null;
  items: {
    id: string;
    chapter: string;
    topic: string;
    prompt: string;
    answer: string;
    explanation: string;
    starred: boolean;
    difficult: boolean;
    note?: string | null;
  }[];
};
type DemandHub = {
  ok: boolean;
  sets: {
    setId: string;
    name: string;
    description: string;
    status: string;
    count: number;
    specialist: boolean;
  }[];
};
type StartFn = (name: string, args?: Record<string, unknown>) => Promise<void>;

const modes = ["all", "new", "weak", "hard", "starred", "difficult", "random"] as const;
const formulaModes = ["all", "new", "due", "weak", "starred", "difficult"] as const;
const pretty = (s: string) => s.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase());
const displayPct = (value: number) => Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1);
const attemptedPct = (value: number, metric: MathsMetric) => metric.attempted ? (value * 100) / metric.attempted : 0;
const actionLabel = (kind: string) => kind === "all" ? "Practice All" : kind === "difficult" ? "◆ Difficult" : pretty(kind);
function route(path: string, params?: Record<string, string | undefined | null>) {
  const q = new URLSearchParams();
  Object.entries(params ?? {}).forEach(([k, v]) => { if (v) q.set(k, v); });
  const s = q.toString();
  return s ? `${path}?${s}` : path;
}

function ErrorBox({ error }: { error: string }) {
  return error ? <div className="maths-error">{error}</div> : null;
}
function PageTitle({ kicker, title, sub, back }: { kicker?: string; title: string; sub?: string; back?: string }) {
  return <div className="m-title">
    {back && <Link className="m-back" href={back}>← {back === "/maths" ? "Home" : "Back"}</Link>}
    {kicker && <div className="m-kicker">{kicker}</div>}
    <h1>{title}</h1>
    {sub && <p>{sub}</p>}
  </div>;
}
function GlobalMetricStrip({ metric }: { metric: MathsMetric }) {
  return <div className="m-metric-strip" aria-label="Maths scope summary">
    <div className="coverage">Coverage {displayPct(metric.coverage)}%</div>
    <div className="wrong">✕ {metric.wrong} Wrong</div>
    <div className="difficult">◆ {metric.difficult}</div>
    <div className="starred">☆ {metric.starred}</div>
  </div>;
}
function OverallMetricStrip() {
  const { data } = useMathsRead<Home>("maths_get_home_snapshot");
  return data ? <GlobalMetricStrip metric={data.overall} /> : null;
}
function MetricStrip({ metric }: { metric: MathsMetric }) {
  return <div className="m-stat-grid">
    <div className="m-stat"><b>{metric.total}</b><small>Total</small></div>
    <div className="m-stat"><b>{metric.attempted}</b><small>Attempted</small></div>
    <div className="m-stat"><b>{metric.weak}</b><small>Weak</small></div>
    <div className="m-stat"><b>{metric.hard}</b><small>Hard</small></div>
  </div>;
}
function Row({ icon, title, sub, status, href, onClick }: { icon?: string; title: string; sub?: string; status?: string; href?: string; onClick?: () => void }) {
  const body = <>
    {icon && <span className="m-row-icon">{icon}</span>}
    <span className="m-row-copy"><b>{title}</b>{sub && <small>{sub}</small>}</span>
    {status && <span className="m-row-status">{status}</span>}
    <i>›</i>
  </>;
  return href
    ? <Link className={`m-row ${icon ? "" : "no-icon"}`} href={href}>{body}</Link>
    : <button className={`m-row ${icon ? "" : "no-icon"}`} type="button" onClick={onClick}>{body}</button>;
}
function QuickCard({ icon, title, sub, href }: { icon: string; title: string; sub: string; href: string }) {
  return <Link className="m-quick-card" href={href}>
    <span className="m-quick-icon">{icon}</span>
    <span className="m-quick-copy"><b>{title}</b><small>{sub}</small></span>
    <i>›</i>
  </Link>;
}
function useMathsRead<T>(name: string, args?: Record<string, unknown>) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState("");
  const key = JSON.stringify(args ?? {});
  useEffect(() => {
    let alive = true;
    let request = 0;
    const accept = (x: T) => { if (alive) { setData(x); setError(""); } };
    const unsub = subscribeMathsFresh<T>(name, args, accept);
    const load = () => { const current = ++request; void mathsRpc<T>(name, args).then(x => { if (current === request) accept(x); }).catch((e: unknown) => {
      if (alive && current === request) setError(e instanceof Error ? e.message : String(e));
    });
    };
    const ownerChanged = () => { if (alive) { setData(null); setError(""); load(); } };
    window.addEventListener("maths:v2-owner-change", ownerChanged);
    load();
    return () => { alive = false; unsub(); window.removeEventListener("maths:v2-owner-change", ownerChanged); };
  }, [name, key]);
  return { data, error };
}
function StartButtons({ start, rpc, baseArgs, modes: kindModes = modes }: { start: StartFn; rpc: string; baseArgs?: Record<string, unknown>; modes?: readonly string[] }) {
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  async function go(kind: string) {
    setBusy(kind); setError("");
    try { await start(rpc, { ...(baseArgs ?? {}), p_kind: kind, p_count: 20 }); }
    catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(""); }
  }
  return <div className="m-actions-shell">
    <div className="m-action-grid">
      {kindModes.map(k => <button
        className={`m-action ${k === "starred" ? "starred" : k === "difficult" ? "difficult" : ""}`}
        key={k}
        type="button"
        disabled={!!busy}
        onClick={() => void go(k)}
      >{busy === k ? "Starting…" : actionLabel(k)}</button>)}
    </div>
    {error && <div className="maths-error compact">{error}</div>}
  </div>;
}

function HomePage({ start }: { start: StartFn }) {
  const { data, error } = useMathsRead<Home>("maths_get_home_snapshot");
  if (!data && !error) return <MathsLoading text="Loading Maths home…" />;
  if (!data) return <ErrorBox error={error} />;
  const d = data.daily;
  const pct = d.target ? Math.min(100, Math.round((d.done * 100) / d.target)) : 0;
  const pendingParts = (data.resume?.title ?? "Practice").split("·").map(x => x.trim()).filter(Boolean);
  const pendingTitle = pendingParts[0] || "Practice";
  const pendingSub = pendingParts.slice(1).join(" · ") || pretty(data.resume?.mode ?? "Practice");
  return <div className="m-home">
    <ErrorBox error={error} />
    <section className={`m-hero ${d.completed ? "complete" : ""}`}>
      <h1>{d.completed ? `Day ${data.studyDay} · Complete` : `Day ${data.studyDay} · Mixed Revision`}</h1>
      <p className="m-hero-desc">{d.completed ? "Today’s mixed Maths revision is complete." : "Mixed adaptive revision · whole question bank, Calculation excluded."}</p>
      <div className="m-goal"><span>Today’s Goal</span><b>{d.done} / {d.target}</b></div>
      <div className="m-daily-track"><i style={{ width: `${pct}%` }} /></div>
      <div className="m-hero-note">{data.config.newQuota} New guaranteed · Difficult every {data.config.difficultRotationDays} days · Weak, Hard and due revision</div>
      {d.completed
        ? <button className="m-hero-cta" type="button" onClick={() => void start("maths_start_practice_more", { p_count: data.config.practiceMoreSize })}>Practice More</button>
        : <button className="m-hero-cta" type="button" onClick={() => void start("maths_start_daily")}>{d.done > 0 || d.sessionId ? `Continue Day ${data.studyDay} · ${d.remaining} left` : `Start Day ${data.studyDay} · ${d.remaining} left`}</button>}
    </section>

    {data.resume && !data.resume.completed && <Link className="m-pending" href={route("/maths/session", { id: data.resume.sessionId })}>
      <span><b>Pending · {pendingTitle}</b><small>{pendingSub}</small></span><i>›</i>
    </Link>}

    <h2 className="m-section-title">Quick Start</h2>
    <div className="m-quick-list">
      <QuickCard icon="✨" title="New Practice" sub={`${data.counts.new} unseen · recent additions by chapter`} href="/maths/new" />
      <QuickCard icon="⭐" title="Starred Revision" sub={`${data.counts.starred} starred · ${data.overall.difficult} difficult`} href="/maths/starred" />
      <QuickCard icon="🧠" title="Concepts" sub={`${data.counts.concepts} saved questions · concept review`} href="/maths/concepts" />
    </div>
  </div>;
}

function ChaptersPage({ group, start }: { group?: string; start: StartFn }) {
  const { data, error } = useMathsRead<ChaptersHub>("maths_get_chapters_hub");
  const { data: home } = useMathsRead<Home>("maths_get_home_snapshot");
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const activeGroup = group ? data.groups.find(g => g.key === group) : undefined;
  if (group && activeGroup) {
    const groupChapters = data.chapters.filter(c => c.group === group);
    return <>
      {home && <GlobalMetricStrip metric={activeGroup.metric} />}
      <PageTitle kicker={activeGroup.label} title={`${activeGroup.metric.total} cards`} sub={`${groupChapters.length} ${groupChapters.length === 1 ? "chapter" : "chapters"}`} back="/maths/chapters" />
      <StartButtons start={start} rpc="maths_start_focused_practice" baseArgs={{ p_scope: "group", p_group: group }} />
      <h2 className="m-section-title">Chapters</h2>
      <div className="m-list">
        {groupChapters.map(c => <Row
          key={c.chapter}
          title={c.chapter}
          sub={`${c.metric.total} cards`}
          status="Open"
          href={route("/maths/chapters", { chapter: c.chapter, group })}
        />)}
        {!groupChapters.length && <div className="m-empty">No active academic chapters in this group.</div>}
      </div>
    </>;
  }
  return <>
    {home && <GlobalMetricStrip metric={home.overall} />}
    <PageTitle kicker="Practice" title="Practice Hub" sub="Choose a focused Maths bank." />
    <ErrorBox error={error} />
    <div className="m-group-grid">
      {data.groups.map(g => {
        const count = data.chapters.filter(c => c.group === g.key).length;
        return <Link className="m-group-card" key={g.key} href={route("/maths/chapters", { group: g.key })}>
          <span className="m-kicker">{g.label}</span>
          <span><b>{g.key === "misc" ? `${count} banks` : `${count} ${count === 1 ? "chapter" : "chapters"}`}</b>{g.key === "misc" && <small>Recall material</small>}</span>
        </Link>;
      })}
      <Link className="m-group-card" href="/maths/mocks">
        <span className="m-kicker">Mocks</span>
        <span><b>{home?.counts.mocks ?? 0} questions</b><small>Saved Mock Questions</small></span>
      </Link>
    </div>
  </>;
}

function ChapterPage({ chapter, topic, group, start }: { chapter: string; topic?: string; group?: string; start: StartFn }) {
  const { data, error } = useMathsRead<ChapterHub>("maths_get_chapter", { p_chapter: chapter, p_topic: topic ?? null });
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const scope = topic ? "topic" : "chapter";
  const attempted = data.metric.attempted;
  const back = topic
    ? route("/maths/chapters", { chapter, group })
    : group ? route("/maths/chapters", { group }) : "/maths/chapters";
  return <>
    <GlobalMetricStrip metric={data.metric} />
    <PageTitle kicker={topic ? chapter : "Chapter"} title={topic || chapter} sub={topic ? `${data.metric.total} cards` : `${data.metric.total} cards · ${attempted} attempted`} back={back} />
    <div className="m-progress-track"><i style={{ width: `${data.metric.coverage}%` }} /></div>
    <StartButtons start={start} rpc="maths_start_focused_practice" baseArgs={{ p_scope: scope, p_chapter: chapter, p_topic: topic ?? null }} />
    {!topic && <>
      <h2 className="m-section-title">Major Topics · Study banks</h2>
      <div className="m-list">
        {data.topics.map(t => <Row
          key={t.name}
          title={t.name}
          sub={`${t.metric.total} cards`}
          href={route("/maths/chapters", { chapter, topic: t.name, group })}
        />)}
      </div>
    </>}
  </>;
}

function ProgressPage() {
  const { data, error } = useMathsRead<Progress>("maths_get_progress");
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const o = data.overall;
  return <>
    <GlobalMetricStrip metric={o} />
    <PageTitle kicker="Overview" title="Progress" />
    <ErrorBox error={error} />
    <div className="m-overview-grid">
      <div><b>{o.total}</b><span>Total Q</span></div>
      <div><b>{o.attempted}</b><span>Encountered</span></div>
      <div className="wrong"><b>✕ {o.wrong}</b><span>Wrong</span><small>{attemptedPct(o.wrong, o).toFixed(1)}%</small></div>
      <div className="difficult"><b>◆ {o.difficult}</b><span>Difficult</span><small>{attemptedPct(o.difficult, o).toFixed(1)}%</small></div>
      <div className="starred"><b>☆ {o.starred}</b><span>Starred</span><small>{attemptedPct(o.starred, o).toFixed(1)}%</small></div>
    </div>
    <div className="m-progress-track"><i style={{ width: `${o.coverage}%` }} /></div>
    <div className="m-progress-summary"><b>{o.attempted} / {o.total}</b> encountered · {o.unseen} left</div>
    <h2 className="m-section-title">By Chapter</h2>
    <div className="m-list">
      {data.chapters.map(c => <Link className="m-progress-card" key={c.chapter} href={route("/maths/chapters", { chapter: c.chapter, group: c.group })}>
        <div className="m-progress-card-head"><b>{c.chapter}</b><span>{c.metric.total} Q</span></div>
        <div className="m-progress-track"><i style={{ width: `${c.metric.coverage}%` }} /></div>
        <div className="m-diagnostics"><span className="wrong">✕ Wrong <b>{c.metric.wrong}</b></span> · <span className="difficult">◆ Difficult <b>{c.metric.difficult}</b></span> · <span className="starred">☆ Starred <b>{c.metric.starred}</b></span> · Left <b>{c.metric.unseen}</b></div>
      </Link>)}
    </div>
  </>;
}

function MocksPage({ chapter, start }: { chapter?: string; start: StartFn }) {
  const { data, error } = useMathsRead<SpecialistHub>("maths_get_mocks_hub");
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const selected = chapter ? data.chapters.find(x => x.chapter === chapter) : undefined;
  const metric = selected?.metric ?? data.overall;
  return <>
    {metric && <GlobalMetricStrip metric={metric} />}
    <PageTitle kicker="Mocks" title={chapter ? chapter : "Mock Questions"} sub={chapter ? `${selected?.metric.total ?? 0} saved questions` : `${data.overall?.total ?? 0} saved questions`} back={chapter ? "/maths/mocks" : "/maths/chapters"} />
    <ErrorBox error={error} />
    <StartButtons start={start} rpc="maths_start_mock_practice" baseArgs={{ p_chapter: chapter ?? null }} modes={["all", "new", "weak", "starred", "difficult", "random"]} />
    {!chapter && <>
      <h2 className="m-section-title">By Chapter</h2>
      <div className="m-list">{data.chapters.map(c => <Row key={c.chapter} title={c.chapter} sub={`${c.metric.total} questions · ${c.metric.weak} weak`} status={`${c.metric.coverage.toFixed(0)}%`} href={route("/maths/mocks", { chapter: c.chapter })} />)}</div>
    </>}
  </>;
}

function FormulaPage({ chapter, start }: { chapter?: string; start: StartFn }) {
  const { data, error } = useMathsRead<SpecialistHub>("maths_get_formula_hub");
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const selected = chapter ? data.chapters.find(x => x.chapter === chapter) : undefined;
  const metric = selected?.metric ?? data.overall;
  return <>
    {metric && <GlobalMetricStrip metric={metric} />}
    <PageTitle kicker="Revision" title={chapter ? chapter : "Formula Revision"} sub={chapter ? `${selected?.metric.total ?? 0} formula cards` : `${data.overall?.total ?? 0} intentional formula cards · ${data.due ?? 0} due`} back={chapter ? "/maths/formulas" : "/maths/ondemand"} />
    <ErrorBox error={error} />
    <StartButtons start={start} rpc="maths_start_formula_revision" baseArgs={{ p_chapter: chapter ?? null }} modes={formulaModes} />
    {!chapter && <>
      <h2 className="m-section-title">By Chapter</h2>
      <div className="m-list">{data.chapters.map(c => <Row key={c.chapter} title={c.chapter} sub={`${c.metric.total} cards · ${c.metric.weak} weak`} status={`${c.metric.coverage.toFixed(0)}%`} href={route("/maths/formulas", { chapter: c.chapter })} />)}</div>
    </>}
  </>;
}

function CalculationPage({ start }: { start: StartFn }) {
  const { data, error } = useMathsRead<CalculationHub>("maths_get_calculation_hub");
  const [busy, setBusy] = useState("");
  const [localError, setLocalError] = useState("");
  async function go(mode: string, args: Record<string, unknown> = {}) {
    setBusy(mode); setLocalError("");
    try { await start("maths_start_calculation", { p_mode: mode, p_count: 20, ...args }); }
    catch (e: unknown) { setLocalError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(""); }
  }
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  return <>
    <PageTitle kicker="Training" title="Calculation Training" sub="MEMORY / METHOD / DRILL · MEMORY recall stays Reveal-based." back="/maths/ondemand" />
    <ErrorBox error={error || localError} />
    <div className="m-stat-grid">
      <div className="m-stat"><b>{data.memory}</b><small>Memory</small></div>
      <div className="m-stat"><b>{data.methods}</b><small>Methods</small></div>
      <div className="m-stat"><b>{data.drills}</b><small>Drills</small></div>
      <div className="m-stat"><b>{data.slow}</b><small>Slow ≥8s</small></div>
    </div>
    <div className="m-actions-shell">
      <div className="m-action-grid four">
        <button className="m-action primary" type="button" disabled={!!busy} onClick={() => void go("recall")}>Recall</button>
        <button className="m-action" type="button" disabled={!!busy} onClick={() => void go("weak")}>Weak & Slow</button>
        <button className="m-action" type="button" disabled={!!busy} onClick={() => void go("all")}>All</button>
        <button className="m-action" type="button" disabled={!!busy} onClick={() => void go("mixed")}>Mixed Practice</button>
      </div>
    </div>
    <h2 className="m-section-title">Skills</h2>
    <div className="m-list">{data.skills.map(s => <Row key={s.skill} title={s.skill} sub={`${s.memory} memory · ${s.methods} methods · ${s.drills} drills`} status={`${s.total}`} onClick={() => void go("mixed", { p_skill: s.skill })} />)}</div>
  </>;
}

function ConceptsPage({ chapter, topic, start }: { chapter?: string; topic?: string; start: StartFn }) {
  const { data, error } = useMathsRead<SpecialistHub>("maths_get_concepts_hub");
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const cr = chapter ? data.chapters.find(x => x.chapter === chapter) : undefined;
  const tr = topic ? cr?.topics?.find(x => x.name === topic) : undefined;
  const metric = tr?.metric ?? cr?.metric ?? data.metric;
  const back = topic ? route("/maths/concepts", { chapter }) : chapter ? "/maths/concepts" : "/maths";
  return <>
    {metric && <GlobalMetricStrip metric={metric} />}
    <PageTitle kicker="Saved" title={topic || chapter || "🧠 Concepts"} sub={topic ? `${metric?.total ?? 0} saved questions` : chapter ? `${metric?.total ?? 0} saved questions · concept review` : "Questions you deliberately saved for concept revision."} back={back} />
    <ErrorBox error={error} />
    <StartButtons start={start} rpc="maths_start_concepts" baseArgs={{ p_chapter: chapter ?? null, p_topic: topic ?? null }} modes={["all", "new", "weak", "hard", "difficult", "random"]} />
    {!chapter && <>
      <h2 className="m-section-title">By Chapter</h2>
      <div className="m-list">{data.chapters.map(c => <Row key={c.chapter} title={c.chapter} sub={`${c.metric.total} saved questions`} status={`${c.metric.total} Q`} href={route("/maths/concepts", { chapter: c.chapter })} />)}</div>
    </>}
    {cr && !topic && <>
      <h2 className="m-section-title">Major Topics</h2>
      <div className="m-list">{(cr.topics ?? []).map(t => <Row key={t.name} title={t.name} sub={`${t.metric.total} saved questions`} status={`${t.metric.total} Q`} href={route("/maths/concepts", { chapter, topic: t.name })} />)}</div>
    </>}
  </>;
}

function DemandPage({ start }: { start: StartFn }) {
  const { data, error } = useMathsRead<DemandHub>("maths_get_demand_hub");
  const [chosen, setChosen] = useState<string | null>(null);
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  return <>
    <OverallMetricStrip />
    <PageTitle kicker="Saved" title="Demand Sets" sub="Explicit ordered saved sets. Specialist sets keep their own primary hubs." back="/maths/ondemand" />
    <ErrorBox error={error} />
    <div className="m-list">{data.sets.map(s => <div className="m-card" key={s.setId}>
      <div className="m-card-row"><span><b>{s.name}</b><small>{s.count} questions</small></span>{s.specialist
        ? <Link className="m-soft-btn" href={s.setId === "MOCK_QUESTIONS" ? "/maths/mocks" : s.setId === "MOCK_FORMULA_REVISION" ? "/maths/formulas" : "/maths/calculation"}>Open</Link>
        : <button className="m-soft-btn" type="button" onClick={() => setChosen(chosen === s.setId ? null : s.setId)}>Practice</button>}
      </div>
      {s.description && <p>{s.description}</p>}
      {chosen === s.setId && <StartButtons start={start} rpc="maths_start_demand_set" baseArgs={{ p_set_id: s.setId }} />}
    </div>)}</div>
  </>;
}

function OnDemandPage({ start }: { start: StartFn }) {
  const { data, error } = useMathsRead<OnDemand>("maths_get_ondemand_hub");
  const { data: chapters } = useMathsRead<ChaptersHub>("maths_get_chapters_hub");
  const [selectedChapter, setSelectedChapter] = useState("");
  const [busy, setBusy] = useState(false);
  const [localError, setLocalError] = useState("");
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  const savedSets = data.demandSets.filter(s => s.setId !== "MOCK_QUESTIONS");
  async function quickStart() {
    setBusy(true); setLocalError("");
    try {
      await start("maths_start_focused_practice", {
        p_scope: selectedChapter ? "chapter" : "all",
        p_chapter: selectedChapter || null,
        p_kind: "random",
        p_count: 20,
      });
    } catch (e: unknown) {
      setLocalError(e instanceof Error ? e.message : String(e));
    } finally { setBusy(false); }
  }
  return <>
    <OverallMetricStrip />
    <PageTitle kicker="Custom" title="On Demand" sub="Calculation Training and preserved custom sets." />
    <ErrorBox error={error || localError} />
    <section className="m-card m-quick-practice">
      <h2>Quick chapter practice</h2>
      <select value={selectedChapter} onChange={e => setSelectedChapter(e.target.value)} aria-label="Quick chapter practice chapter">
        <option value="">All chapters</option>
        {(chapters?.chapters ?? []).map(c => <option key={c.chapter} value={c.chapter}>{c.chapter}</option>)}
      </select>
      <button className="m-wide-primary" type="button" disabled={busy} onClick={() => void quickStart()}>{busy ? "Starting…" : "Start 20 random"}</button>
    </section>

    <h2 className="m-section-title">Saved sets</h2>
    <div className="m-list">{savedSets.map(s => <div className="m-card m-card-row" key={s.setId}>
      <span><b>{s.name}</b><small>{s.count} questions</small></span>
      <Link className="m-soft-btn" href={s.setId === "CALC_TRAINING" ? "/maths/calculation" : s.setId === "MOCK_FORMULA_REVISION" ? "/maths/formulas" : "/maths/demand"}>{s.specialist ? "Open" : "Practice"}</Link>
    </div>)}</div>

    <h2 className="m-section-title secondary">More Maths</h2>
    <div className="m-list">
      <Row title="Mock Questions" sub="Dedicated mock bank and chapter practice" status={`${data.mocks}`} href="/maths/mocks" />
      <Row title="Concepts" sub="Saved concept-question hierarchy" status={`${data.concepts}`} href="/maths/concepts" />
      <Row title="Demand Sets" sub="All preserved custom collections" status={`${data.demandSets.length}`} href="/maths/demand" />
      {data.generated > 0 && <Row title="Generated Practice" sub="Explicit generated bank" status={`${data.generated}`} href="/maths/generated" />}
    </div>
  </>;
}

const libraryConfig = [
  ["formulas", "Σ", "Formula"],
  ["methods", "⚡", "Methods"],
  ["fractions", "⅞", "Fractions"],
  ["triplets", "△", "Triplets"],
  ["marked", "⭐", "Marked"],
  ["notes", "📝", "Notes"],
  ["recent", "＋", "Recent"],
] as const;
function LibraryPage({ cluster }: { cluster?: string }) {
  const { data, error } = useMathsRead<Library>("maths_get_library_hub", { p_cluster: cluster ?? null });
  if (!data && !error) return <MathsLoading />;
  if (!data) return <ErrorBox error={error} />;
  if (!cluster) return <>
    <OverallMetricStrip />
    <PageTitle kicker="Reference" title="Library" sub="Formula, methods, notes and saved material." />
    <ErrorBox error={error} />
    <div className="m-library-grid">{libraryConfig.map(([key, icon, label]) => <Link className="m-library-card" key={key} href={route("/maths/library", { cluster: key })}>
      <span className="m-kicker">{icon} {label}</span>
      <b>{data.counts[key] ?? 0} cards</b>
    </Link>)}</div>
  </>;
  const label = libraryConfig.find(x => x[0] === cluster)?.[2] ?? pretty(cluster);
  return <>
    <PageTitle kicker="Library" title={label} sub={`${data.items.length} cards`} back="/maths/library" />
    <ErrorBox error={error} />
    <div className="m-list">{data.items.length ? data.items.map(x => <article className="m-card m-library-item" key={x.id}>
      <span className="m-kicker">{x.chapter}{x.topic ? ` · ${x.topic}` : ""} · {x.id}</span>
      <h3>{x.prompt}</h3>
      {x.answer && <p className="answer">{x.answer}</p>}
      {x.explanation && <p>{x.explanation}</p>}
      {x.note && <p className="m-memory">Note: {x.note}</p>}
    </article>) : <div className="m-empty">No items in this Library section.</div>}</div>
  </>;
}

function FocusPage({ kind, start }: { kind: "new" | "starred" | "generated"; start: StartFn }) {
  const { data, error } = useMathsRead<Home>("maths_get_home_snapshot");
  const title = kind === "new" ? "New Practice" : kind === "starred" ? "⭐ Starred Revision" : "Generated Practice";
  const scope = kind === "new" ? "new_practice" : kind === "starred" ? "starred" : "generated";
  return <>
    {data && <GlobalMetricStrip metric={data.overall} />}
    <PageTitle kicker={kind === "new" ? "Fresh material" : kind === "starred" ? "Revision" : "Other"} title={title} sub={kind === "new" ? `${data?.counts.new ?? 0} unseen across Maths` : kind === "starred" ? "Focused revision of questions you saved across every quiz." : "Explicit generated bank, isolated from normal Daily."} back="/maths" />
    <ErrorBox error={error} />
    <StartButtons start={start} rpc="maths_start_focused_practice" baseArgs={{ p_scope: scope }} modes={kind === "new" ? ["new", "random"] : modes} />
  </>;
}

function returnRoute(mode: string) {
  const m = mode.toLowerCase();
  if (m.includes("mock")) return "/maths/mocks";
  if (m.includes("formula")) return "/maths/formulas";
  if (m.includes("calculation")) return "/maths/calculation";
  if (m.includes("concept")) return "/maths/concepts";
  if (m.includes("demand")) return "/maths/demand";
  return "/maths";
}

function QuizPage({ sessionId }: { sessionId: string }) {
  const router = useRouter();
  const [sessionState, setSessionState] = useState<MathsSession | null>(null);
  const [error, setError] = useState("");
  const [pause, setPause] = useState(false);
  const [busy, setBusy] = useState(false);
  const [startedAt, setStartedAt] = useState(Date.now());
  const load = useCallback(() => getMathsSession(sessionId).then(s => {
    setSessionState(s); setError(""); setStartedAt(Date.now());
  }).catch((e: unknown) => setError(e instanceof Error ? e.message : String(e))), [sessionId]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!sessionState) return;
    history.pushState({ ...history.state, mathsQuizGuard: true }, "", location.href);
    const onBack = () => { history.pushState({ ...history.state, mathsQuizGuard: true }, "", location.href); setPause(true); };
    window.addEventListener("popstate", onBack);
    return () => window.removeEventListener("popstate", onBack);
  }, [sessionState?.sessionId]);
  if (!sessionState && !error) return <MathsLoading text="Restoring exact Maths session…" />;
  if (!sessionState) return <ErrorBox error={error} />;
  const session = sessionState;
  const index = Math.max(0, Math.min(session.currentIndex, Math.max(0, session.questions.length - 1)));
  const q = session.questions[index];
  if (!q) return <div className="m-empty">This session has no renderable questions.</div>;
  const attempt = session.attempts?.[q.questionId];
  const answered = !!attempt;
  const selected = attempt?.selectedOption ?? "";
  const pct = session.target ? Math.round(((index + 1) * 100) / session.target) : 0;
  const correct = String(q.correctOption || "").toUpperCase();
  async function answer(option?: string) {
    if (answered || busy) return;
    setBusy(true); setError("");
    const elapsed = Math.max(0, (Date.now() - startedAt) / 1000);
    try {
      const r = await mathsRpc<{ result: string; selectedOption?: string; attemptId?: string }>("maths_submit_answer", {
        p_session_id: session.sessionId,
        p_question_id: q.questionId,
        p_selected_option: option ?? null,
        p_response_sec: Number(elapsed.toFixed(1)),
        p_client_attempt_key: `m-${session.sessionId}-${q.questionId}`,
      });
      const next: MathsSession = {
        ...session,
        attempts: {
          ...(session.attempts ?? {}),
          [q.questionId]: { result: r.result, selectedOption: r.selectedOption ?? option ?? "", responseSec: elapsed, attemptId: r.attemptId },
        },
      };
      setSessionState(next); rememberMathsSession(next);
    } catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }
  async function flag(name: "starred" | "difficult" | "concept") {
    const rpcName = name === "starred" ? "maths_set_starred" : name === "difficult" ? "maths_set_difficult" : "maths_set_concept";
    const field = name === "concept" ? "inConcept" : name;
    const value = !Boolean(q[field]);
    try {
      await mathsRpc(rpcName, { p_question_id: q.questionId, p_value: value });
      const next: MathsSession = { ...session, questions: session.questions.map(x => x.questionId === q.questionId ? { ...x, [field]: value } : x) };
      setSessionState(next); rememberMathsSession(next);
    } catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); }
  }
  async function move(nextIndex: number) {
    const ni = Math.max(0, Math.min(nextIndex, session.questions.length - 1));
    const next: MathsSession = { ...session, currentIndex: ni };
    setSessionState(next); rememberMathsSession(next); setStartedAt(Date.now());
    try { await mathsRpc("maths_save_session_position", { p_session_id: session.sessionId, p_index: ni }); }
    catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); }
  }
  async function advance() {
    if (!answered) { setError(q.answerMode === "MCQ" ? "Answer this question first." : "Reveal the answer first."); return; }
    await move(index + 1);
  }
  async function finish() {
    if (!answered) { setError(q.answerMode === "MCQ" ? "Answer this question first." : "Reveal the answer first."); return; }
    setBusy(true);
    try { await mathsRpc("maths_finish_session", { p_session_id: session.sessionId }); router.push(returnRoute(session.mode)); }
    catch (e: unknown) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }
  async function pauseBack() { await move(index); router.push(returnRoute(session.mode)); }
  return <div className="m-quiz-shell">
    <ErrorBox error={error} />
    <div className="m-quiz-head"><div className="m-quiz-head-top"><strong>{session.title}</strong><span>{index + 1} / {session.target}</span></div><div className="m-quiz-progress"><i style={{ width: `${pct}%` }} /></div></div>
    <article className="m-question-card">
      <div className="m-meta"><span>{q.chapter || "Maths"}</span>{q.majorTopic && <span>{q.majorTopic}</span>}<span>{q.questionId}</span><span>{q.answerMode}</span></div>
      <div className="m-question">{q.prompt}</div>
      {q.diagram && <MathsDiagram diagram={q.diagram} />}
      {q.answerMode === "MCQ" ? <div className="m-options">{q.options.map(o => {
        const isSelected = selected === o.key;
        const stateClass = answered ? (o.key === correct ? "correct" : isSelected ? "wrong" : "") : isSelected ? "selected" : "";
        return <button className={`m-option ${stateClass}`} type="button" key={o.key} disabled={answered || busy} onClick={() => void answer(o.key)}><b>{o.key}</b><span>{o.text}</span></button>;
      })}</div> : !answered ? <div className="m-reveal"><button className="m-btn primary" type="button" disabled={busy} onClick={() => void answer()}>Reveal Answer</button></div> : null}
      {answered && q.answerMode === "MCQ" && <div className={`m-feedback ${attempt?.result === "correct" ? "good" : "bad"}`}>{attempt?.result === "correct" ? "Correct" : `Incorrect${correct ? ` · Correct option ${correct}` : ""}`}</div>}
      {answered && <><div className="m-answer-box"><b>Answer</b><p>{q.answer || (correct ? `Option ${correct}` : "Seen")}</p>{q.memoryCue && <div className="m-memory">Memory cue: {q.memoryCue}</div>}</div>{q.explanation && <div className="m-explanation"><b>Explanation</b><p>{q.explanation}</p></div>}</>}
    </article>
    <div className="m-quiz-tools">
      <button className={`m-tool ${q.starred ? "active" : ""}`} type="button" onClick={() => void flag("starred")}>☆ Starred</button>
      <button className={`m-tool ${q.difficult ? "active" : ""}`} type="button" onClick={() => void flag("difficult")}>◆ Difficult</button>
      <button className={`m-tool ${q.inConcept ? "active" : ""}`} type="button" onClick={() => void flag("concept")}>＋ Concept</button>
      <button className="m-tool" type="button" onClick={() => setPause(true)}>Ⅱ Pause</button>
    </div>
    <div className="m-nav-dock">
      <button className="m-btn" type="button" disabled={index === 0} onClick={() => void move(index - 1)}>‹ Previous</button>
      <select className="m-jump" value={index} onChange={e => void move(Number(e.target.value))} aria-label="Jump to question">{session.questions.map((_, i) => <option key={i} value={i}>{i + 1}/{session.target}</option>)}</select>
      {index === session.questions.length - 1 ? <button className="m-btn primary" type="button" disabled={busy} onClick={() => void finish()}>Finish</button> : <button className="m-btn primary" type="button" disabled={busy} onClick={() => void advance()}>Next ›</button>}
    </div>
    {pause && <div className="m-pause-backdrop" role="dialog" aria-modal="true"><section className="m-pause-sheet"><h2>Pause Maths practice?</h2><p>Your server session keeps the frozen question order, option order, answers and current position. Local Safe keeps the preview on this device.</p><button className="m-btn primary" type="button" onClick={() => void pauseBack()}>Save & Back</button><button className="m-btn ghost" type="button" onClick={() => setPause(false)}>Continue Quiz</button></section></div>}
  </div>;
}

function ResumeRedirect() {
  const router = useRouter();
  const { data, error } = useMathsRead<Home>("maths_get_home_snapshot");
  useEffect(() => {
    if (data?.resume?.sessionId) router.replace(route("/maths/session", { id: data.resume.sessionId }));
    else if (data) router.replace("/maths");
  }, [data, router]);
  return error ? <ErrorBox error={error} /> : <MathsLoading text="Finding resumable Maths session…" />;
}

function MathsAppInner() {
  const ready = useAuthGuard();
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const section = pathname.split("/").filter(Boolean)[1] ?? "";
  const chapter = search.get("chapter") || undefined;
  const topic = search.get("topic") || undefined;
  const group = search.get("group") || undefined;
  const cluster = search.get("cluster") || undefined;
  const sessionId = search.get("id") || undefined;
  const start = useCallback<StartFn>(async (name, args) => {
    const s = await mathsRpc<MathsSession>(name, args);
    if (!s?.ok) {
      if (s?.dailyComplete && s.sessionId) { router.push(route("/maths/session", { id: s.sessionId })); return; }
      throw new Error(s?.message || "No eligible Maths questions found.");
    }
    if (!s.sessionId) throw new Error("Session did not return an ID.");
    rememberMathsSession(s);
    router.push(route("/maths/session", { id: s.sessionId }));
  }, [router]);
  if (!ready) return <MathsLoading text="Checking session…" />;
  if (!section) return <HomePage start={start} />;
  if (section === "chapters") return chapter ? <ChapterPage chapter={chapter} topic={topic} group={group} start={start} /> : <ChaptersPage group={group} start={start} />;
  if (section === "library") return <LibraryPage cluster={cluster} />;
  if (section === "ondemand") return <OnDemandPage start={start} />;
  if (section === "progress") return <ProgressPage />;
  if (section === "mocks") return <MocksPage chapter={chapter} start={start} />;
  if (section === "formulas") return <FormulaPage chapter={chapter} start={start} />;
  if (section === "calculation") return <CalculationPage start={start} />;
  if (section === "concepts") return <ConceptsPage chapter={chapter} topic={topic} start={start} />;
  if (section === "demand") return <DemandPage start={start} />;
  if (section === "new") return <FocusPage kind="new" start={start} />;
  if (section === "starred") return <FocusPage kind="starred" start={start} />;
  if (section === "generated") return <FocusPage kind="generated" start={start} />;
  if (section === "session" && sessionId) return <QuizPage sessionId={sessionId} />;
  if (section === "resume") return <ResumeRedirect />;
  return <><PageTitle title="Maths" sub="This Maths route is not available." back="/maths" /><div className="m-empty">Unknown Maths route.</div></>;
}

export default function MathsApp() {
  return <Suspense fallback={<MathsLoading text="Opening Maths…" />}><MathsAppInner /></Suspense>;
}

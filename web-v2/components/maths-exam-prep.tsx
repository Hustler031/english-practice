"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { MathsLoading } from "@/components/maths-frame";
import { mathsCoachRpc, startMathsCoachSession } from "@/lib/maths-coach-rpc";
import { subscribeMathsFresh, type MathsSession } from "@/lib/maths-rpc";
import { supabaseBrowser } from "@/lib/supabase";
import { useAuthGuard } from "@/lib/use-auth";

type SprintPoint = { score: number; at: string };
type Readiness = {
  ok: boolean;
  studyDay: number;
  phase: number;
  phaseLabel: string;
  knowledge: { score: number; graded: number; correct: number; coldConfirmedFamilies: number };
  performance: { score: number; cleanCorrect: number; slowOrWrong: number };
  repair: { p0: number; due: number; persistentFamilies: number; diagnosisPending: number };
  leakage: Record<string, number>;
  biggestLeak?: string | null;
  sprint?: {
    count?: number;
    best?: number | null;
    median?: number | null;
    badDayFloor?: number | null;
    variance?: number | null;
    scores?: SprintPoint[];
  };
};
type CalculationSkill = {
  skill: string;
  total: number;
  memory: number;
  methods: number;
  drills: number;
  attempted?: number;
  accuracy?: number | null;
  medianSec?: number | null;
  baselineSec?: number | null;
  band?: string;
};
type CalculationHub = {
  ok: boolean;
  total: number;
  memory: number;
  methods: number;
  drills: number;
  slow: number;
  wrong: number;
  durationSec?: number;
  skills: CalculationSkill[];
  todayFocus?: string[];
};
type Weekly = {
  ok: boolean;
  current7d: Record<string, number>;
  previous7d: Record<string, number>;
  sprintMedian?: { current?: number | null; previous?: number | null };
  priorities: { reason: string; count: number; action: string }[];
};
type ActiveExamSession = {
  ok: boolean;
  active: boolean;
  sessionId?: string;
  title?: string;
  mode?: string;
  currentIndex?: number;
  target?: number;
  remainingSeconds?: number | null;
  expired?: boolean;
  review?: number[];
  visited?: number[];
};
type ExamData = {
  readiness: Readiness;
  calculation: CalculationHub;
  weekly: Weekly | null;
  active: ActiveExamSession;
};

type Reason = "CAL" | "APP" | "CON" | "FOR" | "SILLY" | "TIME";
const reasons: { id: Reason; label: string; action: string }[] = [
  { id: "CAL", label: "Calculation", action: "Speed + accuracy drill" },
  { id: "APP", label: "Approach", action: "Recognition + transfer" },
  { id: "CON", label: "Concept", action: "Concept repair" },
  { id: "FOR", label: "Formula", action: "Active recall + application" },
  { id: "SILLY", label: "Silly", action: "Trap-control repair" },
  { id: "TIME", label: "Time", action: "Timed method repair" },
];
const calcLabels = [
  "Fractions / %",
  "Squares / Roots",
  "Cubes / Roots",
  "Tables / ×",
  "Division / Cancel",
  "Approx / Simplify",
  "Number Speed",
  "Ratio / Proportion",
  "SSC Mixed",
];

function scoreText(value: number | null | undefined) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  const n = Number(value);
  return Number.isInteger(n) ? String(n) : n.toFixed(1);
}
function formatClock(value: number | null | undefined) {
  if (value == null || !Number.isFinite(Number(value))) return "";
  const seconds = Math.max(0, Math.ceil(Number(value)));
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}
function average(values: number[]) {
  if (!values.length) return null;
  return values.reduce((a, b) => a + b, 0) / values.length;
}
function sprintStats(readiness: Readiness) {
  const points = [...(readiness.sprint?.scores ?? [])]
    .filter(x => Number.isFinite(Number(x.score)))
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
  const last = points[0]?.score ?? null;
  const five = average(points.slice(0, 5).map(x => Number(x.score)));
  let streak = 0;
  for (const point of points) {
    if (Number(point.score) < 45) break;
    streak += 1;
  }
  return { last, five, streak };
}
function bandRank(band?: string) {
  if (band === "Automatic") return 4;
  if (band === "Strong") return 3;
  if (band === "Almost there") return 2;
  if (band === "Building evidence") return 1;
  return 0;
}
function coreBucket(skill: string) {
  const s = skill.toLowerCase();
  if (s.includes("fraction") || s.includes("percentage")) return "Fractions / %";
  if (s.includes("cube")) return "Cubes / Roots";
  if (s.includes("square") || s.includes("root")) return "Squares / Roots";
  if (s.includes("table") || s.includes("multiplication")) return "Tables / ×";
  if (s.includes("division") || s.includes("cancellation")) return "Division / Cancel";
  if (s.includes("approx") || s.includes("simplification") || s.includes("surd")) return "Approx / Simplify";
  if (s.includes("divisib") || s.includes("unit digit") || s.includes("remainder")) return "Number Speed";
  if (s.includes("ratio") || s.includes("proportion")) return "Ratio / Proportion";
  return "SSC Mixed";
}
function groupedCalculation(skills: CalculationSkill[]) {
  return calcLabels.map(label => {
    const rows = skills.filter(x => coreBucket(x.skill) === label);
    const total = rows.reduce((sum, x) => sum + Number(x.total || 0), 0);
    const attempted = rows.reduce((sum, x) => sum + Number(x.attempted || 0), 0);
    const weightedAccuracy = attempted
      ? rows.reduce((sum, x) => sum + Number(x.accuracy ?? 0) * Number(x.attempted || 0), 0) / attempted
      : null;
    const measured = rows.filter(x => Number(x.attempted || 0) > 0);
    const band = measured.length
      ? [...measured].sort((a, b) => bandRank(a.band) - bandRank(b.band))[0]?.band || "Needs work"
      : "Not measured";
    return { label, total, attempted, accuracy: weightedAccuracy, band };
  }).filter(x => x.total > 0);
}
function primaryPlan(data: ExamData) {
  const leak = String(data.readiness.biggestLeak || "").toUpperCase() as Reason;
  if (leak === "CAL") {
    const focus = data.calculation.todayFocus?.[0];
    return { tag: "CAL", title: focus ? `Speed · ${focus}` : "Calculation automaticity", sub: "10-minute focused drill before the next Sprint.", kind: "calculation" as const };
  }
  const meta = reasons.find(x => x.id === leak);
  if (meta) return { tag: meta.id, title: `${meta.label} is the biggest leak`, sub: meta.action, kind: "repair" as const };
  if (data.readiness.repair.due > 0) return { tag: "REPAIR", title: `${data.readiness.repair.due} repairs are due`, sub: "Clear the highest-value repair before adding more volume.", kind: "repair" as const };
  return { tag: "SPRINT", title: "Build fresh exam evidence", sub: "Run one balanced 25-question Sprint and diagnose the marks leakage.", kind: "sprint" as const };
}
async function fetchActiveExamSession(): Promise<ActiveExamSession> {
  const { data, error } = await supabaseBrowser().rpc("maths_get_active_exam_session");
  if (error) throw error;
  return (data ?? { ok: true, active: false }) as ActiveExamSession;
}

function MiniMetric({ label, value }: { label: string; value: string | number }) {
  return <div className="mex-mini-metric"><small>{label}</small><b>{value}</b></div>;
}

function InfoModal({ data, onClose }: { data: ExamData; onClose: () => void }) {
  const leakage = reasons.map(x => ({ ...x, count: Number(data.readiness.leakage?.[x.id] || 0) }));
  const calc = groupedCalculation(data.calculation.skills ?? []);
  return <div className="mex-modal-backdrop" role="presentation" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}>
    <section className="mex-modal" role="dialog" aria-modal="true" aria-label="Maths Exam Intelligence">
      <header><div><strong>Exam Intelligence</strong><span>Detailed evidence stays outside the main study flow.</span></div><button type="button" onClick={onClose} aria-label="Close">×</button></header>

      <div className="mex-info-grid">
        <MiniMetric label="Knowledge" value={`${scoreText(data.readiness.knowledge.score)}%`} />
        <MiniMetric label="Performance" value={`${scoreText(data.readiness.performance.score)}%`} />
        <MiniMetric label="Bad-day floor" value={scoreText(data.readiness.sprint?.badDayFloor)} />
        <MiniMetric label="Sprint variance" value={scoreText(data.readiness.sprint?.variance)} />
        <MiniMetric label="P0 repairs" value={data.readiness.repair.p0} />
        <MiniMetric label="Persistent families" value={data.readiness.repair.persistentFamilies} />
      </div>

      <section className="mex-info-section"><h3>Marks leakage</h3><div className="mex-simple-list">{leakage.map(x => <div key={x.id}><span><b>{x.id}</b> {x.label}</span><strong>{x.count}</strong></div>)}</div></section>

      <section className="mex-info-section"><h3>Calculation automaticity</h3><div className="mex-simple-list">{calc.map(x => <div key={x.label}><span><b>{x.label}</b><small>{x.attempted ? `${x.attempted} measured · ${x.accuracy?.toFixed(0)}%` : `${x.total} training cards`}</small></span><strong>{x.band}</strong></div>)}</div></section>

      <section className="mex-info-section"><h3>Weekly priorities</h3>{data.weekly?.priorities?.length ? <div className="mex-simple-list">{data.weekly.priorities.map((x, i) => <div key={`${x.reason}-${i}`}><span><b>{x.action}</b><small>{x.reason} · {x.count} events</small></span><strong>{i + 1}</strong></div>)}</div> : <p>More completed evidence is needed before a weekly ranking is reliable.</p>}</section>
    </section>
  </div>;
}

export default function MathsExamPreparation() {
  const ready = useAuthGuard();
  const router = useRouter();
  const [data, setData] = useState<ExamData | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [infoOpen, setInfoOpen] = useState(false);
  const [showMore, setShowMore] = useState(false);

  const load = useCallback(async () => {
    const [readiness, calculation, weekly, active] = await Promise.all([
      mathsCoachRpc<Readiness>("maths_get_readiness"),
      mathsCoachRpc<CalculationHub>("maths_get_calculation_hub"),
      mathsCoachRpc<Weekly>("maths_get_weekly_leakage").catch(() => null),
      fetchActiveExamSession(),
    ]);
    setData({ readiness, calculation, weekly, active });
    setError("");
  }, []);

  useEffect(() => {
    if (!ready) return;
    let alive = true;
    void load().catch((e: unknown) => { if (alive) setError(e instanceof Error ? e.message : String(e)); });
    const unsubs = [
      subscribeMathsFresh<Readiness>("maths_get_readiness", undefined, next => { if (alive) setData(prev => prev ? { ...prev, readiness: next } : prev); }),
      subscribeMathsFresh<CalculationHub>("maths_get_calculation_hub", undefined, next => { if (alive) setData(prev => prev ? { ...prev, calculation: next } : prev); }),
    ];
    const ownerChanged = () => { if (alive) { setData(null); setError(""); void load().catch((e: unknown) => { if (alive) setError(e instanceof Error ? e.message : String(e)); }); } };
    window.addEventListener("maths:v2-owner-change", ownerChanged);
    return () => { alive = false; unsubs.forEach(fn => fn()); window.removeEventListener("maths:v2-owner-change", ownerChanged); };
  }, [ready, load]);

  async function start(kind: "sprint" | "calculation" | "repair", reason?: Reason) {
    if (busy) return;
    setBusy(kind + (reason || ""));
    setError("");
    try {
      const active = await fetchActiveExamSession();
      if (active.active && active.sessionId) {
        setData(prev => prev ? { ...prev, active } : prev);
        if (kind === "sprint" || kind === "calculation") {
          router.push(`/maths/exam/session?id=${encodeURIComponent(active.sessionId)}`);
          return;
        }
        throw new Error("A timed Maths session is active. Resume or finish it before targeted repair.");
      }

      let session: MathsSession;
      if (kind === "sprint") session = await startMathsCoachSession("maths_start_sprint", { p_diagnostic: true });
      else if (kind === "calculation") session = await startMathsCoachSession("maths_start_calculation", { p_mode: "timed", p_skill: data?.calculation.todayFocus?.[0] || null, p_count: 60 });
      else session = await startMathsCoachSession("maths_start_repair", { p_count: 5, p_reason: reason || data?.readiness.biggestLeak || null });

      if (kind === "sprint" || kind === "calculation") router.push(`/maths/exam/session?id=${encodeURIComponent(session.sessionId)}`);
      else router.push(`/maths/session?id=${encodeURIComponent(session.sessionId)}`);
    } catch (e: unknown) {
      const active = await fetchActiveExamSession().catch(() => null);
      if (active?.active && active.sessionId && (kind === "sprint" || kind === "calculation")) {
        setData(prev => prev ? { ...prev, active } : prev);
        router.push(`/maths/exam/session?id=${encodeURIComponent(active.sessionId)}`);
      } else {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setBusy("");
    }
  }

  if (!ready) return <MathsLoading text="Checking Maths session…" />;
  if (!data && !error) return <MathsLoading text="Preparing Exam mode…" />;
  if (!data) return <div className="maths-error">{error || "Exam Preparation could not be loaded."}</div>;

  const stats = sprintStats(data.readiness);
  const daysLeft = Math.max(0, 30 - Math.max(1, data.readiness.studyDay) + 1);
  const plan = primaryPlan(data);
  const calcGroups = groupedCalculation(data.calculation.skills ?? []);
  const measuredCount = calcGroups.filter(x => x.attempted > 0).length;
  const strongCount = calcGroups.filter(x => x.band === "Automatic" || x.band === "Strong").length;
  const weakCount = calcGroups.filter(x => x.attempted > 0 && x.band !== "Automatic" && x.band !== "Strong").length;
  const activeExam = data.active.active && data.active.sessionId ? data.active : null;
  const activeTime = activeExam?.expired
    ? "Time expired · open to finalize"
    : activeExam?.remainingSeconds == null
      ? "Timer is still running"
      : `${formatClock(activeExam.remainingSeconds)} remaining · timer keeps running`;

  return <section className="mex-page">
    <header className="mex-head">
      <Link className="mex-back" href="/maths">← Home</Link>
      <div><strong>Exam Preparation</strong><span>{daysLeft} days left · 45+ goal</span></div>
      <button className="mex-info" type="button" aria-label="Exam Preparation details" onClick={() => setInfoOpen(true)}>i</button>
    </header>

    {error && <div className="mex-error" role="alert">{error}</div>}

    {activeExam && <section className="mex-resume-strip">
      <div><span>{activeExam.expired ? "Timed session ended" : "Saved timed session"}</span><strong>{activeExam.title || "Maths timed session"}</strong><small>Q {Number(activeExam.currentIndex || 0) + 1}/{activeExam.target || "—"} · {activeTime}</small></div>
      <Link className="mex-primary small" href={`/maths/exam/session?id=${encodeURIComponent(activeExam.sessionId!)}`}>{activeExam.expired ? "Finalize" : "Resume"}</Link>
    </section>}

    <section className="mex-sprint-card">
      <div className="mex-kicker">SSC STANDARD</div>
      <h1>25 Questions · 15 Minutes</h1>
      <p>50 marks · −0.50 wrong · fresh balanced Maths section</p>
      <button className="mex-primary" type="button" disabled={!!busy || !!activeExam} onClick={() => void start("sprint")}>{busy === "sprint" ? "Starting…" : activeExam ? "Resume timed session first" : "Start Sprint"}</button>
    </section>

    <section className="mex-readiness" aria-label="SSC Standard readiness">
      <MiniMetric label="Last" value={scoreText(stats.last)} />
      <MiniMetric label="5-Sprint Avg" value={scoreText(stats.five)} />
      <MiniMetric label="45+ Streak" value={stats.streak} />
    </section>
    <p className="mex-readiness-note">Readiness uses completed SSC Standard Sprints only. Repair and calculation drills do not inflate the score.</p>

    <section className="mex-plan-card">
      <div><span>Today’s priority · {plan.tag}</span><strong>{plan.title}</strong><small>{plan.sub}</small></div>
      {plan.kind === "calculation"
        ? <button type="button" disabled={!!busy || !!activeExam} onClick={() => void start("calculation")}>10:00 Drill</button>
        : plan.kind === "repair"
          ? <button type="button" disabled={!!busy || !!activeExam} onClick={() => void start("repair", (data.readiness.biggestLeak || undefined) as Reason | undefined)}>Repair 5</button>
          : <button type="button" disabled={!!busy || !!activeExam} onClick={() => void start("sprint")}>Start Sprint</button>}
    </section>

    <section className="mex-block">
      <div className="mex-section-head"><div><span>CALCULATION SPEED</span><h2>Automaticity before pressure</h2></div><button type="button" disabled={!!busy || !!activeExam} onClick={() => void start("calculation")}>Start 10:00</button></div>
      <p className="mex-block-sub">Fractions/percentages, squares/roots, cubes, tables, multiplication, division, cancellation, approximation, simplification, number-speed and SSC embedded calculation are tracked from the real {data.calculation.total}-card calculation pool.</p>
      <div className="mex-calc-summary"><MiniMetric label="Measured" value={`${measuredCount}/${calcGroups.length}`} /><MiniMetric label="Strong" value={strongCount} /><MiniMetric label="Need work" value={weakCount} /></div>
      <div className="mex-calc-grid">{calcGroups.map(x => <div className="mex-calc-row" key={x.label}><span><b>{x.label}</b><small>{x.attempted ? `${x.attempted} measured${x.accuracy == null ? "" : ` · ${x.accuracy.toFixed(0)}%`}` : `${x.total} cards · build evidence`}</small></span><strong className={`band-${x.band.toLowerCase().replace(/\s+/g, "-")}`}>{x.band}</strong></div>)}</div>
    </section>

    <section className="mex-more">
      <div className="mex-section-inline"><strong>Targeted Repair</strong><button type="button" onClick={() => setShowMore(x => !x)}>{showMore ? "Less" : "More"}</button></div>
      <div className="mex-repair-actions">
        <button type="button" disabled={!!busy || !!activeExam} onClick={() => void start("repair", (data.readiness.biggestLeak || undefined) as Reason | undefined)}>Biggest Leak</button>
        {activeExam ? <span className="mex-disabled-action">Approach Scan</span> : <Link href="/maths/approach">Approach Scan</Link>}
        {showMore && reasons.map(reason => <button type="button" key={reason.id} disabled={!!busy || !!activeExam} onClick={() => void start("repair", reason.id)}>{reason.id} · {reason.label}</button>)}
      </div>
      {activeExam && <p className="mex-active-note">A timed session is active. Resume or finalize it before starting another Exam Prep action.</p>}
    </section>

    {infoOpen && <InfoModal data={data} onClose={() => setInfoOpen(false)} />}
  </section>;
}

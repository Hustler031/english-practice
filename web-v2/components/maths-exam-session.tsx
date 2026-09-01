"use client";

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { MathsDiagram } from "@/components/maths-diagram";
import { MathsLoading } from "@/components/maths-frame";
import { mathsCoachRpc } from "@/lib/maths-coach-rpc";
import {
  getMathsSession,
  mathsErrorMessage,
  mathsLocalSafe,
  rememberMathsSession,
  type MathsQuestion,
  type MathsSession,
} from "@/lib/maths-rpc";
import { useAuthGuard } from "@/lib/use-auth";

type SprintAnalysis = {
  ok: boolean;
  score: number;
  maxScore: number;
  correct: number;
  wrong: number;
  unattempted: number;
  recoverableMarksEstimate: number;
  reasons: Record<string, number>;
  selection: { goodSkips: number; badSkips: number; timeTraps: number };
  bestNextAction: string;
};
type SprintReviewItem = {
  position: number;
  questionId: string;
  chapter: string;
  topic: string;
  subtopic: string;
  prompt: string;
  answer: string;
  explanation: string;
  correctOption: string;
  attemptId?: string | null;
  result: string;
  selectedOption?: string | null;
  responseSec?: number | null;
  baselineSec?: number | null;
  inferredReason?: string | null;
  confirmedReason?: string | null;
  finalReason?: string | null;
  inferenceConfidence?: number | null;
  slowCorrect?: boolean;
};
type SprintReview = { ok: boolean; sessionId: string; items: SprintReviewItem[] };
type CalcSummary = {
  ok: boolean;
  attempted: number;
  correct: number;
  wrong: number;
  accuracy: number;
  qpm: number;
  medianSec: number;
  p75Sec: number;
  p90Sec: number;
  elapsedSec: number;
  skills: { skill: string; attempted: number; accuracy: number; medianSec: number; baselineSec: number; band: string }[];
};

type AttemptResult = { result: string; selectedOption?: string; attemptId?: string };
const diagnosis = ["CAL", "APP", "CON", "FOR", "SILLY", "TIME"] as const;
const REVIEW_PREFIX = "maths:exam:review:";
const VISITED_PREFIX = "maths:exam:visited:";

function formatClock(seconds: number) {
  const s = Math.max(0, Math.ceil(seconds));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}
function readIndexSet(prefix: string, id: string) {
  if (typeof window === "undefined") return new Set<number>();
  try {
    const raw = JSON.parse(localStorage.getItem(prefix + id) || "[]");
    return new Set<number>(Array.isArray(raw) ? raw.map(Number).filter(Number.isFinite) : []);
  } catch { return new Set<number>(); }
}
function writeIndexSet(prefix: string, id: string, values: Set<number>) {
  try { localStorage.setItem(prefix + id, JSON.stringify([...values].sort((a, b) => a - b))); } catch {}
}
function clearRuntimeSets(id: string) {
  try { localStorage.removeItem(REVIEW_PREFIX + id); localStorage.removeItem(VISITED_PREFIX + id); } catch {}
}
function ErrorBox({ error }: { error: string }) {
  return error ? <div className="mex-error" role="alert">{error}</div> : null;
}
function ResultMetric({ label, value }: { label: string; value: string | number }) {
  return <div className="mex-result-metric"><b>{value}</b><small>{label}</small></div>;
}

function LocalSafeResult({ session }: { session: MathsSession }) {
  const attempts = Object.values(session.attempts ?? {}).filter(x => x.result === "correct" || x.result === "wrong");
  const correct = attempts.filter(x => x.result === "correct").length;
  const wrong = attempts.filter(x => x.result === "wrong").length;
  const accuracy = attempts.length ? Math.round((1000 * correct) / attempts.length) / 10 : 0;
  return <section className="mex-result-page">
    <header className="mex-result-head"><Link href="/maths/exam">← Exam Prep</Link><div><span>Local Safe preview</span><h1>Session complete</h1></div></header>
    <div className="mex-result-grid"><ResultMetric label="Attempted" value={attempts.length} /><ResultMetric label="Correct" value={correct} /><ResultMetric label="Wrong" value={wrong} /><ResultMetric label="Accuracy" value={`${accuracy}%`} /></div>
    <p className="mex-result-note">Preview evidence stayed on this device; production learning data was not changed.</p>
    <Link className="mex-primary link" href="/maths/exam">Back to Exam Prep</Link>
  </section>;
}

function SprintResult({ session }: { session: MathsSession }) {
  const [analysis, setAnalysis] = useState<SprintAnalysis | null>(null);
  const [review, setReview] = useState<SprintReview | null>(null);
  const [error, setError] = useState("");
  const [open, setOpen] = useState<number | null>(null);
  const [saving, setSaving] = useState("");

  const reload = useCallback(async () => {
    try {
      const [a, r] = await Promise.all([
        mathsCoachRpc<SprintAnalysis>("maths_get_sprint_analysis", { p_session_id: session.sessionId }),
        mathsCoachRpc<SprintReview>("maths_get_sprint_review", { p_session_id: session.sessionId }),
      ]);
      setAnalysis(a);
      setReview(r);
      setError("");
    } catch (e: unknown) { setError(mathsErrorMessage(e, "Could not build Sprint analysis.")); }
  }, [session.sessionId]);

  useEffect(() => { void reload(); }, [reload]);

  async function confirm(item: SprintReviewItem, reason: string) {
    if (!item.attemptId || saving) return;
    setSaving(item.questionId + reason);
    setError("");
    try {
      await mathsCoachRpc("maths_confirm_diagnosis", { p_attempt_id: item.attemptId, p_reason: reason, p_confidence_response: null });
      setReview(prev => prev ? { ...prev, items: prev.items.map(x => x.questionId === item.questionId ? { ...x, confirmedReason: reason, finalReason: reason } : x) } : prev);
      const fresh = await mathsCoachRpc<SprintAnalysis>("maths_get_sprint_analysis", { p_session_id: session.sessionId });
      setAnalysis(fresh);
    } catch (e: unknown) { setError(mathsErrorMessage(e, "Could not save diagnosis.")); }
    finally { setSaving(""); }
  }

  if (!analysis && !error) return <MathsLoading text="Analysing marks leakage…" />;
  if (!analysis) return <ErrorBox error={error || "Sprint analysis unavailable."} />;
  const leakage = Object.entries(analysis.reasons ?? {}).sort((a, b) => Number(b[1]) - Number(a[1]));
  const biggest = leakage[0]?.[0] || "—";

  return <section className="mex-result-page">
    <header className="mex-result-head"><Link href="/maths/exam">← Exam Prep</Link><div><span>SSC Standard result</span><h1>{analysis.score} / {analysis.maxScore}</h1><p>{analysis.bestNextAction}</p></div></header>
    <ErrorBox error={error} />

    <div className="mex-result-grid"><ResultMetric label="Correct" value={analysis.correct} /><ResultMetric label="Wrong" value={analysis.wrong} /><ResultMetric label="Unanswered" value={analysis.unattempted} /><ResultMetric label="Recoverable" value={`+${analysis.recoverableMarksEstimate}`} /></div>

    <section className="mex-result-block"><div className="mex-result-title"><span>BIGGEST LEAK</span><strong>{biggest}</strong></div><div className="mex-leak-row">{diagnosis.map(reason => <span className={reason === biggest ? "active" : ""} key={reason}><b>{reason}</b><small>{analysis.reasons?.[reason] || 0}</small></span>)}</div></section>

    <section className="mex-result-block"><div className="mex-result-title"><span>POST-SPRINT REVIEW</span><strong>{review?.items?.length ?? 0} items</strong></div>{review?.items?.length ? <div className="mex-review-list">{review.items.map(item => {
      const expanded = open === item.position;
      const reason = item.confirmedReason || item.finalReason || item.inferredReason || (item.slowCorrect ? "TIME" : "");
      const canDiagnose = !!item.attemptId && item.result !== "unattempted";
      return <article className="mex-review-item" key={`${item.position}-${item.questionId}`}>
        <button className="mex-review-summary" type="button" onClick={() => setOpen(expanded ? null : item.position)} aria-expanded={expanded}>
          <span><b>Q{item.position + 1} · {item.chapter || "Maths"}</b><small>{item.topic || item.subtopic || item.questionId} · {item.result === "unattempted" ? "Unanswered" : item.slowCorrect && item.result === "correct" ? "Slow correct" : item.result}</small></span>
          <strong>{reason || "Review"}</strong><i>{expanded ? "−" : "+"}</i>
        </button>
        {expanded && <div className="mex-review-detail">
          <p className="mex-review-question">{item.prompt}</p>
          <div className="mex-answer-compare"><span>Selected <b>{item.selectedOption || "—"}</b></span><span>Correct <b>{item.correctOption || "—"}</b></span>{item.responseSec != null && <span>Time <b>{Number(item.responseSec).toFixed(1)}s</b>{item.baselineSec != null ? ` / ${Number(item.baselineSec).toFixed(1)}s baseline` : ""}</span>}</div>
          {item.answer && <div className="mex-review-copy"><b>Answer</b><p>{item.answer}</p></div>}
          {item.explanation && <div className="mex-review-copy"><b>Explanation</b><p>{item.explanation}</p></div>}
          {canDiagnose && <div className="mex-diagnosis"><span>Why did I miss/slow down?</span><div>{diagnosis.map(code => <button className={reason === code ? "active" : ""} type="button" disabled={!!saving} key={code} onClick={() => void confirm(item, code)}>{saving === item.questionId + code ? "…" : code}</button>)}</div></div>}
        </div>}
      </article>;
    })}</div> : <p className="mex-result-note">No wrong, unanswered or slow-correct items need review.</p>}</section>

    <div className="mex-result-actions"><Link className="mex-primary link" href="/maths/exam">Back to Exam Prep</Link><Link className="mex-secondary link" href="/maths/repair">Open Repair Queue</Link></div>
  </section>;
}

function CalculationResult({ session }: { session: MathsSession }) {
  const [data, setData] = useState<CalcSummary | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let alive = true;
    void mathsCoachRpc<CalcSummary>("maths_get_calculation_summary", { p_session_id: session.sessionId })
      .then(x => { if (alive) { setData(x); setError(""); } })
      .catch((e: unknown) => { if (alive) setError(mathsErrorMessage(e, "Could not build speed summary.")); });
    return () => { alive = false; };
  }, [session.sessionId]);
  if (!data && !error) return <MathsLoading text="Building speed summary…" />;
  if (!data) return <ErrorBox error={error || "Calculation summary unavailable."} />;
  return <section className="mex-result-page">
    <header className="mex-result-head"><Link href="/maths/exam">← Exam Prep</Link><div><span>Calculation speed result</span><h1>{data.qpm} Q/min</h1><p>{data.accuracy}% accuracy · median {data.medianSec}s</p></div></header>
    <ErrorBox error={error} />
    <div className="mex-result-grid"><ResultMetric label="Attempted" value={data.attempted} /><ResultMetric label="Accuracy" value={`${data.accuracy}%`} /><ResultMetric label="P75" value={`${data.p75Sec}s`} /><ResultMetric label="P90" value={`${data.p90Sec}s`} /></div>
    <section className="mex-result-block"><div className="mex-result-title"><span>SKILL BANDS</span><strong>Speed + accuracy</strong></div><div className="mex-speed-list">{data.skills.map(skill => <div key={skill.skill}><span><b>{skill.skill}</b><small>{skill.attempted} measured · {skill.accuracy}%</small></span><strong>{skill.band}<small>{skill.medianSec}s / {skill.baselineSec}s</small></strong></div>)}</div></section>
    <div className="mex-result-actions"><Link className="mex-primary link" href="/maths/exam">Back to Exam Prep</Link><Link className="mex-secondary link" href="/maths/calculation">Calculation Bank</Link></div>
  </section>;
}

function SessionResult({ session }: { session: MathsSession }) {
  if (session.localSafe) return <LocalSafeResult session={session} />;
  const mode = String(session.mode || "").toLowerCase();
  if (mode === "section_sprint") return <SprintResult session={session} />;
  if (mode === "calculation_speed" && Boolean(session.params?.calculationTimed)) return <CalculationResult session={session} />;
  return <section className="mex-result-page"><header className="mex-result-head"><Link href="/maths/exam">← Exam Prep</Link><div><span>Session complete</span><h1>Practice saved</h1></div></header></section>;
}

function QuestionMap({ session, index, review, visited, onJump, onClose }: { session: MathsSession; index: number; review: Set<number>; visited: Set<number>; onJump: (index: number) => void; onClose: () => void }) {
  return <div className="mex-map-backdrop" role="presentation" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}><section className="mex-map" role="dialog" aria-modal="true" aria-label="Question map"><header><div><span>QUESTION MAP</span><strong>{session.target} questions</strong></div><button type="button" onClick={onClose}>×</button></header><div className="mex-map-grid">{session.questions.slice(0, session.target).map((q, i) => {
    const attempt = session.attempts?.[q.questionId];
    const state = attempt ? "answered" : review.has(i) ? "review" : visited.has(i) ? "visited" : "";
    return <button type="button" className={`${state} ${i === index ? "current" : ""}`} key={`${q.questionId}-${i}`} onClick={() => onJump(i)}>{i + 1}</button>;
  })}</div><div className="mex-map-legend"><span><i className="answered"/>Answered</span><span><i className="review"/>Review</span><span><i className="visited"/>Visited</span></div></section></div>;
}

function ExamSessionInner() {
  const ready = useAuthGuard();
  const search = useSearchParams();
  const sessionId = search.get("id") || "";
  const [session, setSession] = useState<MathsSession | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [remaining, setRemaining] = useState<number | null>(null);
  const [mapOpen, setMapOpen] = useState(false);
  const [finishOpen, setFinishOpen] = useState(false);
  const [review, setReview] = useState<Set<number>>(() => new Set());
  const [visited, setVisited] = useState<Set<number>>(() => new Set());
  const startedAt = useRef(Date.now());
  const finishing = useRef(false);

  const load = useCallback(async () => {
    if (!sessionId) throw new Error("Session ID is missing.");
    const next = await getMathsSession(sessionId);
    setSession(next);
    startedAt.current = Date.now();
    setReview(readIndexSet(REVIEW_PREFIX, sessionId));
    const seen = readIndexSet(VISITED_PREFIX, sessionId);
    seen.add(Math.max(0, Number(next.currentIndex || 0)));
    setVisited(seen);
    writeIndexSet(VISITED_PREFIX, sessionId, seen);
    setError("");
  }, [sessionId]);

  useEffect(() => { if (ready) void load().catch((e: unknown) => setError(mathsErrorMessage(e, "Could not restore Exam session."))); }, [ready, load]);

  const mode = String(session?.mode || "").toLowerCase();
  const isSprint = mode === "section_sprint";
  const isTimedCalc = mode === "calculation_speed" && Boolean(session?.params?.calculationTimed);
  const timed = isSprint || isTimedCalc;
  const deadlineAt = typeof session?.params?.deadlineAt === "string" ? String(session.params.deadlineAt) : "";
  const index = session ? Math.max(0, Math.min(Number(session.currentIndex || 0), Math.max(0, session.questions.length - 1))) : 0;
  const q = session?.questions?.[index];
  const attempt = q ? session?.attempts?.[q.questionId] : undefined;
  const selected = attempt?.selectedOption || "";
  const answeredCount = session ? session.questions.slice(0, session.target).filter(item => Boolean(session.attempts?.[item.questionId])).length : 0;
  const unansweredCount = session ? Math.max(0, session.target - answeredCount) : 0;

  const finish = useCallback(async (force = false) => {
    if (!session || finishing.current) return;
    if (!force && isSprint && unansweredCount > 0) { setFinishOpen(true); return; }
    finishing.current = true;
    setBusy(true);
    setError("");
    setFinishOpen(false);
    try {
      await mathsCoachRpc("maths_finish_session", { p_session_id: session.sessionId });
      const next = { ...session, completed: true };
      setSession(next);
      rememberMathsSession(next);
      clearRuntimeSets(session.sessionId);
    } catch (e: unknown) { setError(mathsErrorMessage(e, "Could not finish the timed session.")); }
    finally { setBusy(false); finishing.current = false; }
  }, [session, isSprint, unansweredCount]);

  useEffect(() => {
    if (!timed || !deadlineAt || session?.completed) return;
    const tick = () => {
      const seconds = Math.max(0, (Date.parse(deadlineAt) - Date.now()) / 1000);
      setRemaining(seconds);
      if (seconds <= 0) void finish(true);
    };
    tick();
    const timer = window.setInterval(tick, 250);
    return () => window.clearInterval(timer);
  }, [timed, deadlineAt, session?.completed, finish]);

  async function move(nextIndex: number, source = session!) {
    if (!source) return;
    const max = Math.max(0, source.questions.length - 1);
    const nextPosition = Math.max(0, Math.min(nextIndex, max));
    const next = { ...source, currentIndex: nextPosition };
    setSession(next);
    rememberMathsSession(next);
    startedAt.current = Date.now();
    setVisited(prev => {
      const copy = new Set(prev); copy.add(nextPosition); writeIndexSet(VISITED_PREFIX, source.sessionId, copy); return copy;
    });
    try {
      await mathsCoachRpc("maths_save_session_position", { p_session_id: source.sessionId, p_index: nextPosition });
      if (isTimedCalc && !mathsLocalSafe() && source.questions.length - nextPosition <= 5 && (remaining ?? 1) > 20) {
        const refilled = await mathsCoachRpc<MathsSession>("maths_refill_calculation_session", { p_session_id: source.sessionId, p_count: 20 });
        if (refilled?.questions?.length > next.questions.length) {
          const merged = { ...refilled, currentIndex: nextPosition };
          setSession(merged);
          rememberMathsSession(merged);
        }
      }
    } catch (e: unknown) { setError(mathsErrorMessage(e, "Could not save question position.")); }
  }

  async function answer(option?: string) {
    if (!session || !q || attempt || busy) return;
    setBusy(true);
    setError("");
    const elapsed = Math.max(0, (Date.now() - startedAt.current) / 1000);
    const clientKey = `mex-${session.sessionId}-${q.questionId}`;
    try {
      const out = await mathsCoachRpc<AttemptResult>("maths_submit_answer", {
        p_session_id: session.sessionId,
        p_question_id: q.questionId,
        p_selected_option: option ?? null,
        p_response_sec: Number(elapsed.toFixed(1)),
        p_client_attempt_key: clientKey,
      });
      const next: MathsSession = {
        ...session,
        attempts: {
          ...(session.attempts ?? {}),
          [q.questionId]: { result: out.result, selectedOption: out.selectedOption ?? option ?? "", responseSec: elapsed, attemptId: out.attemptId ?? clientKey },
        },
      };
      setSession(next);
      rememberMathsSession(next);
      if (isTimedCalc && index < next.questions.length - 1) window.setTimeout(() => void move(index + 1, next), 80);
    } catch (e: unknown) { setError(mathsErrorMessage(e, "Could not save this answer.")); }
    finally { setBusy(false); }
  }

  function toggleReview() {
    if (!session) return;
    setReview(prev => {
      const next = new Set(prev);
      if (next.has(index)) next.delete(index); else next.add(index);
      writeIndexSet(REVIEW_PREFIX, session.sessionId, next);
      return next;
    });
  }

  if (!ready) return <MathsLoading text="Checking Maths session…" />;
  if (!session && !error) return <MathsLoading text="Restoring exact timed session…" />;
  if (!session) return <div className="mex-session-error"><ErrorBox error={error || "Session not found."} /><Link href="/maths/exam">← Exam Prep</Link></div>;
  if (session.completed) return <SessionResult session={session} />;
  if (!q) return <div className="mex-session-error"><ErrorBox error="No renderable questions in this session." /></div>;

  const progress = session.target ? Math.min(100, Math.round(((index + 1) * 100) / session.target)) : 0;
  const marked = review.has(index);
  const visibleTimer = remaining == null ? Number(session.params?.durationSec || 0) : remaining;

  return <div className={`mex-session ${isSprint ? "sprint" : "calculation"}`}>
    <header className="mex-session-head">
      <div className="mex-session-top"><Link href="/maths/exam" aria-label="Back to Exam Preparation">←</Link><div><strong>{isSprint ? "SSC Standard" : "Calculation Speed"}</strong><span>{isSprint ? "25Q · +2 / −0.5" : "10-minute automaticity"}</span></div><b className={visibleTimer <= 60 ? "urgent" : ""}>{formatClock(visibleTimer)}</b></div>
      <div className="mex-session-meta"><span>Q {index + 1}/{session.target}</span><span>{answeredCount} answered</span>{isSprint && <button type="button" disabled={busy} onClick={() => void finish(false)}>Finish</button>}</div>
      <div className="mex-session-progress"><i style={{ width: `${progress}%` }} /></div>
    </header>

    <ErrorBox error={error} />

    <main className="mex-question-card">
      <div className="mex-question-meta"><span>{q.chapter || "Maths"}</span>{q.topic && <span>{q.topic}</span>}<span>{q.questionId}</span></div>
      <div className="mex-question-text">{q.prompt}</div>
      {q.diagram && <MathsDiagram diagram={q.diagram} />}
      {q.answerMode === "MCQ" ? <div className="mex-options">{q.options.map(option => <button className={selected === option.key ? "selected" : ""} type="button" disabled={!!attempt || busy} key={option.key} onClick={() => void answer(option.key)}><b>{option.key}</b><span>{option.text}</span></button>)}</div> : !attempt ? <button className="mex-primary reveal" type="button" disabled={busy} onClick={() => void answer()}>Reveal</button> : <div className="mex-recall-seen">Seen · continue</div>}
      {isSprint && <button className={`mex-mark-review ${marked ? "active" : ""}`} type="button" onClick={toggleReview}>{marked ? "◆ Marked for review" : "◇ Mark for review"}</button>}
    </main>

    <nav className="mex-session-nav">
      <button type="button" disabled={index === 0 || busy} onClick={() => void move(index - 1)}>‹ Previous</button>
      <button type="button" className="map" onClick={() => setMapOpen(true)}>{index + 1}/{session.target}</button>
      {index < session.questions.length - 1 ? <button type="button" disabled={busy} onClick={() => void move(index + 1)}>Next ›</button> : <button type="button" className="finish" disabled={busy} onClick={() => void finish(false)}>Finish</button>}
    </nav>

    {mapOpen && <QuestionMap session={session} index={index} review={review} visited={visited} onJump={next => { setMapOpen(false); void move(next); }} onClose={() => setMapOpen(false)} />}

    {finishOpen && <div className="mex-finish-backdrop" role="presentation" onMouseDown={e => { if (e.target === e.currentTarget) setFinishOpen(false); }}><section className="mex-finish-dialog" role="dialog" aria-modal="true" aria-label="Finish Sprint"><span>FINISH SPRINT</span><h2>{unansweredCount} unanswered</h2><p>You can return to the question map, or submit now. Unanswered questions score zero.</p><div><button type="button" onClick={() => setFinishOpen(false)}>Keep solving</button><button type="button" className="danger" disabled={busy} onClick={() => void finish(true)}>Finish now</button></div></section></div>}
  </div>;
}

export default function MathsExamSessionPage() {
  return <Suspense fallback={<MathsLoading text="Opening timed Maths session…" />}><ExamSessionInner /></Suspense>;
}

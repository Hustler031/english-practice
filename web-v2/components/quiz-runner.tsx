"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { rpc } from "@/lib/supabase";
import { makeDisplayOptions, type DisplayOption } from "@/lib/options";
import AddWordSheet from "@/components/add-word-sheet";
import { clearPausedQuiz, savePausedQuiz, type PausedQuizSession } from "@/lib/quiz-session";

type Question = { id:string; category?:string; topic?:string; subtopic?:string; word?:string; question:string; options:{key:string;text:string}[]; correctKey?:string; questionType?:string; explanation?:string; tip?:string; usageNote?:string; example?:string; memoryAid?:string; starred?:boolean; difficult?:boolean; mastered?:boolean; status?:string; attempts?:number; wrong?:number };
type Props = { title:string; backHref:string; load:()=>Promise<Question[]>; module?:string; emptyText?:string; resumeSession?:PausedQuizSession|null };

export default function QuizRunner({ title, backHref, load, module="practice", emptyText="No questions are available for this selection.", resumeSession }: Props) {
  const router = useRouter();
  const [items, setItems] = useState<Question[]>([]);
  const [idx, setIdx] = useState(0);
  const [selected, setSelected] = useState("");
  const [result, setResult] = useState<{correct:boolean;correctCanonicalKey:string}|null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const started = useRef(Date.now());
  const optionCache = useRef(new Map<string, DisplayOption[]>());

  useEffect(() => {
    let live = true;
    if (resumeSession?.questions?.length) {
      setItems(resumeSession.questions as Question[]);
      setIdx(Math.max(0, Math.min(resumeSession.index || 0, resumeSession.questions.length - 1)));
      setLoading(false);
      started.current = Date.now();
      return () => { live = false; };
    }
    setLoading(true); optionCache.current.clear();
    load().then((x) => { if (live) { setItems(Array.isArray(x) ? x : []); setIdx(0); started.current = Date.now(); } })
      .catch((e:any) => live && setError(e.message)).finally(() => live && setLoading(false));
    return () => { live = false; };
  }, [load, resumeSession]);

  useEffect(() => {
    if (!items.length) return;
    savePausedQuiz({ title, backHref, module, index:idx, questions:items, savedAt:Date.now() });
  }, [items, idx, title, backHref, module]);

  const q = items[idx];
  const options = useMemo(() => {
    if (!q) return [];
    const hit = optionCache.current.get(q.id); if (hit) return hit;
    const made = makeDisplayOptions(q.questionType, q.options || []); optionCache.current.set(q.id, made); return made;
  }, [q?.id, q?.questionType, q?.options]);
  const correctDisplayKey = result ? options.find((o) => o.canonicalKey === result.correctCanonicalKey)?.key || result.correctCanonicalKey : "";

  function move(next:number) { setIdx(next); setSelected(""); setResult(null); setError(""); started.current = Date.now(); window.scrollTo({ top:0, behavior:"smooth" }); }
  async function answer(option:DisplayOption) {
    if (!q || result || busy) return;
    setSelected(option.key); setBusy(true);
    try { const out = await rpc<any>("english_submit_answer", { p_question_id:q.id, p_selected_key:option.canonicalKey, p_time_seconds:Math.min(180, (Date.now()-started.current)/1000), p_marked_revision:!!q.starred, p_attempt_id:`v2-${q.id}-${Date.now()}-${Math.random().toString(36).slice(2,8)}`, p_module:module }); setResult({ correct:!!out.is_correct, correctCanonicalKey:String(out.correct_key || q.correctKey || "") }); }
    catch (e:any) { setError(e.message); } finally { setBusy(false); }
  }
  async function toggleMark() {
    if (!q) return; const next = !q.starred;
    setItems((rows) => rows.map((row, i) => i === idx ? { ...row, starred:next } : row));
    try { await rpc("english_set_starred", { p_question_id:q.id, p_starred:next }); }
    catch (e:any) { setItems((rows) => rows.map((row, i) => i === idx ? { ...row, starred:!next } : row)); setError(e.message); }
  }
  async function toggleDifficult() {
    if (!q) return; const next = !q.difficult;
    setItems((rows) => rows.map((row, i) => i === idx ? { ...row, difficult:next } : row));
    try { await rpc("english_set_difficult", { p_question_id:q.id, p_difficult:next }); }
    catch (e:any) { setItems((rows) => rows.map((row, i) => i === idx ? { ...row, difficult:!next } : row)); setError(e.message); }
  }
  async function mastered() {
    if (!q || !window.confirm("Mark this as Mastered / Don't Repeat? You can restore it later.")) return;
    try { await rpc("english_set_mastered", { p_question_id:q.id, p_mastered:true, p_require_proven:false }); setItems((rows) => rows.map((row, i) => i === idx ? { ...row, mastered:true } : row)); if (idx < items.length - 1) move(idx + 1); else { clearPausedQuiz(); router.push(backHref); } }
    catch (e:any) { setError(e.message); }
  }

  if (loading) return <main className="center"><div className="muted">Loading {title}…</div></main>;
  if (!items.length) return <main className="shell quiz"><QuizTop title={title} backHref={backHref}/><div className="empty-state"><h2>{title}</h2><p className="muted">{error || emptyText}</p></div></main>;
  if (!q) return <main className="shell"><div className="error-box">Question position is unavailable.</div></main>;

  return <main className="shell quiz quiz-with-tools">
    <QuizTop title={title} backHref={backHref} count={`${idx + 1} / ${items.length}`}/>
    <div className="progress"><span style={{ width:`${((idx + 1) / items.length) * 100}%` }}/></div>
    <section className="quiz-card">
      <div className="quiz-meta"><span className="pill">{q.category || q.topic || "English"}</span>{q.subtopic && <span className="pill">{q.subtopic}</span>}<LearningSignals status={q.status} attempts={q.attempts} wrong={q.wrong}/></div>
      <div className="question-area">{q.word && <div className="question-word">{q.word}</div>}<div className="question">{q.question}</div></div>
      <div className="options">{options.map((o) => { let cls="option"; if (selected===o.key) cls+=" selected"; if (result && o.canonicalKey===result.correctCanonicalKey) cls+=" correct"; if (result && selected===o.key && o.canonicalKey!==result.correctCanonicalKey) cls+=" wrong"; return <button key={o.key} className={cls} onClick={() => answer(o)} disabled={!!result || busy}><span className="option-key">{o.key}</span><span>{o.text}</span></button>; })}</div>
      {error && <div className="result-wrap"><div className="error-box">{error}</div></div>}
      {result && <div className="result-wrap"><div className={`result-head ${result.correct ? "good-result" : "bad-result"}`}><span className="result-dot"/><strong>{result.correct ? "Correct" : "Incorrect"}</strong><span className="spacer"/><span className="pill">Answer {correctDisplayKey}</span></div><div className="explanation">{q.explanation || "No explanation available."}{q.example ? `\n\nExample: ${q.example}` : ""}{q.usageNote ? `\n\nUsage: ${q.usageNote}` : ""}{q.tip ? `\n\nTip: ${q.tip}` : ""}{q.memoryAid ? `\n\nRemember: ${q.memoryAid}` : ""}</div></div>}
      <button className={`mastered-after ${q.mastered ? "done" : ""}`} onClick={mastered}>{q.mastered ? "✓ Mastered" : "✓ Mark Mastered"}</button>
    </section>
    <div className="quiz-tools"><button className={`btn ghost ${q.starred ? "warn" : ""}`} onClick={toggleMark}>{q.starred ? "★ Marked" : "☆ Mark"}</button><AddWordSheet questionId={q.id} initialWord={q.word || ""} source={title} label="📝 Add Word"/><button className={`btn ghost ${q.difficult ? "danger" : ""}`} onClick={toggleDifficult}>! Difficult</button><button className="btn ghost" onClick={() => window.location.assign(backHref)}>Ⅱ Pause</button></div>
    <div className="quiz-nav"><button className="btn ghost" disabled={idx===0} onClick={() => move(idx-1)}>← Previous</button><button className="btn primary" onClick={() => { if (idx < items.length - 1) move(idx+1); else { clearPausedQuiz(); router.push(backHref); } }}>{idx===items.length-1 ? "Finish" : "Next →"}</button></div>
  </main>;
}

function QuizTop({ title, backHref, count }: { title:string; backHref:string; count?:string }) { return <div className="quiz-top"><Link className="btn ghost" href={backHref}>← Back</Link><div className="quiz-title"><div className="brand">{title}</div>{count && <div className="quiz-count">{count}</div>}</div><div/></div>; }
function LearningSignals({ status, attempts, wrong }: { status?:string; attempts?:number; wrong?:number }) { const persistent = status === "Persistent Weak"; const weak = !persistent && ["Weak", "Fragile"].includes(status || ""); return <>{persistent && <span className="pill signal-persistent">Persistent Weak</span>}{weak && <span className="pill signal-weak">Weak</span>}{typeof attempts === "number" && attempts > 0 && <span className="pill">{attempts} attempt{attempts === 1 ? "" : "s"}{wrong ? ` · ${wrong} wrong` : ""}</span>}</>; }

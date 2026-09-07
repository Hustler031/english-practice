"use client";

import { FormEvent, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { learnerErrorMessage, localProductionSafetyMode, supabaseBrowser } from "@/lib/supabase";

const types = ["AUTO", "V", "SM", "OWS", "PV", "IP"];
const SAVE_TIMEOUT_MS = 8_000;
const SAVED_CACHE_PREFIXES = [
  "ep:v2:rpc-cache:english_get_saved_revision_hub:",
  "ep:v2:rpc-cache:english_get_saved_items:",
];

type SaveWordResult = { ok?: boolean; id?: string; duplicate?: boolean; status?: string; gpt_status?: string };

function evictSavedCaches() {
  if (typeof window === "undefined") return;
  const removals: string[] = [];
  for (let i = 0; i < window.localStorage.length; i++) {
    const key = window.localStorage.key(i);
    if (key && SAVED_CACHE_PREFIXES.some(prefix => key.startsWith(prefix))) removals.push(key);
  }
  removals.forEach(key => window.localStorage.removeItem(key));
  try { window.dispatchEvent(new CustomEvent("ep:saved-word-saved")); } catch { /* best effort */ }
}

function sleep(ms: number) { return new Promise(resolve => window.setTimeout(resolve, ms)); }

async function saveWordOnce(args: Record<string, unknown>) {
  let timeout: number | null = null;
  try {
    const request = supabaseBrowser().rpc("english_save_word", args);
    const result = await Promise.race([
      request,
      new Promise<never>((_, reject) => {
        timeout = window.setTimeout(() => reject(new Error("Save timed out. Retrying…")), SAVE_TIMEOUT_MS);
      }),
    ]);
    if (result.error) throw result.error;
    const data = result.data as SaveWordResult | null;
    if (!data?.ok) throw new Error("Word was not saved. Please retry.");
    return data;
  } finally {
    if (timeout !== null) window.clearTimeout(timeout);
  }
}

export default function AddWordSheet({ questionId = "", initialWord = "", questionText = "", source = "Manual capture", label = "＋ Add Word" }: { questionId?: string; initialWord?: string; questionText?: string; source?: string; label?: string }) {
  const [open, setOpen] = useState(false);
  const [word, setWord] = useState("");
  const [type, setType] = useState("AUTO");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const inputRef = useRef<HTMLInputElement | null>(null);

  // Match the reliable Apps Script capture flow: quiz capture starts blank,
  // while a standalone caller may still supply an explicit initial value.
  const defaultWord = questionId ? "" : initialWord;

  useEffect(() => {
    if (!open) return;
    setWord(defaultWord);
    setType("AUTO");
    setMessage("");
    // Keep the Android-friendly delayed focus, while the transparent/non-blocking
    // capture surface still leaves the question readable behind the sheet.
    const timer = window.setTimeout(() => inputRef.current?.focus(), 60);
    return () => window.clearTimeout(timer);
  }, [open, defaultWord]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") closeSheet();
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [open]);

  function closeSheet() {
    inputRef.current?.blur();
    setOpen(false);
  }

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!word.trim()) return;
    if (localProductionSafetyMode()) {
      setMessage("Local Safe is read-only. Open the production app to save this word.");
      return;
    }
    setBusy(true); setMessage("");
    const args = { p_word: word.trim(), p_context: questionText.trim(), p_question_id: questionId, p_capture_type: type, p_module: "web-v2", p_source: source };
    try {
      let saved: SaveWordResult;
      try {
        saved = await saveWordOnce(args);
      } catch (firstError) {
        // A long-lived study tab can have a stale auth token or transient mobile network gap.
        // Refresh once, then retry. The backend de-duplicates by saved word, so retry is safe.
        await supabaseBrowser().auth.refreshSession().catch(() => undefined);
        await sleep(250);
        saved = await saveWordOnce(args);
      }
      evictSavedCaches();
      setMessage(saved.duplicate ? "Already saved · updated ✓" : "Saved ✓");
      setTimeout(closeSheet, 420);
    } catch (error: any) {
      setMessage(learnerErrorMessage(error, "Could not save. Your entry is still here — tap Save again."));
    } finally { setBusy(false); }
  }

  const sheet = open && typeof document !== "undefined" ? createPortal(
    <div className="sheet-backdrop add-word-backdrop" role="dialog" aria-label="Add word">
      <form className="add-word-sheet add-word-sheet-v2" onSubmit={save} autoComplete="off">
        <div className="add-word-handle" aria-hidden="true" />
        <div className="sheet-heading add-word-heading">
          <div>
            <strong>Add Word</strong>
            <span>{questionId ? "Save a word or doubt from this question." : "Save a word, doubt or usage point for revision."}</span>
          </div>
          <button className="sheet-close" type="button" onClick={closeSheet} aria-label="Close Add Word">×</button>
        </div>
        <input
          ref={inputRef}
          className="input add-word-input"
          type="text"
          inputMode="text"
          enterKeyHint="done"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          spellCheck={false}
          value={word}
          onChange={(e) => setWord(e.target.value)}
          placeholder="Word / doubt / usage point"
          required
        />
        <div className="capture-types add-word-types">{types.map((item) => <button className={`capture-type ${item === type ? "selected" : ""}`} type="button" key={item} aria-pressed={item === type} onClick={() => setType(item)}>{item === "IP" ? "I/P" : item}</button>)}</div>
        {message && <div className="form-message add-word-message">{message}</div>}
        <button className="btn primary sheet-save add-word-save" disabled={busy || !word.trim()}>{busy ? "Saving…" : "Save"}</button>
      </form>
    </div>,
    document.body
  ) : null;

  return <>
    <button className="btn ghost compact-add" type="button" onClick={() => setOpen(true)}>{label}</button>
    {sheet}
  </>;
}

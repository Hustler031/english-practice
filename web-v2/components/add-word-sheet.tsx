"use client";

import { FormEvent, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { rpc } from "@/lib/supabase";

const types = ["AUTO", "V", "SM", "OWS", "PV", "IP"];

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
    // The legacy app used a short post-open focus delay. On Android Chrome
    // this is more reliable than contentEditable or synthetic focus tricks.
    const timer = window.setTimeout(() => inputRef.current?.focus(), 60);
    return () => window.clearTimeout(timer);
  }, [open, defaultWord]);

  function closeSheet() {
    inputRef.current?.blur();
    setOpen(false);
  }

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!word.trim()) return;
    setBusy(true); setMessage("");
    try {
      await rpc("english_save_word", { p_word: word.trim(), p_context: questionText.trim(), p_question_id: questionId, p_capture_type: type, p_module: "web-v2", p_source: source });
      setMessage("Saved ✓");
      setTimeout(closeSheet, 260);
    } catch (error: any) { setMessage(error.message || "Could not save"); }
    finally { setBusy(false); }
  }

  const sheet = open && typeof document !== "undefined" ? createPortal(
    <div className="sheet-backdrop add-word-backdrop" role="dialog" aria-modal="true" aria-label="Add word" onMouseDown={(e) => { if (e.target === e.currentTarget) closeSheet(); }}>
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
        <div className="capture-types add-word-types">{types.map((item) => <button className={`capture-type ${item === type ? "selected" : ""}`} type="button" key={item} onClick={() => setType(item)}>{item === "IP" ? "I/P" : item}</button>)}</div>
        {message && <div className="form-message add-word-message">{message}</div>}
        <button className="btn primary sheet-save add-word-save" disabled={busy || !word.trim()}>{busy ? "Saving…" : "Save"}</button>
      </form>
    </div>,
    document.body
  ) : null;

  return <>
    <button className="btn ghost compact-add" onClick={() => setOpen(true)}>{label}</button>
    {sheet}
  </>;
}

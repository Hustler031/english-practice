"use client";

import { FormEvent, useEffect, useState } from "react";
import { rpc } from "@/lib/supabase";

const types = ["AUTO", "V", "SM", "OWS", "PV", "IP"];

export default function AddWordSheet({ questionId = "", initialWord = "", questionText = "", source = "Manual capture", label = "＋ Add Word" }: { questionId?: string; initialWord?: string; questionText?: string; source?: string; label?: string }) {
  const [open, setOpen] = useState(false);
  const [word, setWord] = useState(initialWord);
  const [type, setType] = useState("AUTO");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => { if (open) setWord(initialWord); }, [open, initialWord]);

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!word.trim()) return;
    setBusy(true); setMessage("");
    try {
      // Keep one visible capture box. When launched from a quiz, preserve the
      // encounter automatically through both the originating Question_ID and
      // its question text, matching the Apps Script capture behaviour.
      await rpc("english_save_word", { p_word: word.trim(), p_context: questionText.trim(), p_question_id: questionId, p_capture_type: type, p_module: "web-v2", p_source: source });
      setMessage("Saved");
      setTimeout(() => setOpen(false), 350);
    } catch (error: any) { setMessage(error.message || "Could not save"); }
    finally { setBusy(false); }
  }

  return <>
    <button className="btn ghost compact-add" onClick={() => setOpen(true)}>{label}</button>
    {open && <div className="sheet-backdrop" role="dialog" aria-modal="true" aria-label="Add word" onMouseDown={(e) => { if (e.target === e.currentTarget) setOpen(false); }}>
      <form className="add-word-sheet" onSubmit={save}>
        <div className="sheet-heading"><div><strong>Add Word</strong><span>Save a word, doubt or usage point for revision.</span></div><button className="control-icon" type="button" onClick={() => setOpen(false)} aria-label="Close">×</button></div>
        <input className="input" value={word} onChange={(e) => setWord(e.target.value)} placeholder="Word / doubt / usage point" required autoFocus />
        <div className="capture-types">{types.map((item) => <button className={`capture-type ${item === type ? "selected" : ""}`} type="button" key={item} onClick={() => setType(item)}>{item === "IP" ? "I/P" : item}</button>)}</div>
        {message && <div className="form-message">{message}</div>}
        <button className="btn primary sheet-save" disabled={busy}>{busy ? "Saving…" : "Save"}</button>
      </form>
    </div>}
  </>;
}

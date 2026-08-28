"use client";

import { FormEvent, useEffect, useState } from "react";
import { rpc } from "@/lib/supabase";

const types = ["AUTO", "V", "SM", "OWS", "PV", "IP"];

export default function AddWordSheet({ questionId = "", initialWord = "", source = "Manual capture", label = "＋ Add Word" }: { questionId?: string; initialWord?: string; source?: string; label?: string }) {
  const [open, setOpen] = useState(false);
  const [word, setWord] = useState(initialWord);
  const [context, setContext] = useState("");
  const [type, setType] = useState("AUTO");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => { if (open) setWord(initialWord); }, [open, initialWord]);

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!word.trim()) return;
    setBusy(true); setMessage("");
    try {
      await rpc("english_save_word", { p_word: word.trim(), p_context: context, p_question_id: questionId, p_capture_type: type, p_module: "web-v2", p_source: source });
      setMessage("Saved");
      setContext("");
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
        <input className="input" value={context} onChange={(e) => setContext(e.target.value)} placeholder="Context (optional)" />
        <div className="capture-types">{types.map((item) => <button className={`capture-type ${item === type ? "selected" : ""}`} type="button" key={item} onClick={() => setType(item)}>{item === "IP" ? "I/P" : item}</button>)}</div>
        {message && <div className="form-message">{message}</div>}
        <button className="btn primary sheet-save" disabled={busy}>{busy ? "Saving…" : "Save"}</button>
      </form>
    </div>}
  </>;
}

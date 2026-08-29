"use client";

import { FormEvent, useEffect, useRef, useState } from "react";
import { rpc } from "@/lib/supabase";

const types = ["AUTO", "V", "SM", "OWS", "PV", "IP"];

export default function AddWordSheet({ questionId = "", initialWord = "", questionText = "", source = "Manual capture", label = "＋ Add Word" }: { questionId?: string; initialWord?: string; questionText?: string; source?: string; label?: string }) {
  const [open, setOpen] = useState(false);
  const [word, setWord] = useState(initialWord);
  const [type, setType] = useState("AUTO");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const editorRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    setWord(initialWord);
    const frame = requestAnimationFrame(() => {
      const editor = editorRef.current;
      if (!editor) return;
      editor.textContent = initialWord;
      editor.focus();
      const selection = window.getSelection();
      if (selection) {
        const range = document.createRange();
        range.selectNodeContents(editor);
        range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
      }
    });
    return () => cancelAnimationFrame(frame);
  }, [open, initialWord]);

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
      <form className="add-word-sheet" onSubmit={save} autoComplete="off">
        <div className="sheet-heading"><div><strong>Add Word</strong><span>Save a word, doubt or usage point for revision.</span></div><button className="control-icon" type="button" onClick={() => setOpen(false)} aria-label="Close">×</button></div>
        <div style={{ position: "relative" }}>
          <div
            ref={editorRef}
            className="input"
            role="textbox"
            aria-label="Word, doubt or usage point"
            aria-multiline="false"
            contentEditable
            suppressContentEditableWarning
            inputMode="text"
            spellCheck={false}
            style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}
            onInput={(e) => setWord(e.currentTarget.textContent || "")}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                e.currentTarget.closest("form")?.requestSubmit();
              }
            }}
          />
          {!word && <span aria-hidden="true" style={{ position: "absolute", left: 12, top: "50%", transform: "translateY(-50%)", color: "var(--muted)", pointerEvents: "none" }}>Word / doubt / usage point</span>}
        </div>
        <div className="capture-types">{types.map((item) => <button className={`capture-type ${item === type ? "selected" : ""}`} type="button" key={item} onClick={() => setType(item)}>{item === "IP" ? "I/P" : item}</button>)}</div>
        {message && <div className="form-message">{message}</div>}
        <button className="btn primary sheet-save" disabled={busy || !word.trim()}>{busy ? "Saving…" : "Save"}</button>
      </form>
    </div>}
  </>;
}

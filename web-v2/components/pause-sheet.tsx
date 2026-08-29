"use client";

import { createPortal } from "react-dom";

export default function PauseSheet({open,onSave,onCancel}:{open:boolean;onSave:()=>void;onCancel:()=>void}){
  if(!open||typeof document==="undefined")return null;
  return createPortal(<div className="sheet-backdrop pause-backdrop" role="dialog" aria-modal="true" aria-label="Pause practice" onMouseDown={e=>{if(e.target===e.currentTarget)onCancel();}}><section className="pause-sheet"><div className="pause-icon">Ⅱ</div><div><h2>Pause practice?</h2><p>Your current question, answers and position are already kept on this device.</p></div><button className="btn primary full-width pause-save" type="button" onClick={onSave}>Save & Back</button><button className="btn ghost full-width" type="button" onClick={onCancel}>Continue Quiz</button></section></div>,document.body);
}

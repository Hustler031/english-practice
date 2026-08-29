export default function LearningSignalPill({ status }: { status?: string }) {
  const state = String(status || "").trim();
  if (!["Persistent Weak", "Weak", "Fragile"].includes(state)) return null;
  const cls = state === "Persistent Weak" ? "signal-persistent" : state === "Fragile" ? "signal-fragile" : "signal-weak";
  return <span className={`pill ${cls}`}>{state}</span>;
}

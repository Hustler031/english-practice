import LearningSignalPill from "@/components/learning-signal-pill";

export default function QuizMeta({ category, id, status, intelOpen, onInfo }: { category: string; id: string; status?: string; intelOpen: boolean; onInfo: () => void }) {
  return <div className="quiz-meta"><div className="quiz-meta-left"><span className="pill">{category}</span><span className="pill">{id}</span></div><div className="quiz-meta-right"><LearningSignalPill status={status}/><button className="intel-button" type="button" aria-label="Question intelligence" aria-expanded={intelOpen} onClick={onInfo}>ⓘ</button></div></div>;
}

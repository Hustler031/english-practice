import { rpc } from "@/lib/supabase";

export type RevisionPayload = {
  question: string;
  optionA: string;
  optionB: string;
  optionC: string;
  optionD: string;
  correctKey: string;
  explanation: string;
};

type RevisableQuestion = {
  id: string;
  question: string;
  options: { key: string; text: string }[];
  correctKey?: string;
  explanation?: string;
  revisionVersion?: number;
};

type AppliedRevision = {
  questionId: string;
  version: number;
  payload: RevisionPayload;
};

export async function applyActiveQuestionRevisions<T extends RevisableQuestion>(rows: T[]): Promise<T[]> {
  if (!rows.length) return rows;
  const ids = [...new Set(rows.map(row => String(row.id || "").trim()).filter(Boolean))].slice(0, 120);
  if (!ids.length) return rows;
  const result = await rpc<{ revisions?: AppliedRevision[] }>("english_get_applied_question_revisions", {
    p_question_ids: ids,
    p_cache_buster: Date.now(),
  });
  const revisions = Array.isArray(result?.revisions) ? result.revisions : [];
  const byQuestion = new Map(revisions.map(row => [String(row.questionId), row]));
  return rows.map(row => {
    const revision = byQuestion.get(String(row.id));
    const p = revision?.payload;
    if (!p) return row;
    const correctKey = String(p.correctKey || "").toUpperCase();
    if (!["A", "B", "C", "D"].includes(correctKey)) return row;
    return {
      ...row,
      question: String(p.question || row.question),
      options: [
        { key: "A", text: String(p.optionA || "") },
        { key: "B", text: String(p.optionB || "") },
        { key: "C", text: String(p.optionC || "") },
        { key: "D", text: String(p.optionD || "") },
      ],
      correctKey,
      explanation: String(p.explanation || row.explanation || ""),
      revisionVersion: Number(revision.version || 0) || undefined,
    } as T;
  });
}

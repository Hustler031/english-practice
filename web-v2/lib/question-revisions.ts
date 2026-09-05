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

export type AppliedRevision = {
  questionId: string;
  version: number;
  payload: RevisionPayload;
};

let activeRevisionCache: AppliedRevision[] | null = null;
let activeRevisionFetchedAt = 0;
let activeRevisionPromise: Promise<AppliedRevision[]> | null = null;
const ACTIVE_REVISION_TTL_MS = 10_000;

function refreshActiveQuestionRevisions(): Promise<AppliedRevision[]> {
  if (activeRevisionPromise) return activeRevisionPromise;
  activeRevisionPromise = rpc<{ revisions?: AppliedRevision[] }>("english_get_active_question_revisions")
    .then(result => {
      activeRevisionCache = Array.isArray(result?.revisions) ? result.revisions : [];
      activeRevisionFetchedAt = Date.now();
      return activeRevisionCache;
    })
    .finally(() => { activeRevisionPromise = null; });
  return activeRevisionPromise;
}

export async function fetchActiveQuestionRevisions(): Promise<AppliedRevision[]> {
  const fresh = activeRevisionCache !== null && Date.now() - activeRevisionFetchedAt < ACTIVE_REVISION_TTL_MS;
  if (fresh) return activeRevisionCache!;
  return refreshActiveQuestionRevisions();
}

export function invalidateActiveQuestionRevisions() {
  activeRevisionFetchedAt = 0;
}

export function applyQuestionRevisionList<T extends RevisableQuestion>(rows: T[], revisions: AppliedRevision[]): T[] {
  if (!rows.length || !revisions.length) return rows;
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

export async function applyActiveQuestionRevisions<T extends RevisableQuestion>(rows: T[]): Promise<T[]> {
  if (!rows.length) return rows;
  try {
    const revisions = await fetchActiveQuestionRevisions();
    return applyQuestionRevisionList(rows,revisions);
  } catch {
    return rows;
  }
}

// QuizRunner imports this module before its loader effect runs. Starting the tiny,
// owner-scoped overlay request here lets it overlap the main question-batch request
// instead of adding a second network round-trip after the batch has finished.
if (typeof window !== "undefined") void refreshActiveQuestionRevisions().catch(() => {});

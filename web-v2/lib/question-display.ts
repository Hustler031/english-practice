export type SentenceQuestionDisplay = {
  instruction: string;
  sentence: string;
};

const PROMPT_CUE = /\b(choose|select|complete|completion|fill|replace|identify|pick|find|which|sentence|usage|grammatically|semantically|correct|best|appropriate|context)\b/i;
const QUOTE_PAIRS: Array<[string, string]> = [["'", "'"], ['"', '"'], ["‘", "’"], ["“", "”"]];

/**
 * Split only high-confidence instruction + fully quoted sentence questions.
 * The canonical question stored in the bank remains untouched; this is display-only.
 */
export function splitSentenceQuestionForDisplay(raw: string): SentenceQuestionDisplay | null {
  const text = String(raw || "").trim();
  if (!text) return null;

  const colon = text.indexOf(":");
  if (colon < 5) return null;

  const instruction = text.slice(0, colon).trim().replace(/:\s*$/, "");
  const quoted = text.slice(colon + 1).trim();
  if (!instruction || !PROMPT_CUE.test(instruction)) return null;

  const pair = QUOTE_PAIRS.find(([open, close]) => quoted.startsWith(open) && quoted.endsWith(close));
  if (!pair) return null;

  const sentence = quoted.slice(pair[0].length, quoted.length - pair[1].length).trim();
  if (sentence.length < 12 || (!sentence.includes(" ") && !sentence.includes("___"))) return null;

  return { instruction, sentence };
}

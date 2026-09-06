export type SentenceQuestionDisplay = {
  instruction: string;
  sentence: string;
};

const PROMPT_CUE = /\b(choose|select|complete|completion|fill|replace|identify|pick|find|which|sentence|usage|grammatically|semantically|correct|best|appropriate|context)\b/i;
const QUOTE_PAIRS: Array<[string, string]> = [["'", "'"], ['"', '"'], ["‘", "’"], ["“", "”"]];
const VISIBLE_BLANK = /(?:_{2,}|□{1,8})/;

/**
 * Split high-confidence instruction + sentence questions for display only.
 * A fully quoted suffix is accepted directly. An unquoted suffix is accepted
 * only when it contains an explicit answer blank, preventing ordinary colon
 * questions from being reinterpreted as sentence prompts.
 * The canonical question stored in the bank remains untouched.
 */
export function splitSentenceQuestionForDisplay(raw: string): SentenceQuestionDisplay | null {
  const text = String(raw || "").trim();
  if (!text) return null;

  const colon = text.indexOf(":");
  if (colon < 5) return null;

  const instruction = text.slice(0, colon).trim().replace(/:\s*$/, "");
  const suffix = text.slice(colon + 1).trim();
  if (!instruction || !PROMPT_CUE.test(instruction) || !suffix) return null;

  const pair = QUOTE_PAIRS.find(([open, close]) => suffix.startsWith(open) && suffix.endsWith(close));
  const sentence = pair
    ? suffix.slice(pair[0].length, suffix.length - pair[1].length).trim()
    : VISIBLE_BLANK.test(suffix)
      ? suffix
      : "";

  if (sentence.length < 12 || !sentence.includes(" ")) return null;

  return { instruction, sentence };
}

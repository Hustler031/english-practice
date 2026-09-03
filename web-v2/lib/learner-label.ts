const generic = new Set([
  "phrasal verbs", "vocabulary", "grammar", "grammar & usage", "idioms & phrases",
  "one word substitution", "spelling", "english practice", "english question", "other",
]);

export type LearnerLabel = {
  displayName?: string;
  conceptName?: string;
  topic?: string;
};

export function cleanLearnerName(...values: Array<string | undefined | null>) {
  for (const value of values) {
    const name = String(value || "").replace(/\s+/g, " ").trim();
    if (name && !generic.has(name.toLowerCase())) return name;
  }
  return "English practice";
}

export function learnerName(label: LearnerLabel | undefined, fallback?: string) {
  return cleanLearnerName(label?.displayName, label?.conceptName, fallback);
}

export function confusionLabel(primary?: string, related?: string, fallback?: string) {
  const first = cleanLearnerName(primary);
  const second = cleanLearnerName(related);
  if (first !== "English practice" && second !== "English practice" && first.toLowerCase() !== second.toLowerCase()) return `${first} vs ${second}`;
  return cleanLearnerName(fallback, first, second);
}

export function learnerGroup(value?: string) {
  const raw = String(value || "").trim();
  const lower = raw.toLowerCase();
  if (lower.includes("phrasal")) return "Phrasal Verbs";
  if (lower.includes("idiom")) return "Idioms & Phrases";
  if (lower.includes("spell")) return "Spelling";
  if (lower.includes("grammar") || lower.includes("preposition") || lower.includes("error")) return "Grammar & Usage";
  if (lower.includes("one word")) return "One Word Substitution";
  if (lower.includes("vocab") || lower.includes("word")) return "Vocabulary";
  return "Other";
}

export const DAILY_ANALYSIS_CATEGORIES = [
  { key:"persistent_weak", title:"Persistent Weak", subtitle:"Repeated weakness still needs repair." },
  { key:"weak", title:"Weak", subtitle:"Repeated errors need focused review." },
  { key:"retention_risk", title:"Retention Risk", subtitle:"Previously learned, but recall is slipping." },
  { key:"fragile_learning", title:"Fragile / Learning", subtitle:"Still stabilising after recent practice." },
  { key:"due_revision", title:"Due Revision", subtitle:"Spaced review scheduled in Daily." },
] as const;

export const DAILY_ANALYSIS_RANGES = [
  { key:"today", label:"Today" },
  { key:"7d", label:"7 Days" },
  { key:"overall", label:"Overall" },
] as const;

export type DailyAnalysisCategory = typeof DAILY_ANALYSIS_CATEGORIES[number]["key"];
export type DailyAnalysisRange = typeof DAILY_ANALYSIS_RANGES[number]["key"];
export type DailyAnalysisSummary = {
  ok:boolean;
  date:string;
  relevantCount:number;
  attemptedToday:number;
  wrongToday:number;
  categories:Record<DailyAnalysisCategory,number>;
};

export type DailyAnalysisRow = {
  questionId:string;
  displayName:string;
  topic:string;
  currentState:string;
  dailyReason?:string;
  conceptState?:string;
  dailyDate?:string;
  daysSeen?:number;
  attemptsToday?:number;
  wrongToday?:number;
  periodAttempts?:number;
  periodWrong?:number;
  periodCorrect?:number;
  latestSelected?:string;
  latestCorrect?:boolean;
  lastAttempt?:string;
  totalAttempts:number;
  totalWrong:number;
  accuracy:number;
};

export type DailyAnalysisList = {ok:boolean;date:string;category:DailyAnalysisCategory;range?:DailyAnalysisRange;questions:DailyAnalysisRow[]};
export type DailyAnalysisAttempt = {attemptedAt:string;selected?:string;correct:boolean;module?:string;timeSeconds?:number};
export type DailyAnalysisAttemptSummary = {
  range:DailyAnalysisRange;
  total:number;
  correct:number;
  wrong:number;
  shown:number;
  shownCorrect:number;
  shownWrong:number;
  truncated:boolean;
};
export type DailyAnalysisQuestionPayload = {
  id:string;category?:string;topic?:string;subtopic?:string;word?:string;question:string;
  options:Array<{key:string;text:string}>;correctKey:string;explanation?:string;tip?:string;usageNote?:string;
  example?:string;memoryAid?:string;related?:string;revisionApplied?:boolean;
};
export type DailyAnalysisDetail = {
  ok:boolean;date:string;category:DailyAnalysisCategory;range?:DailyAnalysisRange;analysis:DailyAnalysisRow;
  question:DailyAnalysisQuestionPayload;recentAttempts:DailyAnalysisAttempt[];attemptSummary?:DailyAnalysisAttemptSummary;
};

export function categoryMeta(key:string){return DAILY_ANALYSIS_CATEGORIES.find(x=>x.key===key)}
export function isDailyAnalysisCategory(key:string):key is DailyAnalysisCategory{return !!categoryMeta(key)}
export function isDailyAnalysisRange(key:string):key is DailyAnalysisRange{return DAILY_ANALYSIS_RANGES.some(x=>x.key===key)}
export function rangeLabel(key:DailyAnalysisRange){return DAILY_ANALYSIS_RANGES.find(x=>x.key===key)?.label||"Today"}

export function dailyAnalysisRowNote(row:DailyAnalysisRow,range:DailyAnalysisRange="today"){
  const attempts=row.periodAttempts??row.attemptsToday??0;
  const wrong=row.periodWrong??row.wrongToday??0;
  const correct=row.periodCorrect??Math.max(0,attempts-wrong);
  if(attempts>0){
    if(range==="today")return wrong>0?`${wrong} wrong today · ${row.totalWrong} wrong overall`:`Correct today · ${row.totalAttempts} total attempts`;
    return `${correct} correct · ${wrong} wrong · ${attempts} attempts`;
  }
  if(range!=="today"&&row.daysSeen)return `${row.daysSeen} Daily day${row.daysSeen===1?"":"s"} · no attempts in this period`;
  return row.dailyReason?`Planned today · ${row.dailyReason}`:"Planned in today’s Daily";
}

export function stateLabel(value?:string){
  const x=String(value||"").trim();
  if(!x)return"New";
  if(x==="retention_risk")return"Retention Risk";
  return x.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase());
}

export function formatAttemptTime(value?:string){
  if(!value)return"";
  try{return new Intl.DateTimeFormat("en-IN",{timeZone:"Asia/Kolkata",day:"numeric",month:"short",hour:"numeric",minute:"2-digit"}).format(new Date(value))}catch{return""}
}

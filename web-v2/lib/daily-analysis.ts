export const DAILY_ANALYSIS_CATEGORIES = [
  { key:"persistent_weak", title:"Persistent Weak", subtitle:"Repeated weakness still needs repair." },
  { key:"weak", title:"Weak", subtitle:"Repeated errors need focused review." },
  { key:"retention_risk", title:"Retention Risk", subtitle:"Previously learned, but recall is slipping." },
  { key:"fragile_learning", title:"Fragile / Learning", subtitle:"Still stabilising after recent practice." },
  { key:"due_revision", title:"Due Revision", subtitle:"Spaced review scheduled in today’s Daily." },
] as const;

export type DailyAnalysisCategory = typeof DAILY_ANALYSIS_CATEGORIES[number]["key"];
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
  attemptsToday:number;
  wrongToday:number;
  latestSelected?:string;
  latestCorrect?:boolean;
  lastAttempt?:string;
  totalAttempts:number;
  totalWrong:number;
  accuracy:number;
};

export type DailyAnalysisList = {ok:boolean;date:string;category:DailyAnalysisCategory;questions:DailyAnalysisRow[]};
export type DailyAnalysisAttempt = {attemptedAt:string;selected?:string;correct:boolean;module?:string;timeSeconds?:number};
export type DailyAnalysisQuestionPayload = {
  id:string;category?:string;topic?:string;subtopic?:string;word?:string;question:string;
  options:Array<{key:string;text:string}>;correctKey:string;explanation?:string;tip?:string;usageNote?:string;
  example?:string;memoryAid?:string;related?:string;revisionApplied?:boolean;
};
export type DailyAnalysisDetail = {
  ok:boolean;date:string;category:DailyAnalysisCategory;analysis:DailyAnalysisRow;
  question:DailyAnalysisQuestionPayload;recentAttempts:DailyAnalysisAttempt[];
};

export function categoryMeta(key:string){return DAILY_ANALYSIS_CATEGORIES.find(x=>x.key===key)}
export function isDailyAnalysisCategory(key:string):key is DailyAnalysisCategory{return !!categoryMeta(key)}

export function dailyAnalysisRowNote(row:DailyAnalysisRow){
  if(row.attemptsToday>0){
    if(row.wrongToday>0)return `${row.wrongToday} wrong today · ${row.totalWrong} wrong overall`;
    return `Correct today · ${row.totalAttempts} total attempts`;
  }
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
  try{return new Intl.DateTimeFormat("en-IN",{timeZone:"Asia/Kolkata",hour:"numeric",minute:"2-digit"}).format(new Date(value))}catch{return""}
}

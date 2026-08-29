export type GkLane="MAIN"|"RAPID"|"MIXED";
export type GkOption={key:string;text:string};
export type GkQuestionState={
 attempts?:number;correct?:number;wrong?:number;accuracy?:number;status?:string;learningState?:string;
 firstAttemptCorrect?:boolean|null;retentionAttempts?:number;retentionCorrect?:number;retentionWrong?:number;retentionAccuracy?:number;
 recentSpacedFailures?:number;lastAttempt?:string|null;lastSpacedAttempt?:string|null;lastMeaningfulResult?:string;latestResult?:string;
 nextReview?:string|null;due?:boolean;starred?:boolean;starredAt?:string|null;difficult?:boolean;guessedAttempts?:number;
 unconfirmedGuess?:boolean;lastGuessAt?:string|null;confirmedUnguessedSpacedRecalls?:number;exposureCount?:number;
 firstSeen?:string|null;lastSeen?:string|null;flagged?:boolean;flagReason?:string;note?:string;
};
export type GkQuestion={
 id:string;question_id?:string;question:string;correctKey:string;options:GkOption[];content_lane?:string;content_type?:string;
 subject?:string;topic?:string;chapter?:string;subtopic?:string;concept_id?:string;lecture_key?:string;lecture_no?:number|string;
 library_key?:string;source_label?:string;source_date?:string;difficulty?:string;explanation?:string;trick?:string;related_fact?:string;exam_trap?:string;
 state?:GkQuestionState;
};
export type GkSummary={
 total:number;eligibleTotal:number;eligibleMain:number;eligibleRapidRecall:number;exposed:number;bankExposure:number;
 persistentWeak:number;weak:number;fragile:number;strong:number;provenMastered:number;due:number;starred:number;difficult:number;guessed:number;
 firstAttemptAccuracy:number;retentionAccuracy:number;newQuestions:number;
};
export type GkHomeSnapshot={ok:boolean;summary:GkSummary;resume?:{session_id?:string;sessionId?:string;title?:string;mode?:string;position_index?:number;current_index?:number}|null};
export type GkLibrary={key:string;title:string;icon:string;lectures:number;questions:number};
export type GkLecture={libraryKey:string;lectureKey:string;lectureNo:number|string|null;title:string;sourceDate?:string;total:number;main:number;rapidRecall:number;attempted:number;weak:number};
export type GkTopic={topic:string;total:number;main:number;rapidRecall:number;weak:number};
export type GkSubject={subject:string;total:number;main:number;rapidRecall:number;weak:number;topics:GkTopic[]};
export type GkCurrentCategory={category:string;count:number;minDate?:string;maxDate?:string};
export type GkDemandSet={demandId:string;title:string;kind?:string;count:number;lastUsed?:string};
export type GkCatalog={ok:boolean;libraries:GkLibrary[];lectures:GkLecture[];subjects:GkSubject[];currentAffairs:GkCurrentCategory[];demandSets:GkDemandSet[]};
export type GkStarredGroup={label:string;ageFrom:number;ageTo:number;count:number;health:{persistentWeak:number;weakFragile:number;due:number;difficult:number;healthy:number}};
export type GkStarredHub={ok:boolean;summary:{starred:number;focus:number;difficult:number;mastered:number;due:number;never_revised:number};groups:GkStarredGroup[]};
export type GkDemandWeakTopic={concept_id:string;subject:string;topic:string;persistent_weak:number;weak:number;retention_accuracy:number};
export type GkOnDemandHub={ok:boolean;stats:{weak:number;guessed:number;difficult:number;longUnseen:number};weakTopics:GkDemandWeakTopic[];myDemandSets:GkDemandSet[]};
export type GkProgress={
 ok:boolean;overview:Record<string,number>;knowledgeHealth:Array<{state:string;count:number}>;
 subjectMastery:Array<{subject:string;total:number;exposed:number;weak:number;mastered:number;retentionAccuracy:number}>;
 weakConcepts:Array<{conceptId:string;subject:string;topic:string;total:number;attempted:number;persistentWeak:number;weak:number;mastered:number;guessed:number;retentionAccuracy:number}>;
 currentAffairsHealth:Array<Record<string,number|string>>;starredHealth:Record<string,number>;guessedHealth:Record<string,number>;
 difficultResolution:Record<string,number>;lectureCoverage:Array<{lecture_key:string;title:string;total:number;exposed:number;weak:number;mastered:number}>;
};

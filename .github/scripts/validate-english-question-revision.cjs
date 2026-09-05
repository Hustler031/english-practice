// Final branch-head contract gate for question repair, SSC toughness, related practice, and learner-facing study UI.
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const base=read('supabase/managed-migrations/20260902150000_english_question_revision_proposals.sql');
const integrity=read('supabase/managed-migrations/20260902151000_english_question_revision_integrity.sql');
const quality=read('supabase/managed-migrations/20260902153000_english_question_quality_intelligence.sql');
const hardening=read('supabase/managed-migrations/20260902154000_english_revision_transfer_quality_hardening.sql');
const uiSupport=read('supabase/managed-migrations/20260902161000_english_learning_insights_ui_support.sql');
const auditFix=read('supabase/managed-migrations/20260902162000_english_predeploy_question_ui_audit_fixes.sql');
const aiInsights=read('supabase/managed-migrations/20260905183500_english_learning_ai_updates.sql');
const speedFix=read('supabase/managed-migrations/20260905190000_english_starred_diversity_and_quiz_speed.sql');
const dailyAnalysisMigration=read('supabase/managed-migrations/20260905195500_english_daily_analysis_readonly.sql');
const dailyAnalysisScope=read('supabase/managed-migrations/20260905200500_english_daily_analysis_daily_scope.sql');
const migration=[base,integrity,quality,hardening,uiSupport,auditFix,aiInsights,speedFix,dailyAnalysisMigration,dailyAnalysisScope].join('\n');
const contextWorker=read('supabase/functions/english-context-worker/index.ts');
const revisionWorker=read('supabase/functions/english-revision-worker/index.ts');
const ui=read('web-v2/components/question-revision-actions.tsx');
const runner=read('web-v2/components/quiz-runner.tsx');
const overlay=read('web-v2/lib/question-revisions.ts');
const aiUpdates=read('web-v2/lib/learning-ai-updates.ts');
const dailyAnalysisLib=read('web-v2/lib/daily-analysis.ts');
const home=read('web-v2/app/english/page.tsx');
const practice=read('web-v2/app/english/practice/page.tsx');
const revision=read('web-v2/app/english/revision/page.tsx');
const targeted=read('web-v2/app/english/targeted/page.tsx');
const insights=read('web-v2/app/english/revision/ai-intelligence/page.tsx');
const insightContext=read('web-v2/app/english/revision/ai-intelligence/context/page.tsx');
const insightImprovements=read('web-v2/app/english/revision/ai-intelligence/improvements/page.tsx');
const dailyAnalysis=read('web-v2/app/english/revision/ai-intelligence/daily-analysis/page.tsx');
const dailyAnalysisCategory=read('web-v2/app/english/revision/ai-intelligence/daily-analysis/questions/page.tsx');
const dailyAnalysisDetail=read('web-v2/app/english/revision/ai-intelligence/daily-analysis/review/page.tsx');
const daily=read('web-v2/app/english/daily/page.tsx');
const hindu=read('web-v2/app/english/hindu/page.tsx');
const frame=read('web-v2/components/english-frame.tsx');
const finalCss=read('web-v2/app/learning-insights-final-ui.css');
const aiInsightsCss=read('web-v2/app/learning-insights-ai-only.css');
const dailyAnalysisCss=read('web-v2/app/daily-analysis.css');
const learnerUi=read('web-v2/components/learner-ui.tsx');
const learnerLabels=read('web-v2/lib/learner-label.ts');
const learnerCss=read('web-v2/app/english-learner-rebuild.css');
function requireText(text,needle,label){if(!text.includes(needle))throw new Error(`${label}: missing ${needle}`);}
function forbid(text,re,label){if(re.test(text))throw new Error(`${label}: forbidden pattern ${re}`);}
[
 ['question_revision_proposals','versioned proposal table'],['user_question_revisions','active user overlay'],
 ['pg_advisory_xact_lock','concurrent request serialization'],['english_request_question_revision','request RPC'],
 ['english_get_question_revision_state','live state RPC'],['english_get_applied_question_revisions','applied overlay RPC'],
 ['english_use_question_revision','explicit apply RPC'],['english_keep_question_revision','keep-current RPC'],
 ['question_revision_claim','worker claim'],['apply_question_revision_result','critic-gated result'],['fail_question_revision','bounded failure path'],
 ['question_quality_metrics','learner-specific difficulty calibration'],['question_distractor_metrics','distractor evidence ledger'],
 ['revision_strategy_stats','revision outcome learning'],['confusable_clusters','confusable-cluster memory'],
 ['question_generation_provenance','generation provenance'],['worker_observability','worker telemetry'],
 ['question_quality_reviews','canonical quality-review queue'],['english_request_question_quality_review','doubtful-answer review RPC'],
 ['english_request_related_practice','explicit related-practice RPC'],['targeted_exit_evaluation','measurable Targeted exit contract'],
 ['question stem changed during a repair-only revision','repair-only stem invariant'],
 ['correct option changed during a repair-only revision','repair-only correct-option invariant'],
 ['explanation-only revision changed options','explanation-only invariant'],['revision failed SSC toughness gate','SSC revision gate'],
 ['bank_references','bank references instead of bank replacement'],["'newQuestionAllowed',false",'revision cannot silently create a new question'],
 ['text_token_jaccard','near-duplicate guard'],['generated transfer failed SSC quality gate','generated-transfer quality gate'],
 ['english_get_question_labels','learner-facing question-label RPC'],['english_get_targeted_question','exact targeted-question RPC'],
 ['english_get_targeted_due_session','Targeted due-only learner session'],['observed_difficulty','bank candidate difficulty evidence'],
 ["in ('hard','difficult','advanced')",'hard bank suitability gate'],['confusableTerms','explicit related-practice anchor terms'],
 ['english_get_learning_ai_updates','AI-only Learning Insights RPC'],['learner_context_notes','context evidence feed'],
 ['question_revision_proposals','revision outcome feed'],["status in ('ready','applied','kept')",'only quality-approved revision payloads are learner-visible'],
 ['starred_diversify_payload','Starred category diversity'],['daily_satisfied_concepts','set-based Daily satisfaction read'],
 ['english_get_active_question_revisions','parallel quiz revision feed'],
 ['daily_analysis_base','Daily Analysis owner-scoped base'],['english_get_daily_analysis_summary','Daily Analysis summary RPC'],
 ['english_get_daily_analysis_questions','Daily Analysis list RPC'],['english_get_daily_analysis_question','Daily Analysis detail RPC'],
 ["quiz_date=p.today",'Daily Analysis is scoped to today Daily plan'],["'Due Spaced Revision'",'Daily Analysis due category'],
 ["'retention_risk'",'Daily Analysis retention-risk evidence']
].forEach(([needle,label])=>requireText(migration,needle,label));
forbid(migration,/update\s+english\.questions\b/i,'canonical question immutability');
forbid(migration,/delete\s+from\s+english\.attempts\b/i,'attempt preservation');
forbid(migration,/update\s+english\.question_state\b/i,'mastery preservation');
[
 ['transferGeneratePrompt','strong transfer generator'],['transferCriticPrompt','independent transfer critic'],
 ['semanticNoveltyScore','semantic novelty gate'],['realisticTrapCount','real trap gate']
].forEach(([needle,label])=>requireText(contextWorker,needle,label));
[
 ['revisionGeneratePrompt','intent-aware revision generator'],['revisionCriticPrompt','independent revision critic'],
 ['qualityReviewPrompt','canonical-answer review critic'],['sscDifficultyFit','SSC difficulty fit gate'],
 ['distractorCloseness','distractor closeness gate'],['obviousElimination','obvious-elimination rejection'],
 ['bankReferences','bank reference path'],['bank_informed_ai','bank-informed generation source'],
 ['english_apply_question_revision_result','atomic revision result RPC'],['english_apply_question_quality_review_result','review result RPC'],
 ['english_log_worker_metrics','worker observability'],['english_question_revision_claim_dedicated','dedicated revision claim']
].forEach(([needle,label])=>requireText(revisionWorker,needle,label));
forbid(revisionWorker,/function\s+bankRevisionDraft/i,'bank question must not replace the current question');
forbid(contextWorker,/english_question_revision_claim\b/,'context worker must not claim revision jobs');
forbid(contextWorker,/english_question_quality_review_claim/,'context worker must not claim quality-review jobs');
[
 ['Options too obvious','feedback reason'],['Distractors are unrelated','feedback reason'],['Explanation is weak','feedback reason'],
 ['Correct answer looks doubtful','canonical review wording'],['Write your own note','custom feedback'],
 ['looksLikeRelatedPractice','custom-note related-practice intent'],['english_request_related_practice','related-practice backend route'],
 ['Related practice: …','related-practice learner hint'],['Revision proposal ready','ready state'],['Preview','preview action'],
 ['Use revised version','explicit apply action'],['Keep current','keep action'],['setInterval','continuous background-ready polling'],
 ['The question stem and correct answer stay the same','repair-only learner contract']
].forEach(([needle,label])=>requireText(ui,needle,label));
forbid(ui,/onClick=.*Related practice<\/button>/i,'no fourth visible question action');
requireText(runner,'applyActiveQuestionRevisions','future-session overlay');
requireText(runner,'QuestionRevisionActions','question-screen action');
requireText(overlay,'english_get_active_question_revisions','parallel active overlay feed');
requireText(overlay,'refreshActiveQuestionRevisions','overlay prefetch before quiz loader resolves');
requireText(overlay,'ACTIVE_REVISION_TTL_MS','bounded overlay freshness');

[
 [home,'Targeted Mastery','Home keeps Targeted access in Quick Start'],
 [practice,'Daily Practice','Practice Daily'],[practice,'Targeted Mastery','Practice Targeted'],[practice,'Fast Track','Practice Fast Track'],[practice,'New Practice','Practice New'],[practice,'Topic Practice','Practice Topic'],[practice,'Exam Sprint','Practice Exam Sprint'],
 [revision,'Due Now','Revision due'],[revision,'Difficult &amp; Incorrect','Revision difficult/incorrect'],[revision,'Starred','Revision starred'],[revision,'My Saved','Revision saved'],[revision,'Browse by Topic','Revision topic'],[revision,'Learning Insights','Revision insights'],
 [targeted,'Fix Now','Targeted Fix Now'],[targeted,'Your Confusions','Targeted confusions'],[targeted,'Waiting for Later','Targeted waiting'],[targeted,'OverviewCard','Targeted progressive-disclosure overview'],[targeted,'LearnerRow','Targeted learner rows'],[targeted,'english_get_question_labels','Targeted display labels'],[targeted,'english_get_targeted_question','Targeted exact question'],[targeted,'english_get_targeted_due_session','Targeted Fix Now uses due-only session'],[targeted,'"due_now"','Targeted due-only UI kind'],
 [insights,'Learning Insights','Learning Insights title'],[insights,'english_get_learning_ai_updates','Insights summary reads actual AI outcomes'],[insights,'What AI understood','context drill-down card'],[insights,'Question improvements','revision drill-down card'],[insights,'/ai-intelligence/context','context route'],[insights,'/ai-intelligence/improvements','improvement route'],[insights,'Background AI health','collapsed operational health'],[insights,'ai-hub-card','uncramped hub cards'],[insights,'Daily Analysis','Daily Analysis launch'],[insights,'/ai-intelligence/daily-analysis','Daily Analysis route'],[insights,'english_get_daily_analysis_summary','Daily Analysis count'],
 [insightContext,'Only questions where you added context.','context-only list'],[insightContext,'What you told AI','context detail'],[insightContext,'What AI understood','context interpretation'],[insightContext,'What changed','context effect'],
 [insightImprovements,'Only questions you asked AI to improve.','improvement-only list'],[insightImprovements,'Original version','revision before'],[insightImprovements,'AI revision','revision after'],[insightImprovements,'What changed','revision delta'],
 [dailyAnalysis,'Today only','Daily Analysis today-only scope'],[dailyAnalysis,'DAILY_ANALYSIS_CATEGORIES','five Daily Analysis rows'],[dailyAnalysis,'Read-only review','read-only learner contract'],[dailyAnalysis,'english_get_daily_analysis_summary','Daily Analysis summary fetch'],
 [dailyAnalysisCategory,'english_get_daily_analysis_questions','category question list'],[dailyAnalysisCategory,'daily-analysis-question-row','Manage-like question rows'],[dailyAnalysisCategory,'encodeURIComponent(row.questionId)','question drill-down link'],
 [dailyAnalysisDetail,'english_get_daily_analysis_question','read-only detail RPC'],[dailyAnalysisDetail,'Correct answer is shown','manual weakness-review contract'],[dailyAnalysisDetail,'Recent attempts','attempt evidence'],[dailyAnalysisDetail,'Review only · nothing is recorded here','no-write learner copy'],
 [dailyAnalysisLib,'persistent_weak','Persistent Weak config'],[dailyAnalysisLib,'retention_risk','Retention Risk config'],[dailyAnalysisLib,'fragile_learning','Fragile/Learning config'],[dailyAnalysisLib,'due_revision','Due Revision config'],
 [daily,'QuestionRevisionActions','Daily Improve Question action'],[daily,'english_get_applied_question_revisions','Daily applied revision overlay'],[daily,'I Guessed','Daily confidence signal'],[daily,'Add Context','Daily context signal'],
 [hindu,'QuestionRevisionActions','Hindu Improve Question action'],[hindu,'english_get_applied_question_revisions','Hindu applied revision overlay'],[hindu,'english_record_guess','Hindu confidence signal'],[hindu,'english_save_context_note','Hindu context signal'],
 [frame,'targeted|fast-track|exam','Practice nav routing'],[frame,'pathname.startsWith("/english/revision/")','Revision nav routing'],
 [learnerUi,'learner-overview-card','shared overview-card primitive'],[learnerUi,'learner-row','shared learner-row primitive'],[learnerLabels,'confusionLabel','learner confusion label resolver'],[learnerLabels,'cleanLearnerName','generic-label guard'],[learnerCss,'.learner-overview-card','new learner overview styling'],[learnerCss,'.learner-row','new learner row styling'],[learnerCss,'.practice-primary-card','Practice learner-card harmony'],[learnerCss,'.revision-primary-row','Revision learner-row harmony'],
 [finalCss,'.next-best-action-card','legacy next-action styling remains harmless'],[finalCss,'grid-template-columns:repeat(3','three question actions layout'],
 [aiInsightsCss,'.ai-hub-grid','compact Insights hub'],[aiInsightsCss,'.ai-focused-item','focused question list'],[aiInsightsCss,'.ai-option-line.changed','changed-option styling'],[dailyAnalysisCss,'.ai-daily-analysis-launch','Daily Analysis hub row styling'],[dailyAnalysisCss,'.daily-review-option.correct','visible correct-answer styling'],
 [aiUpdates,'revisionChangeText','shared revision delta formatter'],[aiUpdates,'contextChanges','shared context-action formatter']
].forEach(([text,needle,label])=>requireText(text,needle,label));
forbid(home,/Next Best Action/,'Home stays clean: no Next Best Action card');
forbid(home,/next-best-action-card/,'Home stays clean: no next-action card markup');
forbid(home,/targeted\?\.retentionChecks\?/,'Home must not recommend future retention merely because it exists');
forbid(insights,/Concept coverage/i,'Insights must not expose concept dashboard');
forbid(insights,/Total Concepts/i,'Insights must not expose total-concepts dashboard');
forbid(insights,/Check Soon/i,'Insights must not duplicate Targeted scheduling');
forbid(insights,/Scheduled for Later/i,'Insights must not duplicate Targeted scheduling');
for(const page of [insights,insightContext,insightImprovements])forbid(page,/\{item\.questionId\}/,'no raw question IDs on Insights surface');
for(const page of [dailyAnalysis,dailyAnalysisCategory,dailyAnalysisDetail]){
 forbid(page,/english_submit_answer|english_mark_|english_set_|english_save_context_note|english_record_guess/,'Daily Analysis stays read-only');
}
forbid(targeted,/Question IDs are visible/i,'no developer audit copy in Targeted');
forbid(targeted,/Open\s*›/i,'no redundant Targeted Open affordance');
forbid(targeted,/Practice\s*›/i,'no redundant Targeted Practice affordance');

for(const [name,text] of [['base migration',base],['integrity migration',integrity],['quality migration',quality],['hardening migration',hardening],['UI support migration',uiSupport],['audit fix migration',auditFix],['AI Insights migration',aiInsights],['speed migration',speedFix],['Daily Analysis migration',dailyAnalysisMigration],['Daily Analysis scope migration',dailyAnalysisScope]]){
 const dollars=(text.match(/\$\$/g)||[]).length;if(dollars%2)throw new Error(`${name}: unbalanced $$ function delimiters`);
}
try{
 const ts=require(path.join(root,'web-v2/node_modules/typescript'));
 for(const [name,source,jsx] of [['context worker',contextWorker,false],['revision worker',revisionWorker,false],['revision ui',ui,true],['overlay',overlay,false],['AI update helpers',aiUpdates,false],['Daily Analysis helpers',dailyAnalysisLib,false],['targeted page',targeted,true],['learning insights',insights,true],['context insights',insightContext,true],['improvement insights',insightImprovements,true],['Daily Analysis',dailyAnalysis,true],['Daily Analysis category',dailyAnalysisCategory,true],['Daily Analysis detail',dailyAnalysisDetail,true],['learner ui',learnerUi,true],['learner labels',learnerLabels,false],['home',home,true],['practice',practice,true],['revision',revision,true],['daily',daily,true],['hindu',hindu,true],['frame',frame,true]]){
  const out=ts.transpileModule(source,{reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,jsx:jsx?ts.JsxEmit.ReactJSX:ts.JsxEmit.Preserve}});
  const bad=(out.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
  if(bad.length)throw new Error(`${name}: TypeScript parse error ${bad.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; ')}`);
 }
}catch(e){if(/Cannot find module/.test(String(e)))console.warn('TypeScript parser unavailable; web typecheck will cover frontend syntax.');else throw e;}
console.log('English question revision + quality + learner UI contracts: OK');

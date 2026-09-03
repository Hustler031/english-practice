// Final branch-head contract gate for question repair, SSC toughness, related practice, and learner-facing study UI.
// This file is intentionally touched after the documentation audit so CI validates the exact release-candidate head.
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
const migration=[base,integrity,quality,hardening,uiSupport,auditFix].join('\n');
const worker=read('supabase/functions/english-context-worker/index.ts');
const ui=read('web-v2/components/question-revision-actions.tsx');
const runner=read('web-v2/components/quiz-runner.tsx');
const overlay=read('web-v2/lib/question-revisions.ts');
const home=read('web-v2/app/english/page.tsx');
const practice=read('web-v2/app/english/practice/page.tsx');
const revision=read('web-v2/app/english/revision/page.tsx');
const targeted=read('web-v2/app/english/targeted/page.tsx');
const insights=read('web-v2/app/english/revision/ai-intelligence/page.tsx');
const daily=read('web-v2/app/english/daily/page.tsx');
const hindu=read('web-v2/app/english/hindu/page.tsx');
const frame=read('web-v2/components/english-frame.tsx');
const finalCss=read('web-v2/app/learning-insights-final-ui.css');
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
 ["in ('hard','difficult','advanced')",'hard bank suitability gate'],['confusableTerms','explicit related-practice anchor terms']
].forEach(([needle,label])=>requireText(migration,needle,label));
forbid(migration,/update\s+english\.questions\b/i,'canonical question immutability');
forbid(migration,/delete\s+from\s+english\.attempts\b/i,'attempt preservation');
forbid(migration,/update\s+english\.question_state\b/i,'mastery preservation');
[
 ['transferGeneratePrompt','strong transfer generator'],['transferCriticPrompt','independent transfer critic'],
 ['revisionGeneratePrompt','intent-aware revision generator'],['revisionCriticPrompt','independent revision critic'],
 ['qualityReviewPrompt','canonical-answer review critic'],['sscDifficultyFit','SSC difficulty fit gate'],
 ['distractorCloseness','distractor closeness gate'],['obviousElimination','obvious-elimination rejection'],
 ['semanticNoveltyScore','semantic novelty gate'],['realisticTrapCount','real trap gate'],
 ['bankReferences','bank reference path'],['bank_informed_ai','bank-informed generation source'],
 ['english_apply_question_revision_result','atomic revision result RPC'],['english_apply_question_quality_review_result','review result RPC'],
 ['english_log_worker_metrics','worker observability'],['if (transferClaimed > 0)','transfer lane priority']
].forEach(([needle,label])=>requireText(worker,needle,label));
forbid(worker,/function\s+bankRevisionDraft/i,'bank question must not replace the current question');
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
requireText(overlay,'questionId','same canonical id overlay');
requireText(overlay,'p_cache_buster: Date.now()','live applied-revision read');

[
 [home,'Next Best Action','Home next-best action'],[home,'Start focused practice','Home focused CTA'],[home,'targetedDue>0','Home Targeted recommendation is due-gated'],
 [practice,'Daily Practice','Practice Daily'],[practice,'Targeted Mastery','Practice Targeted'],[practice,'Fast Track','Practice Fast Track'],[practice,'New Practice','Practice New'],[practice,'Topic Practice','Practice Topic'],[practice,'Exam Sprint','Practice Exam Sprint'],
 [revision,'Due Now','Revision due'],[revision,'Difficult &amp; Incorrect','Revision difficult/incorrect'],[revision,'Starred','Revision starred'],[revision,'My Saved','Revision saved'],[revision,'Browse by Topic','Revision topic'],[revision,'Learning Insights','Revision insights'],
 [targeted,'Fix Now','Targeted Fix Now'],[targeted,'Your Confusions','Targeted confusions'],[targeted,'Waiting for Later','Targeted waiting'],[targeted,'OverviewCard','Targeted progressive-disclosure overview'],[targeted,'LearnerRow','Targeted learner rows'],[targeted,'english_get_question_labels','Targeted display labels'],[targeted,'english_get_targeted_question','Targeted exact question'],[targeted,'english_get_targeted_due_session','Targeted Fix Now uses due-only session'],[targeted,'"due_now"','Targeted due-only UI kind'],
 [insights,'Learning Insights','Learning Insights title'],[insights,'Today','Today overview'],[insights,'See what changed in your learning plan.','Today learner copy'],[insights,'Fix Now','Insights Fix Now'],[insights,'Check Soon','Insights Check Soon'],[insights,'Improving','Insights Improving'],[insights,'Scheduled for Later','Insights scheduled'],[insights,'How your learning plan works','Learning-plan explainer'],[insights,'learnerName','Today uses learner-facing names'],[insights,'OverviewCard','Insights progressive-disclosure overview'],[insights,'LearnerRow','Insights learner rows'],
 [daily,'QuestionRevisionActions','Daily Improve Question action'],[daily,'english_get_applied_question_revisions','Daily applied revision overlay'],[daily,'I Guessed','Daily confidence signal'],[daily,'Add Context','Daily context signal'],
 [hindu,'QuestionRevisionActions','Hindu Improve Question action'],[hindu,'english_get_applied_question_revisions','Hindu applied revision overlay'],[hindu,'english_record_guess','Hindu confidence signal'],[hindu,'english_save_context_note','Hindu context signal'],
 [frame,'targeted|fast-track|exam','Practice nav routing'],[frame,'pathname.startsWith("/english/revision/")','Revision nav routing'],
 [learnerUi,'learner-overview-card','shared overview-card primitive'],[learnerUi,'learner-row','shared learner-row primitive'],[learnerLabels,'confusionLabel','learner confusion label resolver'],[learnerLabels,'cleanLearnerName','generic-label guard'],[learnerCss,'.learner-overview-card','new learner overview styling'],[learnerCss,'.learner-row','new learner row styling'],[learnerCss,'.practice-primary-card','Practice learner-card harmony'],[learnerCss,'.revision-primary-row','Revision learner-row harmony'],
 [finalCss,'.next-best-action-card','Home next action UI'],[finalCss,'grid-template-columns:repeat(3','three question actions layout']
].forEach(([text,needle,label])=>requireText(text,needle,label));
forbid(home,/targeted\?\.retentionChecks\?/,'Home must not recommend future retention merely because it exists');
forbid(insights,/\{item\.questionId\}/,'no question IDs on Today surface');
forbid(targeted,/Question IDs are visible/i,'no developer audit copy in Targeted');
forbid(targeted,/Open\s*›/i,'no redundant Targeted Open affordance');
forbid(targeted,/Practice\s*›/i,'no redundant Targeted Practice affordance');
forbid(insights,/Open\s*›/i,'no redundant Insights Open affordance');
forbid(insights,/Practice\s*›/i,'no redundant Insights Practice affordance');

for(const [name,text] of [['base migration',base],['integrity migration',integrity],['quality migration',quality],['hardening migration',hardening],['UI support migration',uiSupport],['audit fix migration',auditFix]]){
 const dollars=(text.match(/\$\$/g)||[]).length;if(dollars%2)throw new Error(`${name}: unbalanced $$ function delimiters`);
}
try{
 const ts=require(path.join(root,'web-v2/node_modules/typescript'));
 for(const [name,source,jsx] of [['worker',worker,false],['revision ui',ui,true],['overlay',overlay,false],['targeted page',targeted,true],['learning insights',insights,true],['learner ui',learnerUi,true],['learner labels',learnerLabels,false],['home',home,true],['practice',practice,true],['revision',revision,true],['daily',daily,true],['hindu',hindu,true],['frame',frame,true]]){
  const out=ts.transpileModule(source,{reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,jsx:jsx?ts.JsxEmit.ReactJSX:ts.JsxEmit.Preserve}});
  const bad=(out.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
  if(bad.length)throw new Error(`${name}: TypeScript parse error ${bad.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; ')}`);
 }
}catch(e){if(/Cannot find module/.test(String(e)))console.warn('TypeScript parser unavailable; web typecheck will cover frontend syntax.');else throw e;}
console.log('English question revision + quality + learner UI contracts: OK');

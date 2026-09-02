// Final branch-head contract gate for question repair, SSC toughness, related practice, and quality intelligence.
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const base=read('supabase/managed-migrations/20260902150000_english_question_revision_proposals.sql');
const integrity=read('supabase/managed-migrations/20260902151000_english_question_revision_integrity.sql');
const quality=read('supabase/managed-migrations/20260902153000_english_question_quality_intelligence.sql');
const hardening=read('supabase/managed-migrations/20260902154000_english_revision_transfer_quality_hardening.sql');
const migration=[base,integrity,quality,hardening].join('\n');
const worker=read('supabase/functions/english-context-worker/index.ts');
const ui=read('web-v2/components/question-revision-actions.tsx');
const runner=read('web-v2/components/quiz-runner.tsx');
const overlay=read('web-v2/lib/question-revisions.ts');
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
 ['text_token_jaccard','near-duplicate guard'],['generated transfer failed SSC quality gate','generated-transfer quality gate']
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
 ['Correct answer looks doubtful · review only','canonical review wording'],['Write your own note','custom feedback'],
 ['Related practice','explicit new-question action'],['Prepare related question','related practice action'],
 ['Revision proposal ready','ready state'],['Preview','preview action'],['Use revised version','explicit apply action'],['Keep current','keep action'],
 ['setInterval','continuous background-ready polling'],['The question stem and correct answer stay the same','repair-only learner contract']
].forEach(([needle,label])=>requireText(ui,needle,label));
requireText(runner,'applyActiveQuestionRevisions','future-session overlay');
requireText(runner,'QuestionRevisionActions','question-screen action');
requireText(overlay,'questionId','same canonical id overlay');
requireText(overlay,'p_cache_buster: Date.now()','live applied-revision read');
for(const [name,text] of [['base migration',base],['integrity migration',integrity],['quality migration',quality],['hardening migration',hardening]]){
 const dollars=(text.match(/\$\$/g)||[]).length;if(dollars%2)throw new Error(`${name}: unbalanced $$ function delimiters`);
}
try{
 const ts=require(path.join(root,'web-v2/node_modules/typescript'));
 for(const [name,source,jsx] of [['worker',worker,false],['revision ui',ui,true],['overlay',overlay,false]]){
  const out=ts.transpileModule(source,{reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,jsx:jsx?ts.JsxEmit.ReactJSX:ts.JsxEmit.Preserve}});
  const bad=(out.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
  if(bad.length)throw new Error(`${name}: TypeScript parse error ${bad.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; ')}`);
 }
}catch(e){if(/Cannot find module/.test(String(e)))console.warn('TypeScript parser unavailable; web typecheck will cover frontend syntax.');else throw e;}
console.log('English question revision + quality contracts: OK');

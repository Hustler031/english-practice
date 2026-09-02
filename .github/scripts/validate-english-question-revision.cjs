const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const migration=read('supabase/managed-migrations/20260902150000_english_question_revision_proposals.sql');
const worker=read('supabase/functions/english-context-worker/index.ts');
const ui=read('web-v2/components/question-revision-actions.tsx');
const runner=read('web-v2/components/quiz-runner.tsx');
const overlay=read('web-v2/lib/question-revisions.ts');
function requireText(text,needle,label){if(!text.includes(needle))throw new Error(`${label}: missing ${needle}`);}
function forbid(text,re,label){if(re.test(text))throw new Error(`${label}: forbidden pattern ${re}`);}
[
 ['question_revision_proposals','versioned proposal table'],['user_question_revisions','active user overlay'],
 ['pg_advisory_xact_lock','concurrent request serialization'],["status in ('queued','processing','ready','applied','kept','failed','superseded')",'proposal lifecycle'],
 ['english_request_question_revision','request RPC'],['english_get_question_revision_state','live state RPC'],
 ['english_get_applied_question_revisions','applied overlay RPC'],['english_use_question_revision','explicit apply RPC'],
 ['english_keep_question_revision','keep-current RPC'],['question_revision_claim','worker claim'],
 ['apply_question_revision_result','critic-gated result'],['fail_question_revision','bounded failure path'],
 ['revision changed the canonical correct key','canonical grading invariant'],['revision explanation is stale','stale explanation rejection'],
 ['revision critic rejected the proposal','critic gate'],['attempts<3','bounded retries'],['bank_candidate','bank-first evidence']
].forEach(([needle,label])=>requireText(migration,needle,label));
forbid(migration,/update\s+english\.questions\b/i,'canonical question immutability');
forbid(migration,/delete\s+from\s+english\.attempts\b/i,'attempt preservation');
forbid(migration,/update\s+english\.question_state\b/i,'mastery preservation');
[
 ['bankRevisionDraft','bank-first worker path'],['revisionGeneratePrompt','bounded generator'],['revisionCriticPrompt','independent critic'],
 ['exactlyOneCorrect','one-answer gate'],['closeDistractors','SSC distractor gate'],['notObviouslyEliminable','elimination gate'],
 ['explanationMatches','explanation consistency gate'],['noStaleExplanation','stale explanation gate'],['noAmbiguity','ambiguity gate'],
 ['faithfulConcept','concept fidelity gate'],['fairDifficulty','difficulty fairness gate'],['english_apply_question_revision_result','atomic result RPC']
].forEach(([needle,label])=>requireText(worker,needle,label));
[
 ['Options too obvious','feedback reason'],['Distractors are unrelated','feedback reason'],['Explanation is weak','feedback reason'],
 ['Correct answer looks doubtful','feedback reason'],['Write your own note','custom feedback'],['Revision proposal ready','ready state'],
 ['Preview','preview action'],['Use revised version','explicit apply action'],['Keep current','keep action']
].forEach(([needle,label])=>requireText(ui,needle,label));
requireText(runner,'applyActiveQuestionRevisions','future-session overlay');
requireText(runner,'QuestionRevisionActions','question-screen action');
requireText(overlay,'questionId','same canonical id overlay');
requireText(overlay,'p_cache_buster: Date.now()','live applied-revision read');
const dollars=(migration.match(/\$\$/g)||[]).length;if(dollars%2)throw new Error('migration: unbalanced $$ function delimiters');
try{
 const ts=require(path.join(root,'web-v2/node_modules/typescript'));
 for(const [name,source,jsx] of [['worker',worker,false],['revision ui',ui,true],['overlay',overlay,false]]){
  const out=ts.transpileModule(source,{reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,jsx:jsx?ts.JsxEmit.ReactJSX:ts.JsxEmit.Preserve}});
  const bad=(out.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
  if(bad.length)throw new Error(`${name}: TypeScript parse error ${bad.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; ')}`);
 }
}catch(e){if(/Cannot find module/.test(String(e)))console.warn('TypeScript parser unavailable; web typecheck will cover frontend syntax.');else throw e;}
console.log('English question revision contracts: OK');

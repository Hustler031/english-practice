const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const worker = fs.readFileSync(path.join(root, 'supabase/functions/english-saved-enrichment-worker/index.ts'),'utf8');
const terminalMigration = fs.readFileSync(path.join(root, 'supabase/migrations/20260909150000_english_saved_luna_manual_terminal.sql'),'utf8');
const learningIntentMigration = fs.readFileSync(path.join(root, 'supabase/migrations/20260907214500_english_saved_learning_intent.sql'),'utf8');
const familyQualityMigration = fs.readFileSync(path.join(root, 'supabase/migrations/20260909112500_english_saved_family_quality_contract.sql'),'utf8');
const retryMigration = fs.readFileSync(path.join(root, 'supabase/migrations/20260909133000_english_saved_one_minute_retry.sql'),'utf8');

function need(text, needle, label) {
  if (!text.includes(needle)) throw new Error(`Missing ${label}: ${needle}`);
}
function forbid(text, needle, label) {
  if (text.includes(needle)) throw new Error(`Forbidden ${label}: ${needle}`);
}
function before(text, first, second, label) {
  const a = text.indexOf(first), b = text.indexOf(second);
  if (a < 0 || b < 0 || a >= b) throw new Error(`Ordering failed: ${label}`);
}

// Core maintenance boundary remains intact.
need(worker, 'english_saved_enrichment_worker_claim', 'worker claim RPC');
need(worker, 'english_saved_enrichment_worker_apply', 'worker apply RPC');
need(worker, 'english_saved_enrichment_worker_finish', 'worker finish RPC');
need(worker, 'english_record_content_generation_audits', 'content-generation audit RPC');
need(worker, 'fourOptionCodeGate', 'deterministic four-option gate');
forbid(worker, '.from("saved_items")', 'direct saved_items write');
forbid(worker, ".from('saved_items')", 'direct saved_items write');

// New Saved-only smart routing contract.
need(worker, 'SAVED_GEMINI_38_MODEL', 'Gemini 3.8 primary constant');
need(worker, '"gemini-3.8-flash"', 'Gemini 3.8 primary model');
need(worker, 'SAVED_GEMINI_36_MODEL', 'Gemini 3.6 fallback constant');
need(worker, '"gemini-3.6-flash"', 'Gemini 3.6 availability fallback model');
need(worker, 'SAVED_GEMINI_35_MODEL', 'Gemini 3.5 easy-route constant');
need(worker, '"gemini-3.5-flash"', 'Gemini 3.5 easy meaning model');
need(worker, 'type RouteKind="EASY"|"NORMAL"|"CONFUSION"', 'deterministic route labels');
need(worker, 'function routeKind(item:any):RouteKind', 'deterministic difficulty router');
need(worker, 'const family=requiredFamily(item),intent=requiredLearningIntent(item)', 'router reads authoritative family and intent');
need(worker, 'if(intent==="CONFUSION"', 'authoritative confusion routing');
need(worker, 'route==="EASY"?', 'easy-route branch');
need(worker, 'model:SAVED_GEMINI_35_MODEL', 'easy route starts on 3.5');
need(worker, 'model:SAVED_GEMINI_38_MODEL', 'normal/confusion route starts on 3.8');
need(worker, 'model:SAVED_GEMINI_36_MODEL', 'availability fallback uses 3.6');
need(worker, 'availabilityError', 'provider availability classifier');
need(worker, 'directGeminiJson', 'direct Gemini writer');

// Luna is a one-shot rescue writer, not a blanket critic or retry loop.
need(worker, 'lunaRescueJson', 'Luna one-shot rescue writer');
need(worker, 'You are the one-shot rescue writer', 'Luna rescue instruction');
need(worker, 'SAVED_MANUAL_REVIEW_REQUIRED', 'terminal manual-review marker');
need(worker, 'maxLunaCallsPerItem:1', 'one Luna call maximum');
need(worker, 'blanketLunaCritic:false', 'blanket Luna critic disabled');
need(worker, 'sameTierRepair:false', 'same-tier repair disabled');
need(worker, 'criticRequests:0', 'no AI critic request accounting');
need(worker, 'antigravityRequests:0', 'no Antigravity request accounting');
need(worker, 'sameTierRepairUsed:false', 'no same-tier repair audit');
forbid(worker, 'runAntigravityLunaPipeline', 'legacy Antigravity/Luna pipeline');
forbid(worker, 'lunaCritic(', 'blanket Luna critic');
forbid(worker, 'lunaPass(', 'Luna critic pass loop');
forbid(worker, 'ANTIGRAVITY_AGENT', 'Antigravity dependency in Saved worker');
forbid(worker, 'antigravityJson(', 'Antigravity writer call');
forbid(worker, 'sameTierRepair(', 'same-tier AI repair helper');

// A valid Google item publishes without Luna; a deterministic rejection jumps to rescue.
need(worker, 'if(!issues.length)', 'Google deterministic-pass branch');
need(worker, 'lunaRescueUsed:false', 'Google direct publish metadata');
need(worker, 'status:"code_reject"', 'Google deterministic rejection trace');
need(worker, 'return await rescue', 'immediate rescue after Google failure');
need(worker, 'lunaRescueUsed:true', 'Luna rescue publish metadata');

// Existing category/intent authority and SSC hard gates stay enforced.
need(worker, 'function requiredFamily(item:any)', 'authoritative family reader');
need(worker, 'if(capture!=="AUTO")return capture', 'explicit capture authority');
need(worker, 'function requiredLearningIntent(item:any)', 'authoritative learning-intent reader');
need(worker, 'SM requires a spelling-family MCQ', 'SM family gate');
need(worker, 'V requires semantic vocabulary practice, not spelling practice', 'V anti-spelling gate');
need(worker, 'CU must explicitly test grammar/usage or a distinction', 'CU family gate');
need(worker, 'simple V+MEANING must directly test lexical meaning/recall', 'simple meaning gate');
need(worker, 'CONFUSION must test supplied targets together', 'confusion family gate');
need(worker, 'explanation must explicitly explain A, B, C and D', 'all-option explanation gate');
need(worker, 'data.captureType=normalizedCapture(item)', 'AI cannot mutate capture type');
need(worker, 'requiredQuestionFamily:family', 'family sent to writer');
need(worker, 'requiredLearningIntent:requiredIntent', 'learning intent sent to writer');

// Database still resolves family/learning intent before generation and injects family-specific guidance.
need(learningIntentMigration, 'resolve_saved_learning_intent_authoritative', 'authoritative learning-intent resolver');
need(learningIntentMigration, '"requiredLearningIntent"', 'claim payload effective learning intent');
need(familyQualityMigration, 'english.saved_enrichment_prepare_worker_item', 'family-aware writer preparation');
need(familyQualityMigration, "when family='V' and learning_intent='CONFUSION'", 'V confusion generation contract');
need(familyQualityMigration, "when family='CU' and learning_intent='CONFUSION'", 'CU confusion generation contract');
need(familyQualityMigration, "when family='PV'", 'PV generation contract');

// Existing transient provider retries remain, but Luna rescue failure becomes terminal/manual.
need(retryMigration, "state='retrying'", 'transient retry state');
need(retryMigration, "next_attempt_at=now()+interval '1 minute'", 'fast transient retry cadence');
need(terminalMigration, 'SAVED_MANUAL_REVIEW_REQUIRED:%', 'manual terminal marker');
need(terminalMigration, "new.state:='failed'", 'manual rescue failure becomes terminal');
need(terminalMigration, 'new.next_attempt_at:=null', 'terminal item has no auto retry time');
need(terminalMigration, "new.last_error_class:='manual'", 'manual terminal error class');
need(terminalMigration, 'before insert or update of state,last_error,next_attempt_at,last_error_class', 'terminal guard trigger');

// Zero pending exits before generation work.
const zeroGuard = 'if(!items.length)return reply({ok:true,claimed:0,processed:0,failed:0';
need(worker, zeroGuard, 'zero-pending early exit');
before(worker, zeroGuard, 'items.map((item:any)=>enrichOne(item,forceModel))', 'zero-pending exit before item generation');

console.log('English Saved smart router: 3.5 easy / 3.8 primary / 3.6 availability fallback / one-shot Luna rescue / no Antigravity / no critic retry loop: PASS');

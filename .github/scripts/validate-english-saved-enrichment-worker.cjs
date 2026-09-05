const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const worker = fs.readFileSync(
  path.join(root, 'supabase/functions/english-saved-enrichment-worker/index.ts'),
  'utf8',
);
const helper = fs.readFileSync(
  path.join(root, 'supabase/functions/_shared/english-hybrid-ai.ts'),
  'utf8',
);
const workerFoundation = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905075121_english_saved_enrichment_background_worker.sql'),
  'utf8',
);
const bridge = fs.readFileSync(
  path.join(root, 'supabase/functions/english-saved-enrichment-bridge/index.ts'),
  'utf8',
);
const bridgeMigration = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905081500_english_saved_enrichment_chatgpt_bridge.sql'),
  'utf8',
);
const hybridScheduler = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905235930_english_saved_hybrid_scheduler.sql'),
  'utf8',
);
const recoveryMigration = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905090000_english_saved_ready_incomplete_recovery.sql'),
  'utf8',
);
const exactPromotionMigration = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905173500_english_saved_enrichment_exact_promotion.sql'),
  'utf8',
);
const exactApplyMigration = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905174200_english_saved_enrichment_exact_apply.sql'),
  'utf8',
);

function need(text, needle, label) {
  if (!text.includes(needle)) throw new Error(`Missing ${label}: ${needle}`);
}

function forbid(text, needle, label) {
  if (text.includes(needle)) throw new Error(`Forbidden ${label}: ${needle}`);
}

// Production worker keeps the existing token-authorized maintenance contract.
need(worker, 'english_saved_enrichment_worker_claim', 'worker claim RPC');
need(worker, 'english_saved_enrichment_worker_apply', 'worker validated apply RPC');
need(worker, 'english_saved_enrichment_worker_finish', 'worker verify/finish RPC');
need(worker, 'criticAndEscalate', 'Groq critic with specialist escalation');
need(worker, 'QUALITY_REJECTED', 'worker quality gate');
need(worker, 'AI_TIMEOUT', 'worker timeout classification');
forbid(worker, '.from("saved_items")', 'worker direct saved_items write');
forbid(worker, ".from('saved_items')", 'worker direct saved_items write');
forbid(worker, 'OPENAI_API_KEY', 'worker OpenAI provider regression');

// Quality-first request routing: one Saved item per generation request, no batching.
need(helper, 'gemini-3.5-flash-lite', 'Flash-Lite bulk/default model');
need(helper, 'gemini-3.6-flash', 'Flash specialist escalation model');
need(worker, 'const first=await geminiJson<any>(instructions,input,enrichmentSchema,{model:GEMINI_BULK_MODEL})', 'one-item initial Gemini request');
need(worker, 'items.map((item:any)=>enrichOne(item))', 'each claimed Saved item is processed independently');
need(worker, 'current:first.data', 'Groq reviews the original Flash-Lite draft without a duplicate bulk generation');
need(worker, 'model:GEMINI_ESCALATION_MODEL', 'only failed/resolvable Saved item escalates to specialist model');
need(worker, 'requestMode:"one_item_per_generation_request"', 'Saved audit records one-item request mode');
forbid(worker, 'enrichBatch', 'Saved generation batching');
forbid(worker, 'chunks(items', 'Saved batching helper use');

// Zero pending must exit before any provider invocation.
const zeroGuard = 'if(!items.length)return reply({ok:true,claimed:0,processed:0,failed:0,initialGeminiRequests:0';
need(worker, zeroGuard, 'zero-pending early exit');
const zeroPos=worker.indexOf(zeroGuard);
const firstProviderPos=worker.indexOf('items.map((item:any)=>enrichOne(item))');
if(zeroPos<0||firstProviderPos<0||zeroPos>firstProviderPos)throw new Error('Zero-pending guard must precede Saved provider processing');

need(workerFoundation, 'english.maintenance_saved_enrichment_batch', 'maintenance batch helper');
need(workerFoundation, 'english.maintenance_apply_saved_enrichment', 'maintenance apply helper');
need(workerFoundation, 'english.maintenance_verify_saved_enrichment', 'maintenance verify helper');
need(workerFoundation, 'english.kick_saved_enrichment_worker', 'token-authorized worker launcher');

// The former ChatGPT private bridge remains available only as a dormant emergency fallback.
need(bridgeMigration, 'english_saved_enrichment_task_claim', 'fallback ChatGPT task claim RPC');
need(bridgeMigration, 'english_saved_enrichment_task_apply', 'fallback ChatGPT task apply RPC');
need(bridgeMigration, 'last_applied_run_id', 'fallback idempotent apply replay');
need(bridgeMigration, "interval '90 minutes'", 'bounded fallback task lease');
need(bridgeMigration, "jobname='english-saved-enrichment'", 'legacy cron removal recorded');
need(bridgeMigration, 'cron.unschedule', 'legacy cron unschedule recorded');

need(bridge, 'createRemoteJWKSet', 'GitHub remote JWKS validation');
need(bridge, 'jwtVerify', 'GitHub OIDC signature validation');
need(bridge, 'english-saved-enrichment', 'OIDC audience');
need(bridge, 'Hustler031/telegram-media-bot', 'private transport repository claim pin');
need(bridge, 'refs/heads/automation/english-saved-enrichment', 'private queue ref claim pin');
need(bridge, 'english_saved_enrichment_task_claim', 'fallback bridge claim RPC');
need(bridge, 'english_saved_enrichment_task_apply', 'fallback bridge apply RPC');
forbid(bridge, 'Hustler031/english-practice', 'public repository transport pin');
forbid(bridge, 'refs/heads/automation/saved-enrichment', 'public queue ref pin');
forbid(bridge, 'OPENAI_API_KEY', 'OpenAI API use in fallback bridge');
forbid(bridge, 'api.openai.com', 'OpenAI network use in fallback bridge');
forbid(bridge, 'Access-Control-Allow-Origin', 'browser-origin exposure');

// Hybrid rollout reclaims recurring ownership for the Gemini/Groq worker.
need(hybridScheduler, "jobname='english-saved-enrichment'", 'hybrid recurring job identity');
need(hybridScheduler, "'7 * * * *'", 'hourly Saved schedule');
need(hybridScheduler, 'english.kick_saved_enrichment_worker(10)', 'hourly worker invocation');
need(hybridScheduler, 'cron.unschedule', 'idempotent scheduler replacement');

// A legacy row cannot remain terminal Ready when core learning fields are incomplete.
need(recoveryMigration, "lower(btrim(coalesce(s.gpt_status,'')))='ready'", 'legacy Ready re-enrichment eligibility');
need(recoveryMigration, "btrim(coalesce(s.meaning,''))=''", 'missing meaning recovery');
need(recoveryMigration, "btrim(coalesce(s.option_d,''))=''", 'missing option recovery');
need(recoveryMigration, "upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D')", 'invalid key recovery');
need(recoveryMigration, "btrim(coalesce(s.explanation,''))=''", 'missing explanation recovery');
need(recoveryMigration, "when lower(btrim(coalesce(s.gpt_status,'')))='ready' then 0", 'malformed Ready recovery priority');
need(recoveryMigration, 'grant execute on function english.maintenance_saved_enrichment_batch(integer) to service_role', 'service-role maintenance boundary');

// My Saved practice must use the exact validated enrichment, not merely any same-word question.
need(exactPromotionMigration, 'english.ensure_saved_enrichment_exact_question', 'exact enrichment helper');
need(exactPromotionMigration, "btrim(coalesce(q.question,''))=v_question", 'exact question comparison');
need(exactPromotionMigration, "btrim(coalesce(q.option_d,''))=v_d", 'exact option comparison');
need(exactPromotionMigration, "upper(btrim(coalesce(q.correct,'')))=v_correct", 'exact answer-key comparison');
need(exactPromotionMigration, "btrim(coalesce(q.explanation,''))=v_expl", 'exact explanation comparison');
need(exactPromotionMigration, "v_qid:='MYWORD_EXACT_'||v_digest", 'immutable exact variant identity');
need(exactPromotionMigration, 's.saved_id,', 'saved identity in content hash');
need(exactPromotionMigration, "'saved_generated',s.saved_id,p_user_id", 'owner-scoped saved provenance');
need(exactPromotionMigration, 'from english.saved_concept_mappings scm', 'saved concept mapping preservation');
need(exactPromotionMigration, "'saved_exact_enrichment','mapped','variant'", 'exact variant concept relation');
need(exactPromotionMigration, 'perform english.ensure_saved_enrichment_exact_question(r.user_id,r.saved_id)', 'legacy mismatch repair');
need(exactPromotionMigration, "raise exception 'Ready enrichment is incomplete'", 'no incomplete Ready promotion');
forbid(exactPromotionMigration, 'array_agg(x order by random())', 'random fallback distractor generation');

// Re-enrichment of an already linked item must also relink to the exact Ready variant.
need(exactApplyMigration, "if lower(v_status)='ready' then", 'Ready re-promotion');
need(exactApplyMigration, 'v_promoted:=public.english_promote_saved_item(v_saved_id)', 'exact promotion after enrichment');
forbid(exactApplyMigration, "coalesce((select s.practice_question_id", 'blank-link-only promotion gate');
need(exactApplyMigration, 'grant execute on function english.maintenance_apply_saved_enrichment(jsonb) to service_role', 'maintenance apply service-role boundary');

console.log('English Saved enrichment one-item Gemini + Groq critic + specialist escalation contract: PASS');

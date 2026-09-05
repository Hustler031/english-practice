const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const fallbackWorker = fs.readFileSync(
  path.join(root, 'supabase/functions/english-saved-enrichment-worker/index.ts'),
  'utf8',
);
const fallbackMigration = fs.readFileSync(
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

// Paid worker remains only as a dormant/manual fallback.
need(fallbackWorker, 'english_saved_enrichment_worker_claim', 'fallback claim RPC');
need(fallbackWorker, 'english_saved_enrichment_worker_apply', 'fallback validated apply RPC');
need(fallbackWorker, 'english_saved_enrichment_worker_finish', 'fallback verify/finish RPC');
need(fallbackWorker, 'QUALITY_REJECTED', 'fallback quality gate');
need(fallbackWorker, 'AI_TIMEOUT', 'fallback timeout classification');
forbid(fallbackWorker, '.from("saved_items")', 'fallback direct saved_items write');
forbid(fallbackWorker, ".from('saved_items')", 'fallback direct saved_items write');

need(fallbackMigration, 'english.maintenance_saved_enrichment_batch', 'maintenance batch helper');
need(fallbackMigration, 'english.maintenance_apply_saved_enrichment', 'maintenance apply helper');
need(fallbackMigration, 'english.maintenance_verify_saved_enrichment', 'maintenance verify helper');

// Production recurring ownership is ChatGPT task -> private GitHub transport -> OIDC bridge.
need(bridgeMigration, 'english_saved_enrichment_task_claim', 'ChatGPT task claim RPC');
need(bridgeMigration, 'english_saved_enrichment_task_apply', 'ChatGPT task apply RPC');
need(bridgeMigration, 'english.maintenance_saved_enrichment_batch', 'bridge maintenance batch helper');
need(bridgeMigration, 'english.maintenance_apply_saved_enrichment', 'bridge maintenance apply helper');
need(bridgeMigration, 'english.maintenance_verify_saved_enrichment', 'bridge maintenance verify helper');
need(bridgeMigration, 'last_applied_run_id', 'idempotent apply replay');
need(bridgeMigration, "interval '90 minutes'", 'bounded ChatGPT task lease');
need(bridgeMigration, "jobname='english-saved-enrichment'", 'old paid cron ownership removal');
need(bridgeMigration, 'cron.unschedule', 'old paid cron unschedule');

need(bridge, 'createRemoteJWKSet', 'GitHub remote JWKS validation');
need(bridge, 'jwtVerify', 'GitHub OIDC signature validation');
need(bridge, 'english-saved-enrichment', 'OIDC audience');
need(bridge, 'Hustler031/telegram-media-bot', 'private transport repository claim pin');
need(bridge, 'refs/heads/automation/english-saved-enrichment', 'private queue ref claim pin');
need(bridge, 'english_saved_enrichment_task_claim', 'bridge claim RPC');
need(bridge, 'english_saved_enrichment_task_apply', 'bridge apply RPC');
forbid(bridge, 'Hustler031/english-practice', 'public repository transport pin');
forbid(bridge, 'refs/heads/automation/saved-enrichment', 'public queue ref pin');
forbid(bridge, 'OPENAI_API_KEY', 'OpenAI API use in zero-cost bridge');
forbid(bridge, 'api.openai.com', 'OpenAI network use in zero-cost bridge');
forbid(bridge, 'Access-Control-Allow-Origin', 'browser-origin exposure');

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

console.log('English Saved enrichment private ChatGPT bridge contract: PASS');

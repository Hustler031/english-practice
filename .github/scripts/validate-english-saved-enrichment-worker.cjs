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

console.log('English Saved enrichment private ChatGPT bridge contract: PASS');

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const worker = fs.readFileSync(
  path.join(root, 'supabase/functions/english-saved-enrichment-worker/index.ts'),
  'utf8',
);
const migration = fs.readFileSync(
  path.join(root, 'supabase/managed-migrations/20260905133000_english_saved_enrichment_background_worker.sql'),
  'utf8',
);

function need(text, needle, label) {
  if (!text.includes(needle)) throw new Error(`Missing ${label}: ${needle}`);
}

function forbid(text, needle, label) {
  if (text.includes(needle)) throw new Error(`Forbidden ${label}: ${needle}`);
}

need(worker, 'english_saved_enrichment_worker_claim', 'token/lease claim RPC');
need(worker, 'english_saved_enrichment_worker_apply', 'validated apply RPC');
need(worker, 'english_saved_enrichment_worker_finish', 'verify/finish RPC');
need(worker, 'x-english-context-token', 'private scheduler token');
need(worker, 'QUALITY_REJECTED', 'quality gate');
need(worker, 'AI_TIMEOUT', 'transient timeout classification');
need(worker, 'Promise.allSettled', 'bounded batch isolation');
forbid(worker, '.from("saved_items")', 'direct canonical saved_items write');
forbid(worker, ".from('saved_items')", 'direct canonical saved_items write');
forbid(worker, 'Access-Control-Allow-Origin', 'browser-origin exposure');

need(migration, 'english.maintenance_saved_enrichment_batch', 'existing maintenance batch helper');
need(migration, 'english.maintenance_apply_saved_enrichment', 'existing maintenance apply helper');
need(migration, 'english.maintenance_verify_saved_enrichment', 'existing maintenance verify helper');
need(migration, 'english.context_worker_authorized', 'private token authorization');
need(migration, 'lease_expires_at', 'lease recovery');
need(migration, 'english-saved-enrichment', 'pg_cron job');
need(migration, "'7 * * * *'", 'hourly schedule');
need(migration, 'english.kick_saved_enrichment_worker(10)', '10-item bounded batch');

console.log('English Saved enrichment worker contract: PASS');

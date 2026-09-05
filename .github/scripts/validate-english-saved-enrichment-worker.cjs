const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const worker = fs.readFileSync(path.join(root, 'supabase/functions/english-saved-enrichment-worker/index.ts'),'utf8');
const helper = fs.readFileSync(path.join(root, 'supabase/functions/_shared/english-antigravity-luna.ts'),'utf8');
const workerFoundation = fs.readFileSync(path.join(root, 'supabase/managed-migrations/20260905075121_english_saved_enrichment_background_worker.sql'),'utf8');
const bridge = fs.readFileSync(path.join(root, 'supabase/functions/english-saved-enrichment-bridge/index.ts'),'utf8');
const bridgeMigration = fs.readFileSync(path.join(root, 'supabase/managed-migrations/20260905081500_english_saved_enrichment_chatgpt_bridge.sql'),'utf8');
const hybridScheduler = fs.readFileSync(path.join(root, 'supabase/managed-migrations/20260905235930_english_saved_hybrid_scheduler.sql'),'utf8');
const recoveryMigration = fs.readFileSync(path.join(root, 'supabase/managed-migrations/20260905090000_english_saved_ready_incomplete_recovery.sql'),'utf8');
const exactPromotionMigration = fs.readFileSync(path.join(root, 'supabase/managed-migrations/20260905173500_english_saved_enrichment_exact_promotion.sql'),'utf8');
const exactApplyMigration = fs.readFileSync(path.join(root, 'supabase/managed-migrations/20260905174200_english_saved_enrichment_exact_apply.sql'),'utf8');

function need(text, needle, label) { if (!text.includes(needle)) throw new Error(`Missing ${label}: ${needle}`); }
function forbid(text, needle, label) { if (text.includes(needle)) throw new Error(`Forbidden ${label}: ${needle}`); }

// Production worker keeps the existing token-authorized maintenance contract.
need(worker, 'english_saved_enrichment_worker_claim', 'worker claim RPC');
need(worker, 'english_saved_enrichment_worker_apply', 'worker validated apply RPC');
need(worker, 'english_saved_enrichment_worker_finish', 'worker verify/finish RPC');
need(worker, 'english_record_content_generation_audits', 'worker audit RPC');
need(worker, 'AI_TIMEOUT', 'worker timeout classification');
need(worker, 'antigravity_writer_v1', 'Antigravity rollout flag');
need(worker, 'luna_critic_v1', 'Luna rollout flag');
forbid(worker, '.from("saved_items")', 'worker direct saved_items write');
forbid(worker, ".from('saved_items')", 'worker direct saved_items write');

// One Saved item per writer/critic call; no batch generation.
need(helper, 'antigravity-preview-05-2026', 'Antigravity writer agent');
need(helper, 'gpt-5.6-luna', 'Luna critic model');
need(helper, 'reasoning:{effort:"low"}', 'Luna low reasoning');
need(helper, 'gemini-3.8-flash', 'rare second-repair rescue');
need(helper, 'thinkingConfig:{thinkingLevel:"high"}', 'rare rescue high reasoning');
need(helper, 'Only a second Luna REPAIR reaches the rare Gemini 3.8 Flash HIGH rescue path.', 'second Luna repair rescue rule');
need(worker, 'runAntigravityLunaPipeline<any>', 'Saved writer/critic pipeline');
need(worker, 'items.map((item:any)=>enrichOne(item))', 'each claimed Saved item is processed independently');
need(worker, 'requestMode:"one_item_per_generation_request"', 'Saved audit records one-item request mode');
need(worker, 'writerReasoning:"high"', 'Saved writer reasoning audit');
need(worker, 'criticReasoning:"low"', 'Saved critic reasoning audit');
need(worker, 'rareRescueModel:GEMINI_RARE_RESCUE_MODEL', 'Saved rare rescue audit');
need(worker, 'fourOptionCodeGate', 'Saved deterministic option gate');
need(worker, 'explicit captureType', 'Saved explicit capture-type preservation gate');
forbid(worker, 'enrichBatch', 'Saved generation batching');
forbid(worker, 'chunks(items', 'Saved batching helper use');
forbid(worker, 'GROQ_API_KEY', 'Saved direct Groq dependency');
forbid(worker, 'criticAndEscalate', 'Saved legacy Groq escalation helper');

// Zero pending must exit before any item provider invocation.
const zeroGuard = 'if(!items.length)return reply({ok:true,claimed:0,processed:0,failed:0,initialAntigravityRequests:0';
need(worker, zeroGuard, 'zero-pending early exit');
const zeroPos=worker.indexOf(zeroGuard);
const firstProviderPos=worker.indexOf('items.map((item:any)=>enrichOne(item))');
if(zeroPos<0||firstProviderPos<0||zeroPos>firstProviderPos)throw new Error('Zero-pending guard must precede Saved item provider processing');

need(workerFoundation, 'english.maintenance_saved_enrichment_batch', 'maintenance batch helper');
need(workerFoundation, 'english.maintenance_apply_saved_enrichment', 'maintenance apply helper');
need(workerFoundation, 'english.maintenance_verify_saved_enrichment', 'maintenance verify helper');
need(workerFoundation, 'english.kick_saved_enrichment_worker', 'token-authorized worker launcher');

// Former ChatGPT private bridge remains only dormant emergency transport.
need(bridgeMigration, 'english_saved_enrichment_task_claim', 'fallback ChatGPT task claim RPC');
need(bridgeMigration, 'english_saved_enrichment_task_apply', 'fallback ChatGPT task apply RPC');
need(bridgeMigration, 'last_applied_run_id', 'fallback idempotent apply replay');
need(bridgeMigration, "interval '90 minutes'", 'bounded fallback task lease');
need(bridgeMigration, "jobname='english-saved-enrichment'", 'legacy cron removal recorded');
need(bridgeMigration, 'cron.unschedule', 'legacy cron unschedule recorded');
need(bridge, 'createRemoteJWKSet', 'GitHub remote JWKS validation');
need(bridge, 'jwtVerify', 'GitHub OIDC signature validation');
need(bridge, 'english-saved-enrichment', 'OIDC audience');
need(bridge, 'Hustler031/telegram-media-bot', 'private transport repository pin');
need(bridge, 'refs/heads/automation/english-saved-enrichment', 'private queue ref pin');
forbid(bridge, 'OPENAI_API_KEY', 'OpenAI use in dormant bridge');
forbid(bridge, 'api.openai.com', 'OpenAI network use in dormant bridge');

// Recurring production ownership stays with the Supabase worker.
need(hybridScheduler, "jobname='english-saved-enrichment'", 'recurring job identity');
need(hybridScheduler, "'7 * * * *'", 'hourly Saved schedule');
need(hybridScheduler, 'english.kick_saved_enrichment_worker(10)', 'hourly worker invocation');
need(hybridScheduler, 'cron.unschedule', 'idempotent scheduler replacement');

// Recovery and exact promotion invariants remain unchanged.
need(recoveryMigration, "lower(btrim(coalesce(s.gpt_status,'')))='ready'", 'legacy Ready re-enrichment eligibility');
need(recoveryMigration, "btrim(coalesce(s.meaning,''))=''", 'missing meaning recovery');
need(recoveryMigration, "btrim(coalesce(s.option_d,''))=''", 'missing option recovery');
need(recoveryMigration, "upper(btrim(coalesce(s.correct_option,''))) not in ('A','B','C','D')", 'invalid key recovery');
need(recoveryMigration, "btrim(coalesce(s.explanation,''))=''", 'missing explanation recovery');
need(exactPromotionMigration, 'english.ensure_saved_enrichment_exact_question', 'exact enrichment helper');
need(exactPromotionMigration, "btrim(coalesce(q.question,''))=v_question", 'exact question comparison');
need(exactPromotionMigration, "upper(btrim(coalesce(q.correct,'')))=v_correct", 'exact answer-key comparison');
need(exactPromotionMigration, "btrim(coalesce(q.explanation,''))=v_expl", 'exact explanation comparison');
need(exactPromotionMigration, "v_qid:='MYWORD_EXACT_'||v_digest", 'immutable exact variant identity');
need(exactPromotionMigration, "raise exception 'Ready enrichment is incomplete'", 'no incomplete Ready promotion');
forbid(exactPromotionMigration, 'array_agg(x order by random())', 'random fallback distractor generation');
need(exactApplyMigration, "if lower(v_status)='ready' then", 'Ready re-promotion');
need(exactApplyMigration, 'v_promoted:=public.english_promote_saved_item(v_saved_id)', 'exact promotion after enrichment');
need(exactApplyMigration, 'grant execute on function english.maintenance_apply_saved_enrichment(jsonb) to service_role', 'maintenance apply service-role boundary');

console.log('English Saved Antigravity HIGH writer + Luna LOW one-item critic contract: PASS');

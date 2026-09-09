import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const read = (p) => fs.readFileSync(p, 'utf8');
const fail = (m) => { throw new Error(`Grammar Stage 1 validation failed: ${m}`); };
const has = (text, needle, label = needle) => { if (!text.includes(needle)) fail(`missing ${label}`); };
const notHas = (text, needle, label = needle) => { if (text.includes(needle)) fail(`forbidden ${label}`); };

const foundationPath = 'supabase/migrations/20260909012000_english_grammar_intelligence_foundation.sql';
const syncPath = 'supabase/migrations/20260909012500_english_grammar_curriculum_sync.sql';
const pipelinePath = 'supabase/migrations/20260909013000_english_grammar_daily_pipeline.sql';
const preflightPath = 'supabase/migrations/20260909011500_english_grammar_preflight.sql';
const bridgePath = 'supabase/functions/english-content-task-bridge/index.ts';
const submittedPath = 'supabase/functions/english-content-task-bridge/submitted-grammar.ts';
const manifestPath = 'web-v2/data/grammar-curriculum-manifest.json';
const aliasesPath = 'web-v2/data/grammar-sprint-aliases.json';

for (const p of [preflightPath, foundationPath, syncPath, pipelinePath, bridgePath, submittedPath, manifestPath, aliasesPath]) {
  if (!fs.existsSync(p)) fail(`required file missing: ${p}`);
}

const preflight = read(preflightPath);
const foundation = read(foundationPath);
const sync = read(syncPath);
const pipeline = read(pipelinePath);
const bridge = read(bridgePath);
const submitted = read(submittedPath);
const manifest = JSON.parse(read(manifestPath));
const aliases = JSON.parse(read(aliasesPath));

// Frozen curriculum contract.
if (manifest.ruleCount !== 260) fail(`expected 260 verified atomic rules, got ${manifest.ruleCount}`);
if (manifest.dailyTarget !== 20) fail(`Daily Grammar target must remain exact 20`);
if (manifest?.coldStart?.initialReviewCap !== 3) fail(`cold-start review cap must remain 3 after initial exposure threshold`);
if (!manifest.keySha256 || !/^[a-f0-9]{64}$/.test(manifest.keySha256)) fail('curriculum key checksum is missing/invalid');
if (Object.keys(manifest.chapters || {}).length < 12) fail('curriculum breadth unexpectedly narrow');
const chapterTotal = Object.values(manifest.chapters || {}).reduce((a, b) => a + Number(b || 0), 0);
if (chapterTotal !== manifest.ruleCount) fail(`chapter total ${chapterTotal} != ruleCount ${manifest.ruleCount}`);

// Feature stays OFF until explicit deployment.
has(preflight, "'grammar_ai_v1'::text", 'Grammar feature-flag constraint');
has(foundation, "values('grammar_ai_v1',false", 'Grammar feature flag disabled by default');

// First-class schema + RLS from birth.
for (const table of ['grammar_rules','grammar_rule_aliases','grammar_question_variants','grammar_rule_events','grammar_rule_evidence','grammar_generation_batches','grammar_generation_slots','grammar_daily_items']) {
  has(foundation, `create table if not exists english.${table}`, `${table} table`);
  has(foundation, `alter table english.${table} enable row level security`, `${table} RLS`);
}
has(foundation, "source text not null check(source in ('grammar_daily','sprint'))", 'Sprint + Daily evidence sources');
has(foundation, 'create or replace function english.recompute_grammar_rule_evidence', 'incremental rule evidence recompute');
notHas(foundation, 'learning_progress_cache', 'Learning Progress cache dependency in Grammar evidence');

// Google Sheet is a curated source only; no daily runtime dependency.
has(sync, 'grammar_sync_curriculum', 'validated curriculum snapshot sync');
has(sync, 'Grammar curriculum must contain 200-500 verified atomic rules', 'curriculum size gate');
has(sync, 'Grammar curriculum Rule_Key values must be unique', 'curriculum unique-key gate');
has(sync, 'Grammar curriculum key checksum mismatch', 'curriculum checksum gate');
has(sync, 'grammar_sync_sprint_aliases', 'non-destructive Sprint alias sync');
notHas(pipeline.toLowerCase(), 'googleapis', 'Google API in daily runtime');
notHas(pipeline, manifest.spreadsheetId, 'Google Sheet ID in daily runtime');

// Exact-20 atomic publication and cold-start behaviour.
has(pipeline, "if p_count<>20 then raise exception 'Grammar Daily invariant requires exactly 20 slots'", 'exact-20 selector invariant');
has(pipeline, 'if v_introduced<20 then v_review_cap:=0', 'initial all-new cold start');
has(pipeline, 'elsif v_introduced<140 then v_review_cap:=3', 'bounded early review cap');
has(pipeline, "if v_selected<>20 then raise exception 'Grammar selector could form only % of 20 distinct rule slots", 'selector fail-closed');
has(pipeline, "if v_existing<>0 then raise exception 'Partial Grammar daily membership exists", 'partial-membership refusal');
has(pipeline, "jsonb_array_length(p_items)<>20", 'apply exact-20 finalized payload');
has(pipeline, 'Grammar finalized slot numbers must be unique', 'unique slot invariant');
has(pipeline, 'Grammar slot % canonical reuse identity mismatch', 'same-ID canonical reuse guard');
has(pipeline, "v_qid:='GRM'||lpad(nextval('english.grammar_question_seq')::text,6,'0')", 'new permanent Grammar Question_ID');
has(pipeline, 'english.generated_item_hard_gates_pass(v_item)', 'deterministic final-payload hard gates');
has(pipeline, 'missing ChatGPT self-critic provenance', 'ChatGPT self-critic provenance');
has(pipeline, 'planner family is outside CI allowance', 'AI planner bounded by CI family allowance');
has(pipeline, 'duplicates an existing canonical question stem', 'canonical duplicate guard');
has(pipeline, 'public.english_get_grammar_today()', 'app-facing exact Grammar getter');
has(pipeline, "'ready',(select count(*) from rows)=20", 'getter ready only at exact 20');

// Bridge is ChatGPT-owned, not a second server-side Grammar generator.
has(bridge, 'GRAMMAR_REF = "refs/heads/automation/english-grammar"', 'Grammar OIDC branch binding');
has(bridge, 'claimSubmittedGrammar', 'Grammar claim route');
has(bridge, 'ingestSubmittedGrammar', 'Grammar ingest route');
has(bridge, 'Legacy/server-side Grammar AI generation is disabled', 'no legacy Grammar server AI');
has(submitted, 'selection.length !== 20', 'bridge exact-20 claim guard');
has(submitted, 'itemsRaw.length > 20', 'generated-only override upper bound');
has(submitted, 'english_grammar_task_ingest', 'Grammar ingest RPC');

// Historical Sprint aliases are curated, unique and intentionally conservative.
if (!Array.isArray(aliases.aliases) || aliases.aliases.length < 40) fail('too few curated Sprint aliases');
const aliasKeys = aliases.aliases.map((x) => x.aliasKey);
if (new Set(aliasKeys).size !== aliasKeys.length) fail('duplicate Sprint alias keys');
for (const a of aliases.aliases) {
  if (!a.aliasKey || !a.ruleKey) fail('empty Sprint alias mapping');
  if (!(Number(a.confidence) >= 0.9 && Number(a.confidence) <= 1)) fail(`low/invalid alias confidence for ${a.aliasKey}`);
}
for (const excluded of aliases.deliberatelyExcludedExamples || []) {
  if (aliasKeys.includes(excluded)) fail(`deliberately excluded historical key was mapped: ${excluded}`);
}

// Stage 1 is backend/data only. No learning UI, Maths, or GK implementation may change.
let changed = [];
try {
  const out = execFileSync('git', ['diff', '--name-only', 'origin/main...HEAD'], { encoding: 'utf8' });
  changed = out.split(/\r?\n/).filter(Boolean);
} catch {
  // Local/manual validation can run without origin/main; CI performs the strict path check.
}
for (const p of changed) {
  if (/^web-v2\/(app|components|styles)\//.test(p)) fail(`Stage 1 unexpectedly changed UI path: ${p}`);
  if (/(^|\/)(maths?|gk)(\/|[-_.])/i.test(p)) fail(`Stage 1 crossed Maths/GK boundary: ${p}`);
}

console.log(JSON.stringify({
  ok: true,
  stage: 'grammar-intelligence-stage1',
  ruleCount: manifest.ruleCount,
  chapters: Object.keys(manifest.chapters).length,
  aliasCount: aliases.aliases.length,
  dailyTarget: manifest.dailyTarget,
  coldStartInitialReviewCap: manifest.coldStart.initialReviewCap,
  changedFilesChecked: changed.length,
}, null, 2));

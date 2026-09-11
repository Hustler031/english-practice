const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const focus = read('web-v2/app/english/focus/page.tsx');
const home = read('web-v2/app/english/page.tsx');
const phase1 = read('supabase/migrations/20260911091322_english_review_due_today_phase1_shadow.sql');
const shadowSecurity = read('supabase/migrations/20260911095447_english_review_due_shadow_security_hardening.sql');
const lane = read('supabase/migrations/20260911100000_english_review_due_practice_lane.sql');
const gate = read('supabase/migrations/20260911100500_english_review_due_cross_credit_deferral_gate.sql');
const gateAware = read('supabase/migrations/20260911101000_english_review_due_gate_aware_lane.sql');
const exactQuality = read('supabase/migrations/20260911101200_english_review_due_exact_question_quality_semantics.sql');
const releaseSecurity = read('supabase/migrations/20260911101500_english_review_due_release_security_hardening.sql');

function must(text, re, label) {
  if (!re.test(text)) throw new Error(`Review Due contract failed: ${label}`);
}
function mustNot(text, re, label) {
  if (re.test(text)) throw new Error(`Review Due contract failed: ${label}`);
}

must(focus, /Review Due Today/, 'Daily Focus must expose Review Due Today');
must(focus, /module="reviewduetoday"/, 'Review Due quiz must submit with dedicated module provenance');
must(focus, /english_get_review_due_lane/, 'Daily Focus must load the Review Due lane');
must(focus, /p_nonce:/, 'Review Due lane must use a fresh cache key');
must(focus, /settlePendingAnswers/, 'Review Due lane must settle queued answers before a fresh read');
must(focus, /ep:answer-durable/, 'Daily Focus must refresh after durable answer saves');
must(focus, /const total=summary\?\.total\|\|170/, 'Daily Focus denominator must remain 170');
must(focus, /separate from 170/, 'Review Due must be visibly separate from the 170 denominator');

must(home, /Daily Focus/, 'Home must retain Daily Focus entry point');
must(home, /Review Due/, 'Home Daily Focus entry must surface Review Due status');
mustNot(home, /aria-label="Review Due Today shadow tracking"/, 'Home must not retain the obsolete standalone shadow card');

must(phase1, /source text not null default 'question_state\.next_review'/, 'question_state.next_review must remain the obligation source');
must(phase1, /primary key \(user_id,due_date,concept_key\)/, 'one obligation per user + day + concept');
must(phase1, /30 18 \* \* \*/, 'snapshot must run at 00:00 IST');

must(shadowSecurity, /set search_path to 'pg_catalog'/, 'review_due_module_qualifies must use a fixed search path');
must(shadowSecurity, /review_due_day_runs enable row level security/, 'active due-day snapshot table must have RLS');
must(shadowSecurity, /review_due_obligations enable row level security/, 'active obligation table must have RLS');
must(shadowSecurity, /review_due_phase2_daily_mix_selections enable row level security/, 'active Phase 2 selection ledger must have RLS');

must(lane, /english\.review_due_evidence_status/, 'practice lane must use strict evidence classification');
must(lane, /actual due question first|due question/i, 'practice lane migration must document due-question priority');
must(lane, /reviewDueQuestionCount/, 'practice payload must expose dedup provenance');
must(lane, /countsTowardDailyFocus',false/, 'Review Due must not count toward Daily Focus');
must(lane, /routingChanged',false/, 'practice-lane migration must not silently alter routing');
mustNot(lane, /update\s+english\.question_state/i, 'practice lane must remain read-only with respect to question_state');
mustNot(lane, /insert\s+into\s+english\.attempts/i, 'practice lane must never fake attempts');

must(gate, /cross_concept_credit_enabled boolean not null default false/, 'cross-concept credit must default OFF');
must(gate, /auto_deferral_enabled boolean not null default false/, 'automatic deferral must default OFF');
must(gate, /review_due_question_deferrals/, 'cross-concept credit must have an audited word-clock deferral ledger');
must(gate, /active_review_due_deferral/, 'recompute path must preserve recorded deferrals');
must(gate, /least\(v_base_next,v_override\)/, 'guess/context earlier-review override must beat a later deferral');
must(gate, /25 18 \* \* \*/, 'deferral reconciliation must run at 23:55 IST');
must(gate, /enabled',false/, 'disabled deferral path must explicitly no-op');
mustNot(gate, /insert\s+into\s+english\.attempts/i, 'deferral must never manufacture learning history');

must(gateAware, /crossCreditEnabled/, 'learner summary must expose cross-credit gate state');
must(gateAware, /p\.cross_credit or q\.question_id=any\(s\.due_question_ids\)/, 'gate-OFF practice must stay on exact due questions');
must(gateAware, /reviewDueCrossCreditEnabled/, 'practice payload must expose gate state');
must(gateAware, /Retry the scheduled due word after repair/, 'gate-OFF repair selection must remain exact-word based');
mustNot(gateAware, /insert\s+into\s+english\.attempts/i, 'gate-aware lane must never manufacture attempts');

must(exactQuality, /exact_due or not too_easy/, 'exact due questions must remain resolvable even when flagged too easy');
must(exactQuality, /too_easy and not exact_due/, 'too-easy sibling evidence must remain low-confidence');
must(exactQuality, /a\.low_at is null[\s\S]*interval '15 minutes'/, 'guessed/low-confidence same-question recovery must require aged or fresh evidence');
mustNot(exactQuality, /insert\s+into\s+english\.attempts/i, 'quality semantics must never manufacture attempts');

must(releaseSecurity, /review_due_runtime_config enable row level security/, 'runtime gate table must have RLS');
must(releaseSecurity, /review_due_question_deferrals enable row level security/, 'deferral audit table must have RLS');
must(releaseSecurity, /review_due_deferral_days[\s\S]*set search_path to 'pg_catalog'/, 'deferral helper must use a fixed search path');
must(releaseSecurity, /revoke all on function public\.english_get_review_due_today\(\) from public,anon/, 'summary RPC must deny anonymous execution');
must(releaseSecurity, /revoke all on function public\.english_get_review_due_lane\(text\) from public,anon/, 'practice RPC must deny anonymous execution');

console.log('Review Due Today contracts: PASS');

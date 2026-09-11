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
const coverageHotfix = read('supabase/migrations/20260911113000_english_review_due_coverage_semantics_hotfix.sql');
const enableCrossCredit = read('supabase/migrations/20260911120500_english_review_due_enable_valid_cross_credit.sql');
const carryoverOwner = read('supabase/migrations/20260911192000_english_review_due_carryover_owner.sql');
const focusV3 = read('supabase/migrations/20260911200000_english_daily_focus_unified_repair_v3.sql');
const focusSummaryV3 = read('supabase/migrations/20260911200500_english_daily_focus_summary_version_aware.sql');
const midnight = read('supabase/migrations/20260911201000_english_midnight_orchestrator_v1.sql');
const dailyMixV2 = read('supabase/migrations/20260911202000_english_daily_mix_performance_v2.sql');
const cronCutover = read('supabase/migrations/20260911203000_english_midnight_orchestrator_cron_cutover.sql');

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
must(focus, /const total=summary\?\.total\|\|summary\?\.nominalTarget\|\|170/, 'Daily Focus total must be version-aware with legacy fallback');
must(focus, /const focusDenominator=summary\?\.nominalTarget\|\|170/, 'Daily Focus denominator must come from the frozen batch contract');
must(focus, /separate from \$\{focusDenominator\}/, 'Review Due must be visibly separate from the active Focus denominator');
must(focus, /scheduled reviews covered/, 'Review Due UI must describe coverage, not retention proof');
must(focus, /whether correct or wrong/, 'Review Due UI must document any-attempt coverage');
must(focus, /wrong answer elsewhere does not cover it/, 'Review Due UI must document outside-wrong non-credit');
must(focus, /carryoverConcepts/, 'Review Due UI must surface unresolved carryover');
must(focus, /Valid strong evidence from another module may cross-credit Review Due/, 'UI must describe enabled validated cross-credit');

must(home, /Daily Focus/, 'Home must retain Daily Focus entry point');
must(home, /Review Due/, 'Home Daily Focus entry must surface Review Due status');
must(home, /Today’s performance mix/, 'Home must describe Daily Mix as performance practice, not scheduled review');
must(home, /carryoverConcepts/, 'Home must surface Review Due carryover');
mustNot(home, /aria-label="Review Due Today shadow tracking"/, 'Home must not retain the obsolete standalone shadow card');

must(phase1, /source text not null default 'question_state\.next_review'/, 'question_state.next_review must remain the obligation source');
must(phase1, /primary key \(user_id,due_date,concept_key\)/, 'one obligation per user + day + concept');
must(phase1, /30 18 \* \* \*/, 'original snapshot contract must document 00:00 IST');

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

must(gate, /cross_concept_credit_enabled boolean not null default false/, 'cross-concept credit must default OFF before validated activation');
must(gate, /auto_deferral_enabled boolean not null default false/, 'automatic deferral must default OFF before validated activation');
must(gate, /review_due_question_deferrals/, 'cross-concept credit must have an audited word-clock deferral ledger');
must(gate, /active_review_due_deferral/, 'recompute path must preserve recorded deferrals');
must(gate, /least\(v_base_next,v_override\)/, 'guess/context earlier-review override must beat a later deferral');
must(gate, /25 18 \* \* \*/, 'deferral reconciliation must run at 23:55 IST');
must(gate, /enabled',false/, 'disabled deferral path must explicitly no-op');
mustNot(gate, /insert\s+into\s+english\.attempts/i, 'deferral must never manufacture learning history');

must(gateAware, /crossCreditEnabled/, 'learner summary must expose cross-credit gate state');
must(gateAware, /p\.cross_credit or q\.question_id=any\(s\.due_question_ids\)/, 'gate-aware practice must protect exact-due behavior while cross-credit is disabled');
must(gateAware, /reviewDueCrossCreditEnabled/, 'practice payload must expose gate state');
mustNot(gateAware, /insert\s+into\s+english\.attempts/i, 'gate-aware lane must never manufacture attempts');

must(exactQuality, /exact_due or not too_easy/, 'exact due questions must remain resolvable even when flagged too easy');
must(exactQuality, /too_easy and not exact_due/, 'too-easy sibling evidence must remain low-confidence');
must(exactQuality, /a\.low_at is null[\s\S]*interval '15 minutes'/, 'quality diagnostics must retain aged/fresh recovery semantics');
mustNot(exactQuality, /insert\s+into\s+english\.attempts/i, 'quality semantics must never manufacture attempts');

must(coverageHotfix, /module_key='reviewduetoday'/, 'dedicated Review Due attempts must be identifiable');
must(coverageHotfix, /when review_attempt_at is not null then 'satisfied'/, 'any durable Review Due attempt must cover today even when wrong');
must(coverageHotfix, /when cross_credit_enabled and recovered then 'satisfied'/, 'outside-module credit must require enabled strong recovery evidence');
must(coverageHotfix, /else 'remaining'/, 'outside wrong/low-confidence evidence must leave the Review Due obligation open');
must(coverageHotfix, /when wrong_at is not null then 'needs_repair'/, 'shadow quality status must still preserve wrong-answer repair evidence');
mustNot(coverageHotfix, /update\s+english\.question_state/i, 'coverage hotfix must not directly write question_state or next_review');
mustNot(coverageHotfix, /insert\s+into\s+english\.attempts/i, 'coverage hotfix must never manufacture attempts');

must(enableCrossCredit, /cross_concept_credit_enabled\s*=\s*true/, 'validated cross-module credit must be explicitly enabled');
must(enableCrossCredit, /auto_deferral_enabled\s*=\s*true/, 'automatic scheduler deferral must be enabled together with cross-credit');
must(enableCrossCredit, /cross-credit and auto-deferral must be enabled together/i, 'activation migration must fail closed if the paired gates diverge');
mustNot(enableCrossCredit, /insert\s+into\s+english\.attempts/i, 'cross-credit activation must not manufacture attempts');

must(releaseSecurity, /review_due_runtime_config enable row level security/, 'runtime gate table must have RLS');
must(releaseSecurity, /review_due_question_deferrals enable row level security/, 'deferral audit table must have RLS');
must(releaseSecurity, /review_due_deferral_days[\s\S]*set search_path to 'pg_catalog'/, 'deferral helper must use a fixed search path');
must(releaseSecurity, /revoke all on function public\.english_get_review_due_today\(\) from public,anon/, 'summary RPC must deny anonymous execution');
must(releaseSecurity, /revoke all on function public\.english_get_review_due_lane\(text\) from public,anon/, 'practice RPC must deny anonymous execution');

// Central scheduler ownership and carryover.
must(carryoverOwner, /origin_due_date date/, 'Review Due obligations must preserve original scheduled date');
must(carryoverOwner, /resolution_status<>'satisfied'/, 'only unresolved prior obligations may carry forward');
must(carryoverOwner, /question_state\.next_review\+carryover/, 'exact-today and carryover obligations must merge by concept');
must(carryoverOwner, /reviewDueCarryover/, 'practice payload must expose carryover provenance');
must(carryoverOwner, /Missed scheduled review carryover/, 'carryover items must be auditable in selection reason');
mustNot(carryoverOwner, /insert\s+into\s+english\.attempts/i, 'carryover owner must never manufacture attempts');

// Version-aware Focus migration: existing frozen batches remain legacy, new batches use unified learning needs.
must(focusV3, /repair_target>=0 and repair_target<=70/, 'Repair batch contract must allow up to 70');
must(focusV3, /learning_need_repair_selection/, 'v3 Repair must use canonical Learning Need selection');
must(focusV3, /limit least\(50/, 'v3 Repair must cap critical learning slots at 50');
must(focusV3, /limit least\(15/, 'v3 Repair must reserve anti-starvation capacity');
must(focusV3, /selectionLane/, 'v3 Repair snapshot must record critical/rotation/fill provenance');
must(focusSummaryV3, /case when v_is_v3 then 190 else 170 end/, 'Focus summary must preserve legacy 170 and expose v3 190');
must(focusSummaryV3, /case when v_is_v3 then 70 else 50 end/, 'Repair summary must preserve legacy 50 and expose v3 70');

// Midnight ordering: scheduler snapshot -> Focus learning mission -> Daily performance sampler.
must(midnight, /reconcile_review_due_deferrals\(p_user_id,v_today-1\)/, 'midnight must reconcile yesterday before snapshot');
must(midnight, /capture_review_due_day\(p_user_id,v_today\)/, 'midnight must snapshot Review Due first');
must(midnight, /v_focus:=english\.ensure_daily_focus\(p_user_id\)/, 'midnight must build/retain Focus before Daily');
must(midnight, /v_daily:=english\.ensure_daily\(p_user_id,120\)/, 'midnight must build/retain Daily after Focus');
must(midnight, /pg_advisory_xact_lock/, 'midnight build must be user/date locked');
must(midnight, /status='completed'/, 'midnight build must persist idempotent completion state');

// Daily Mix is performance practice, not a second scheduler lane.
must(dailyMixV2, /review date is not an admission or scoring signal/i, 'Daily Mix migration must state scheduler separation');
must(dailyMixV2, /'reviewClockUsedForAdmission',false/, 'Daily Mix telemetry must prove review clock is not an admission signal');
must(dailyMixV2, /'reviewClockUsedForScore',false/, 'Daily Mix telemetry must prove review clock is not a scoring signal');
must(dailyMixV2, /array\['Controlled New','Targeted Performance','Learning Risk','Mixed Performance'\]/, 'Daily Mix must use performance buckets');
must(dailyMixV2, /p_batch_date-3/, 'Mixed performance sampling must include a Daily cooldown window');
mustNot(dailyMixV2, /when 'Due Spaced Revision'/, 'performance-v2 must not retain a due-spaced-revision bucket');

// Cron ownership: old exact-midnight builders retained but disabled; central orchestrator owns 00:00 IST.
must(cronCutover, /english-review-due-snapshot/, 'cutover must explicitly address legacy Review Due snapshot');
must(cronCutover, /english-daily-rollover-primary/, 'cutover must explicitly address legacy Daily rollover');
must(cronCutover, /active=>false/, 'legacy midnight owners must be disabled, not silently duplicated');
must(cronCutover, /english-central-midnight-orchestrator'[\s\S]*'30 18 \* \* \*'/, 'central orchestrator must run at 00:00 IST');
must(cronCutover, /english-central-midnight-orchestrator-safety'[\s\S]*'36 18 \* \* \*'/, 'central orchestrator must have an idempotent 00:06 safety run');
must(cronCutover, /3-59\/10 \* \* \* \*/, 'Focus catch-up must be staggered before Daily catch-up');
must(cronCutover, /7-59\/10 \* \* \* \*/, 'Daily catch-up must run after Focus catch-up');

console.log('Review Due Today + central orchestrator contracts: PASS');

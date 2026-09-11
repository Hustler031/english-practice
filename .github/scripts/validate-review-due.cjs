const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const focus = read('web-v2/app/english/focus/page.tsx');
const home = read('web-v2/app/english/page.tsx');
const phase1 = read('supabase/migrations/20260911091322_english_review_due_today_phase1_shadow.sql');
const lane = read('supabase/migrations/20260911100000_english_review_due_practice_lane.sql');
const gate = read('supabase/migrations/20260911100500_english_review_due_cross_credit_deferral_gate.sql');

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

must(phase1, /source text not null default 'question_state\.next_review'/, 'question_state.next_review must remain the obligation source');
must(phase1, /primary key \(user_id,due_date,concept_key\)/, 'one obligation per user + day + concept');
must(phase1, /30 18 \* \* \*/, 'snapshot must run at 00:00 IST');

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

must(home, /Daily Focus/, 'Home must retain Daily Focus entry point');

console.log('Review Due Today contracts: PASS');

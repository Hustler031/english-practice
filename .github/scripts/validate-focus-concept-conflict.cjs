const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations/20260911205500_english_focus_concept_conflict_hardening.sql'), 'utf8');

function must(re, label) {
  if (!re.test(sql)) throw new Error(`Focus concept-conflict contract failed: ${label}`);
}
function mustNot(re, label) {
  if (re.test(sql)) throw new Error(`Focus concept-conflict contract failed: ${label}`);
}

must(/create or replace function english\.focus_conflicts_with_required_daily/i, 'canonical conflict helper must be replaced');
must(/d\.quiz_date\s*=\s*p_batch_date/i, 'Daily conflict must be scoped to the same batch date');
must(/english\.focus_concept_key\(d\.question_id\)\s*=\s*c\.concept_key/i, 'Daily sibling variants must be blocked by canonical concept');
must(/d\.question_id\s*=\s*p_question_id/i, 'exact Daily question conflict must remain blocked');
must(/grammar_daily_items[\s\S]*g\.question_id\s*=\s*p_question_id/i, 'Grammar must retain exact-question conflict semantics');
must(/phrasal_daily_items[\s\S]*p\.question_id\s*=\s*p_question_id/i, 'Phrasal must retain exact-question conflict semantics');
mustNot(/review_due/i, 'Review Due must remain outside the learning-workload conflict helper');
must(/revoke all on function english\.focus_conflicts_with_required_daily/i, 'helper must remain internal-only');

console.log('Daily Focus concept-level conflict hardening: PASS');

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations/20260912043000_english_shared_revision_recency.sql'), 'utf8');

function must(re, label) {
  if (!re.test(sql)) throw new Error(`Shared revision recency contract failed: ${label}`);
}
function mustNot(re, label) {
  if (re.test(sql)) throw new Error(`Shared revision recency contract failed: ${label}`);
}

must(/create or replace function english\.saved_revision_candidates_all/i, 'Saved recency function must be replaced');
must(/create or replace function english\.starred_revision_candidates/i, 'Starred recency function must be replaced');
must(/attempt_base as materialized/i, 'cross-module attempt evidence must be materialized once');
must(/coalesce\(qm\.concept_id,nullif\(a\.concept_id,''\),a\.question_id\)/i, 'attempt evidence must resolve through canonical concept mapping');
must(/ab\.attempted_at>=s\.created_at/i, 'Saved revision credit must start after Saved membership');
must(/ab\.attempted_at>=s\.membership_at/i, 'Starred revision credit must start after current Starred membership');
must(/coalesce\(a\.lifetime_attempts,0\)=0 controlled_new/i, 'controlled-new must be concept-level lifetime exposure');
must(/coalesce\(a\.revised_count,0\)=0 never_revised/i, 'never-revised must use shared revision evidence');
must(/max\(ab\.attempted_at\).*last_revision/i, 'latest shared attempt must become effective revision time');
mustNot(/lower\(coalesce\(a\.module,''\)\)='mysavedrevision'/i, 'Saved recency must not be module-siloed');
mustNot(/lower\(coalesce\(a\.module,''\)\)='starredrevision'/i, 'Starred recency must not be module-siloed');
mustNot(/update\s+english\.attempts/i, 'migration must not rewrite attempt history');
mustNot(/delete\s+from\s+english\.attempts/i, 'migration must not delete attempt history');
mustNot(/insert\s+into\s+english\.attempts/i, 'migration must not manufacture attempts');
mustNot(/review_due/i, 'Review Due ownership must remain untouched');
mustNot(/create or replace function english\.(reconcile_learning_signals_after_attempt|route_after_attempt_trigger)/i, 'Targeted reconciliation must not be rewritten by this migration');

console.log('Shared Saved/Starred revision recency contract: PASS');

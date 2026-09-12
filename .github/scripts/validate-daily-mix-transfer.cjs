const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations/20260912004500_english_daily_mix_transfer_validation_v3.sql'), 'utf8');
const reader = fs.readFileSync(path.join(root, 'supabase/migrations/20260912071500_english_daily_performance_reader_v3_compat.sql'), 'utf8');

function must(text, re, label) {
  if (!re.test(text)) throw new Error(`Daily Mix transfer contract failed: ${label}`);
}
function mustNot(text, re, label) {
  if (re.test(text)) throw new Error(`Daily Mix transfer contract failed: ${label}`);
}

must(sql,/daily_performance_candidates_v3/i, 'v3 candidate source must exist');
must(sql,/where c\.reason<>'Concept Validation'/i, 'legacy clock-owned Concept Validation must be excluded');
must(sql,/'Transfer Validation'/i, 'transfer validation lane must exist');
must(sql,/fresh_sibling_after_prior_concept_exposure/i, 'transfer must be based on sibling evidence');
must(sql,/coalesce\(s\.attempts,0\)=0/i, 'transfer variant must be genuinely unattempted');
must(sql,/coalesce\(ce\.attempts,0\)<=4/i, 'under-exposure may trigger transfer validation');
must(sql,/coalesce\(ce\.confidence_score,0\)<80/i, 'low concept confidence may trigger transfer validation');
must(sql,/p_batch_date-3/i, 'healthy Daily cooldown must remain');
must(sql,/'reviewClockUsedForAdmission',false/i, 'review clock may not admit Daily Mix items');
must(sql,/'reviewClockUsedForScore',false/i, 'review clock may not score Daily Mix items');
must(sql,/array\['Controlled New','Targeted Performance','Learning Risk','Transfer Validation','Mixed Performance'\]/i, 'builder must use the v3 performance buckets');
must(sql,/select \* from english\.daily_performance_candidates_v3/i, 'active builder must source v3 candidates');
mustNot(sql,/CONCEPT_DUE/i, 'Daily Mix must not reintroduce concept-due selection signals');
mustNot(sql,/concept_next_review\s*<=/i, 'concept review clock must not be an admission gate');
mustNot(sql,/next_review\s*<=/i, 'question review clock must not be an admission gate');

must(reader,/create or replace function english\.daily_effective_counts/i, 'effective-count reader must be version compatible');
must(reader,/create or replace function english\.current_daily_items/i, 'question reader must be version compatible');
const versionChecks = reader.match(/selection_snapshot->>'buildVersion'\s*,''\) like 'performance-v%'/gi) || [];
if (versionChecks.length < 2) throw new Error('Daily Mix transfer contract failed: both readers must accept performance-vN batches');
must(reader,/coalesce\(nullif\(d\.reason,''\),'Mixed Performance'\)/i, 'performance readers must honor frozen selection reason');
must(reader,/else english\.daily_reason/i, 'legacy batches must keep legacy dynamic reason semantics');

console.log('Daily Mix transfer + performance reader contracts: PASS');

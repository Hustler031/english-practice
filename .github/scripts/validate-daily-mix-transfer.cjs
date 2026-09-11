const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations/20260912004500_english_daily_mix_transfer_validation_v3.sql'), 'utf8');

function must(re, label) {
  if (!re.test(sql)) throw new Error(`Daily Mix transfer contract failed: ${label}`);
}
function mustNot(re, label) {
  if (re.test(sql)) throw new Error(`Daily Mix transfer contract failed: ${label}`);
}

must(/daily_performance_candidates_v3/i, 'v3 candidate source must exist');
must(/where c\.reason<>'Concept Validation'/i, 'legacy clock-owned Concept Validation must be excluded');
must(/'Transfer Validation'/i, 'transfer validation lane must exist');
must(/fresh_sibling_after_prior_concept_exposure/i, 'transfer must be based on sibling evidence');
must(/coalesce\(s\.attempts,0\)=0/i, 'transfer variant must be genuinely unattempted');
must(/coalesce\(ce\.attempts,0\)<=4/i, 'under-exposure may trigger transfer validation');
must(/coalesce\(ce\.confidence_score,0\)<80/i, 'low concept confidence may trigger transfer validation');
must(/p_batch_date-3/i, 'healthy Daily cooldown must remain');
must(/'reviewClockUsedForAdmission',false/i, 'review clock may not admit Daily Mix items');
must(/'reviewClockUsedForScore',false/i, 'review clock may not score Daily Mix items');
must(/array\['Controlled New','Targeted Performance','Learning Risk','Transfer Validation','Mixed Performance'\]/i, 'builder must use the v3 performance buckets');
must(/select \* from english\.daily_performance_candidates_v3/i, 'active builder must source v3 candidates');
mustNot(/CONCEPT_DUE/i, 'Daily Mix must not reintroduce concept-due selection signals');
mustNot(/concept_next_review\s*<=/i, 'concept review clock must not be an admission gate');
mustNot(/next_review\s*<=/i, 'question review clock must not be an admission gate');

console.log('Daily Mix transfer validation clock-separation contract: PASS');
